`timescale 1ns/1ps
// AXI4-Lite programmed SPI mode-1 master (CPOL=0, CPHA=1).
// It replaces the physical BL616 companion while preserving the Enhanced
// core's byte protocol.  Register 0x0c bit 0 is the explicit PS host-ready
// gate used by the Apple-bus PHY; reset leaves the bus electrically quiescent.
//
// CS# is released on the last data bit's trailing edge. The Enhanced slave
// (bl616_spi_proto_proc) must retire byte_rx_stb even if CS# already dropped
// — see that module's CS-vs-byte CDC comment. Do NOT add a post-transfer CS
// hold state here without verifying the module_ref IP actually resynthesizes;
// a half-applied hold FSM left busy stuck and killed a2hostd + HDMI (Apple
// /RES never released under HOST_MANAGED_RESET).
module axi_spi_master #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 18,
    parameter integer BUFFER_BYTES = 8192
)(
    input  wire s_axi_aclk,
    input  wire s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire s_axi_awvalid,
    output wire s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0] s_axi_wstrb,
    input  wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg  [1:0] s_axi_bresp,
    output reg  s_axi_bvalid,
    input  wire s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0] s_axi_rresp,
    output reg  s_axi_rvalid,
    input  wire s_axi_rready,
    output reg  spi_cs_n,
    output reg  spi_sclk,
    output reg  spi_mosi,
    input  wire spi_miso,
    output reg  irq,
    output reg  host_ready
);
    localparam integer PTR_W = $clog2(BUFFER_BYTES);
    localparam integer WORDS = BUFFER_BYTES / 4;
    localparam integer WORD_W = PTR_W - 2;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] TX_BASE = 18'h10000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] RX_BASE = 18'h20000;

    (* ram_style = "distributed" *) reg [7:0] txmem0 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] txmem1 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] txmem2 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] txmem3 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] rxmem0 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] rxmem1 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] rxmem2 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] rxmem3 [0:WORDS-1];
    reg [31:0] transfer_len;
    reg [31:0] clock_div;
    reg [PTR_W-1:0] byte_index;
    reg [7:0] rx_shift;
    reg [2:0] bit_index;
    reg [31:0] div_count;
    reg busy, done_latched, phase;
    reg tail;   // half an SCLK period after the last falling edge, before CS# rises

    reg aw_pending, w_pending;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [31:0] wdata_hold;
    reg [3:0] wstrb_hold;
    wire write_fire = aw_pending && w_pending && !s_axi_bvalid;
    wire read_fire  = s_axi_arvalid && !s_axi_rvalid;
    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = !w_pending && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;

    integer i;

    wire [WORD_W-1:0] aw_tx_word = awaddr_hold[PTR_W-1:2];
    wire [WORD_W-1:0] ar_word    = s_axi_araddr[PTR_W-1:2];
    wire [WORD_W-1:0] spi_word   = byte_index[PTR_W-1:2];
    wire [1:0]        spi_lane   = byte_index[1:0];
    wire [7:0]        spi_tx_byte = (spi_lane == 2'd0) ? txmem0[spi_word]
                                  : (spi_lane == 2'd1) ? txmem1[spi_word]
                                  : (spi_lane == 2'd2) ? txmem2[spi_word]
                                  :                      txmem3[spi_word];

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= 2'b00;
            aw_pending <= 1'b0; w_pending <= 1'b0;
            awaddr_hold <= '0; wdata_hold <= '0; wstrb_hold <= '0;
            s_axi_rvalid <= 1'b0;
            s_axi_rresp <= 2'b00;
            s_axi_rdata <= 32'b0;
            transfer_len <= 32'b0;
            clock_div <= 32'd4;
            byte_index <= '0;
            rx_shift <= 8'b0;
            bit_index <= 3'd7;
            div_count <= 32'b0;
            busy <= 1'b0;
            tail <= 1'b0;
            done_latched <= 1'b0;
            phase <= 1'b0;
            spi_cs_n <= 1'b1;
            spi_sclk <= 1'b0;
            spi_mosi <= 1'b0;
            irq <= 1'b0;
            host_ready <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            if (s_axi_awready && s_axi_awvalid) begin aw_pending <= 1'b1; awaddr_hold <= s_axi_awaddr; end
            if (s_axi_wready && s_axi_wvalid) begin w_pending <= 1'b1; wdata_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb; end

            if (write_fire) begin
                aw_pending <= 1'b0; w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00;
                case (awaddr_hold[17:2])
                    16'd0: begin
                        if (wstrb_hold[0] && wdata_hold[1]) begin
                            done_latched <= 1'b0;
                            irq <= 1'b0;
                        end
                        if (wstrb_hold[0] && wdata_hold[0] && !busy &&
                            transfer_len != 0 && transfer_len <= BUFFER_BYTES) begin
                            busy <= 1'b1;
                            tail <= 1'b0;
                            done_latched <= 1'b0;
                            irq <= 1'b0;
                            spi_cs_n <= 1'b0;
                            spi_sclk <= 1'b0;
                            spi_mosi <= 1'b0; // CPHA=1: data changes on first rising edge
                            phase <= 1'b0;
                            byte_index <= '0;
                            bit_index <= 3'd7;
                            rx_shift <= 8'b0;
                            div_count <= 32'b0;
                        end
                    end
                    16'd1: for (i=0; i<4; i=i+1)
                                if (wstrb_hold[i]) transfer_len[i*8 +: 8] <= wdata_hold[i*8 +: 8];
                    16'd2: for (i=0; i<4; i=i+1)
                                if (wstrb_hold[i]) clock_div[i*8 +: 8] <= wdata_hold[i*8 +: 8];
                    16'd3: if (wstrb_hold[0]) host_ready <= wdata_hold[0];
                    default: begin
                        if (awaddr_hold >= TX_BASE && awaddr_hold < TX_BASE + BUFFER_BYTES) begin
                            if (wstrb_hold[0]) txmem0[aw_tx_word] <= wdata_hold[7:0];
                            if (wstrb_hold[1]) txmem1[aw_tx_word] <= wdata_hold[15:8];
                            if (wstrb_hold[2]) txmem2[aw_tx_word] <= wdata_hold[23:16];
                            if (wstrb_hold[3]) txmem3[aw_tx_word] <= wdata_hold[31:24];
                        end else begin
                            s_axi_bresp <= 2'b10;
                        end
                    end
                endcase
            end

            if (read_fire) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp <= 2'b00;
                s_axi_rdata <= 32'b0;
                case (s_axi_araddr[17:2])
                    16'd0: s_axi_rdata <= {29'b0, irq, done_latched, busy};
                    16'd1: s_axi_rdata <= transfer_len;
                    16'd2: s_axi_rdata <= clock_div;
                    16'd3: s_axi_rdata <= {31'b0, host_ready};
                    default: begin
                        if (s_axi_araddr >= TX_BASE && s_axi_araddr < TX_BASE + BUFFER_BYTES) begin
                            s_axi_rdata <= {txmem3[ar_word], txmem2[ar_word],
                                            txmem1[ar_word], txmem0[ar_word]};
                        end else if (s_axi_araddr >= RX_BASE && s_axi_araddr < RX_BASE + BUFFER_BYTES) begin
                            s_axi_rdata <= {rxmem3[ar_word], rxmem2[ar_word],
                                            rxmem1[ar_word], rxmem0[ar_word]};
                        end else begin
                            s_axi_rresp <= 2'b10;
                        end
                    end
                endcase
            end

            if (busy) begin
                if (div_count >= ((clock_div < 2) ? 1 : clock_div-1)) begin
                    div_count <= 32'b0;
                    if (tail) begin
                        // Half a period after the last falling edge: only now
                        // release CS# and park MOSI. Changing them on that edge
                        // raced the slave's sample of the final bit (the SPI
                        // clock is asynchronous to this domain in the timing
                        // constraints, so nothing checks that skew): in some
                        // builds every register write lost data bit 0.
                        tail <= 1'b0;
                        busy <= 1'b0;
                        done_latched <= 1'b1;
                        irq <= 1'b1;
                        spi_cs_n <= 1'b1;
                        spi_mosi <= 1'b0;
                    end else if (!phase) begin
                        // CPHA=1 leading (rising) edge: master changes MOSI;
                        // Enhanced BL616 slave also changes MISO on this edge.
                        spi_mosi <= spi_tx_byte[bit_index];
                        spi_sclk <= 1'b1;
                        phase <= 1'b1;
                    end else begin
                        // Trailing (falling) edge: both sides sample.
                        spi_sclk <= 1'b0;
                        rx_shift[bit_index] <= spi_miso;
                        phase <= 1'b0;
                        if (bit_index == 0) begin
                            case (spi_lane)
                                2'd0: rxmem0[spi_word] <= {rx_shift[7:1], spi_miso};
                                2'd1: rxmem1[spi_word] <= {rx_shift[7:1], spi_miso};
                                2'd2: rxmem2[spi_word] <= {rx_shift[7:1], spi_miso};
                                2'd3: rxmem3[spi_word] <= {rx_shift[7:1], spi_miso};
                            endcase
                            if (({1'b0, byte_index} + 1'b1) >= transfer_len[PTR_W:0]) begin
                                tail <= 1'b1;   // CS#/MOSI change one half-period later
                            end else begin
                                byte_index <= byte_index + 1'b1;
                                bit_index <= 3'd7;
                                rx_shift <= 8'b0;
                            end
                        end else begin
                            bit_index <= bit_index - 1'b1;
                        end
                    end
                end else begin
                    div_count <= div_count + 1'b1;
                end
            end
        end
    end
endmodule
