//
// ssc_net_bridge.sv -- the Super Serial Card's serial port, carried to a2hostd
// (and from there to a TCP port on the board) instead of a wire.
//
// The 6551 core (uart_6551.v) is left alone and still makes and takes a real
// serial bit stream. This module is the far end of the cable: uart_rx decodes
// the card's TX line into a FIFO that a2hostd drains over SPI, and uart_tx
// sends a2hostd's bytes into the card's RX line. Both run at the baud the Apple
// program set in the 6551 control register, 8N1 as the core itself uses, so the
// card's status flags and timing are exactly those of a cabled port.
//
// Host side (bl616_spi_connector), SPI memory SPACE 5: reads below 0x100 give
// the status {room for 256 more to send, bytes waiting (0-127)}, reads at 0x100
// and up pop received bytes, writes at 0x100 and up push bytes to send.
//
module ssc_net_bridge #(
    parameter int CLOCK_SPEED_HZ = 54_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ssc_ctl_i,      // 6551 control register: baud in [3:0]
    input  wire       ssc_tx_i,       // the card's serial output (idle high)
    output wire       ssc_rx_o,       // the card's serial input (idle high)

    input  wire       rx_pop_i,       // host takes the head byte
    output wire [7:0] rx_data_o,      // head byte, valid while rx_count_o != 0
    output wire [9:0] rx_count_o,
    input  wire       tx_push_i,      // host queues one byte for the card
    input  wire [7:0] tx_data_i,
    output wire [9:0] tx_free_o
);
    // Same baud table as the 6551 core (clock cycles per bit)
    localparam int C50 = CLOCK_SPEED_HZ / 50, C75 = CLOCK_SPEED_HZ / 75, C110 = CLOCK_SPEED_HZ / 110,
                   C135 = CLOCK_SPEED_HZ / 135, C150 = CLOCK_SPEED_HZ / 150, C300 = CLOCK_SPEED_HZ / 300,
                   C600 = CLOCK_SPEED_HZ / 600, C1200 = CLOCK_SPEED_HZ / 1200, C1800 = CLOCK_SPEED_HZ / 1800,
                   C2400 = CLOCK_SPEED_HZ / 2400, C3600 = CLOCK_SPEED_HZ / 3600, C4800 = CLOCK_SPEED_HZ / 4800,
                   C7200 = CLOCK_SPEED_HZ / 7200, C9600 = CLOCK_SPEED_HZ / 9600, C19200 = CLOCK_SPEED_HZ / 19200,
                   C115200 = CLOCK_SPEED_HZ / 115200;
    reg [20:0] cycle;
    always @(posedge clk) begin
        case (ssc_ctl_i[3:0])
            4'd0:  cycle <= 21'(C115200);
            4'd1:  cycle <= 21'(C50);
            4'd2:  cycle <= 21'(C75);
            4'd3:  cycle <= 21'(C110);
            4'd4:  cycle <= 21'(C135);
            4'd5:  cycle <= 21'(C150);
            4'd6:  cycle <= 21'(C300);
            4'd7:  cycle <= 21'(C600);
            4'd8:  cycle <= 21'(C1200);
            4'd9:  cycle <= 21'(C1800);
            4'd10: cycle <= 21'(C2400);
            4'd11: cycle <= 21'(C3600);
            4'd12: cycle <= 21'(C4800);
            4'd13: cycle <= 21'(C7200);
            4'd14: cycle <= 21'(C9600);
            default: cycle <= 21'(C19200);
        endcase
    end

    // ---- card -> host ----
    wire [7:0] rx_byte;
    wire       rx_valid;
    uart_rx from_card (
        .clk(clk), .cycle(cycle), .rst_n(rst_n),
        .rx_data(rx_byte), .rx_data_valid(rx_valid), .rx_data_ready(1'b1), .rx_pin(ssc_tx_i));

    reg [7:0] rxf [0:511];
    reg [9:0] rx_wp, rx_rp;
    wire [9:0] rx_cnt = 10'(rx_wp - rx_rp);
    assign rx_count_o = rx_cnt;
    assign rx_data_o  = rxf[rx_rp[8:0]];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_wp <= 10'd0;
            rx_rp <= 10'd0;
        end else begin
            if (rx_valid && rx_cnt != 10'd512) begin   // full: the byte is dropped
                rxf[rx_wp[8:0]] <= rx_byte;
                rx_wp <= 10'(rx_wp + 1'b1);
            end
            if (rx_pop_i && rx_cnt != 10'd0) rx_rp <= 10'(rx_rp + 1'b1);
        end
    end

    // ---- host -> card ----
    reg [7:0] txf [0:511];
    reg [9:0] tx_wp, tx_rp;
    wire [9:0] tx_cnt = 10'(tx_wp - tx_rp);
    assign tx_free_o = 10'(10'd512 - tx_cnt);

    reg  [7:0] tx_byte_r;
    reg        tx_valid_r;
    reg        tx_wait_r;         // a byte was handed over: wait for the sender to take it
    wire       tx_ready;
    uart_tx to_card (
        .clk(clk), .cycle(cycle), .rst_n(rst_n),
        .tx_data(tx_byte_r), .tx_data_valid(tx_valid_r), .tx_data_ready(tx_ready),
        .tx_pin(ssc_rx_o), .loopback());

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_wp      <= 10'd0;
            tx_rp      <= 10'd0;
            tx_valid_r <= 1'b0;
            tx_wait_r  <= 1'b0;
            tx_byte_r  <= 8'hFF;
        end else begin
            tx_valid_r <= 1'b0;
            if (tx_push_i && tx_cnt != 10'd512) begin   // full: the byte is dropped
                txf[tx_wp[8:0]] <= tx_data_i;
                tx_wp <= 10'(tx_wp + 1'b1);
            end
            if (tx_wait_r) begin
                if (!tx_ready) tx_wait_r <= 1'b0;       // the sender started on it
            end else if (tx_ready && !tx_valid_r && tx_cnt != 10'd0) begin
                tx_byte_r  <= txf[tx_rp[8:0]];
                tx_valid_r <= 1'b1;
                tx_wait_r  <= 1'b1;
                tx_rp      <= 10'(tx_rp + 1'b1);
            end
        end
    end
endmodule
