`timescale 1ns/1ps

// One-outstanding-request bridge from A2FPGA's 54-MHz mem_port_if to the
// 100-MHz Zynq HP2 AXI port.  The mem_port address is a 32-bit WORD address;
// AXI addresses are bytes and are placed in a reserved 8-MiB DDR window.
module mem_port_axi_async #(
    parameter integer PORT_ADDR_WIDTH = 21,
    parameter [31:0] DDR_BASE = 32'h1e000000,
    parameter integer AXI_ID_WIDTH = 6
) (
    input  wire mem_clk,
    input  wire reset_n,
    mem_port_if.controller mem,

    input  wire axi_clk,

    output wire [AXI_ID_WIDTH-1:0] m_axi_awid,
    output reg  [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output reg  m_axi_awvalid,
    input  wire m_axi_awready,

    output reg  [31:0] m_axi_wdata,
    output reg  [3:0] m_axi_wstrb,
    output wire m_axi_wlast,
    output reg  m_axi_wvalid,
    input  wire m_axi_wready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0] m_axi_bresp,
    input  wire m_axi_bvalid,
    output reg  m_axi_bready,

    output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
    output reg  [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output reg  m_axi_arvalid,
    input  wire m_axi_arready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0] m_axi_rresp,
    input  wire m_axi_rlast,
    input  wire m_axi_rvalid,
    output reg  m_axi_rready
);
    assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_wlast   = 1'b1;
    assign m_axi_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd2;
    assign m_axi_arburst = 2'b01;

    // Async assert / synchronous deassert in each clock domain. The PS reset
    // is synchronous to FCLK, while the A2 memory side runs from the core's
    // independent 54-MHz clock.
    (* ASYNC_REG = "TRUE" *) reg [1:0] mem_rst_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] axi_rst_sync;
    always @(posedge mem_clk or negedge reset_n) begin
        if (!reset_n) mem_rst_sync <= 2'b00;
        else mem_rst_sync <= {mem_rst_sync[0], 1'b1};
    end
    always @(posedge axi_clk or negedge reset_n) begin
        if (!reset_n) axi_rst_sync <= 2'b00;
        else axi_rst_sync <= {axi_rst_sync[0], 1'b1};
    end
    wire mem_reset_n = mem_rst_sync[1];
    wire axi_reset_n = axi_rst_sync[1];

    // ---------------- mem_clk request/response side ----------------
    reg [PORT_ADDR_WIDTH-1:0] req_addr_hold;
    reg [31:0] req_data_hold;
    reg [3:0] req_be_hold;
    reg req_write_hold;
    reg req_toggle;
    reg mem_busy;
    // Clients (and the Smart-Zynq arbiter) often HOLD rd/wr until ready.
    // Accept only the rising request phase so a still-asserted rd/wr cannot
    // start a second AXI beat the cycle mem_busy clears (that orphaned the
    // video fetch ready handshake and left HDMI stuck on the black border).
    reg req_armed;
    reg [31:0] mem_q_r;
    reg mem_ready_r;

    reg rsp_toggle_axi;
    reg [31:0] rsp_data_axi;
    (* ASYNC_REG = "TRUE" *) reg rsp_sync1, rsp_sync2;
    reg rsp_seen;

    wire req_fire = mem.rd || mem.wr;

    assign mem.available = mem_reset_n && !mem_busy;
    assign mem.ready = mem_ready_r;
    assign mem.q = mem_q_r;

    always @(posedge mem_clk or negedge mem_reset_n) begin
        if (!mem_reset_n) begin
            req_addr_hold <= '0;
            req_data_hold <= 32'b0;
            req_be_hold <= 4'b0;
            req_write_hold <= 1'b0;
            req_toggle <= 1'b0;
            mem_busy <= 1'b0;
            req_armed <= 1'b0;
            mem_q_r <= 32'b0;
            mem_ready_r <= 1'b0;
            rsp_sync1 <= 1'b0;
            rsp_sync2 <= 1'b0;
            rsp_seen <= 1'b0;
        end else begin
            rsp_sync1 <= rsp_toggle_axi;
            rsp_sync2 <= rsp_sync1;
            mem_ready_r <= 1'b0;

            if (!req_fire)
                req_armed <= 1'b0;

            if (!mem_busy && req_fire && !req_armed) begin
                // All clients in this build use single-beat transfers.
                req_addr_hold <= mem.addr;
                req_data_hold <= mem.data;
                req_be_hold <= mem.byte_en;
                req_write_hold <= mem.wr;
                req_toggle <= ~req_toggle;
                mem_busy <= 1'b1;
                req_armed <= 1'b1;
            end

            if (mem_busy && (rsp_sync2 != rsp_seen)) begin
                rsp_seen <= rsp_sync2;
                mem_q_r <= rsp_data_axi;
                mem_ready_r <= 1'b1;
                mem_busy <= 1'b0;
            end
        end
    end

    // ---------------- axi_clk execution side ----------------
    (* ASYNC_REG = "TRUE" *) reg req_sync1, req_sync2;
    reg req_seen;
    reg aw_done, w_done;
    // Narrow WSTRB has been observed to paint ALL bytes on this HP2 window
    // (TEXT40 double-cursor / "AAppppllee"). Partial writes become
    // read-modify-write with WSTRB=1111 so only the enabled lanes change.
    localparam [2:0] A_IDLE=3'd0, A_WRITE=3'd1, A_B=3'd2,
                     A_AR=3'd3, A_R=3'd4,
                     A_RMW_AR=3'd5, A_RMW_R=3'd6;
    reg [2:0] astate;
    reg [31:0] rmw_wdata_r;
    reg [3:0]  rmw_be_r;

    wire [31:0] byte_addr = DDR_BASE + {{(30-PORT_ADDR_WIDTH){1'b0}}, req_addr_hold, 2'b00};
    wire        needs_rmw_w = req_write_hold && (req_be_hold != 4'b1111);

    function automatic [31:0] merge_be;
        input [31:0] old_w;
        input [31:0] new_w;
        input [3:0]  be;
        begin
            merge_be = old_w;
            if (be[0]) merge_be[7:0]   = new_w[7:0];
            if (be[1]) merge_be[15:8]  = new_w[15:8];
            if (be[2]) merge_be[23:16] = new_w[23:16];
            if (be[3]) merge_be[31:24] = new_w[31:24];
        end
    endfunction

    always @(posedge axi_clk or negedge axi_reset_n) begin
        if (!axi_reset_n) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen <= 1'b0;
            rsp_toggle_axi <= 1'b0;
            rsp_data_axi <= 32'b0;
            m_axi_awaddr <= 32'b0;
            m_axi_awvalid <= 1'b0;
            m_axi_wdata <= 32'b0;
            m_axi_wstrb <= 4'b0;
            m_axi_wvalid <= 1'b0;
            m_axi_bready <= 1'b0;
            m_axi_araddr <= 32'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_rready <= 1'b0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
            rmw_wdata_r <= 32'b0;
            rmw_be_r <= 4'b0;
            astate <= A_IDLE;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;

            case (astate)
                A_IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid <= 1'b0;
                    m_axi_bready <= 1'b0;
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b0;
                    if (req_sync2 != req_seen) begin
                        req_seen <= req_sync2;
                        if (req_write_hold) begin
                            if (needs_rmw_w) begin
                                rmw_wdata_r <= req_data_hold;
                                rmw_be_r <= req_be_hold;
                                m_axi_araddr <= byte_addr;
                                m_axi_arvalid <= 1'b1;
                                astate <= A_RMW_AR;
                            end else begin
                                m_axi_awaddr <= byte_addr;
                                m_axi_wdata <= req_data_hold;
                                m_axi_wstrb <= 4'b1111;
                                m_axi_awvalid <= 1'b1;
                                m_axi_wvalid <= 1'b1;
                                aw_done <= 1'b0;
                                w_done <= 1'b0;
                                astate <= A_WRITE;
                            end
                        end else begin
                            m_axi_araddr <= byte_addr;
                            m_axi_arvalid <= 1'b1;
                            astate <= A_AR;
                        end
                    end
                end
                A_RMW_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready <= 1'b1;
                        astate <= A_RMW_R;
                    end
                end
                A_RMW_R: begin
                    if (m_axi_rvalid) begin
                        m_axi_rready <= 1'b0;
                        m_axi_awaddr <= byte_addr;
                        m_axi_wdata <= merge_be(m_axi_rdata, rmw_wdata_r, rmw_be_r);
                        m_axi_wstrb <= 4'b1111;
                        m_axi_awvalid <= 1'b1;
                        m_axi_wvalid <= 1'b1;
                        aw_done <= 1'b0;
                        w_done <= 1'b0;
                        astate <= A_WRITE;
                    end
                end
                A_WRITE: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        aw_done <= 1'b1;
                    end
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        w_done <= 1'b1;
                    end
                    if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
                        (w_done || (m_axi_wvalid && m_axi_wready))) begin
                        m_axi_bready <= 1'b1;
                        astate <= A_B;
                    end
                end
                A_B: begin
                    if (m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        rsp_data_axi <= 32'b0;
                        rsp_toggle_axi <= ~rsp_toggle_axi;
                        astate <= A_IDLE;
                    end
                end
                A_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready <= 1'b1;
                        astate <= A_R;
                    end
                end
                A_R: begin
                    if (m_axi_rvalid) begin
                        rsp_data_axi <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        rsp_toggle_axi <= ~rsp_toggle_axi;
                        astate <= A_IDLE;
                    end
                end
                default: astate <= A_IDLE;
            endcase
        end
    end

    wire _unused_axi = ^{m_axi_bid,m_axi_bresp,m_axi_rid,m_axi_rresp,m_axi_rlast,mem.burst};
endmodule
