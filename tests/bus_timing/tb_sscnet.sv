// tb_sscnet.sv -- the Super Serial Card's 6551 (uart_6551.v) talking to the
// network bridge (ssc_net_bridge.sv) instead of a cable.
//
// The "Apple" programs the 6551 through its registers the way the SSC firmware
// does; the "host" side is a2hostd's view: bytes the Apple sends must come out of
// the bridge FIFO in order, and bytes the host queues must arrive in the 6551's
// receive register, at whatever baud the Apple picked (115200, then 9600).
`timescale 1ns/1ps
module tb_sscnet;
    reg clk = 0;
    always #9.259 clk = ~clk;                  // 54 MHz clk_logic

    reg rst_n = 0, ph2 = 0, rw = 1;
    reg [1:0] cs = 2'b00, rs = 2'b00;
    reg [7:0] di = 8'h00;
    wire [7:0] dout, ctl;
    wire tx, rx, rts, dtr;

    glb6551 #(.CLOCK_SPEED_HZ(54_000_000)) acia (
        .clk_logic_i(clk), .RESET_N(rst_n), .PH_2(ph2), .DI(di), .DO(dout), .IRQ(),
        .CS(cs), .RS(rs), .RW_N(rw), .TXDATA_OUT(tx), .RXDATA_IN(rx),
        .RTS(rts), .CTL_OUT(ctl), .CTS(rts), .DCD(dtr), .DTR(dtr), .DSR(dtr));

    reg pop = 0, push = 0;
    reg [7:0] txd = 0;
    wire [7:0] rxd;
    wire [9:0] rxc, txfree;
    ssc_net_bridge #(.CLOCK_SPEED_HZ(54_000_000)) bridge (
        .clk(clk), .rst_n(rst_n), .ssc_ctl_i(ctl), .ssc_tx_i(tx), .ssc_rx_o(rx),
        .rx_pop_i(pop), .rx_data_o(rxd), .rx_count_o(rxc),
        .tx_push_i(push), .tx_data_i(txd), .tx_free_o(txfree));

    // 6551 register access as the SSC makes it: CS = {/CS1, CS0} = 01, PH_2 strobe
    task automatic wr(input [1:0] r, input [7:0] d);
        @(negedge clk); cs = 2'b01; rs = r; rw = 0; di = d; ph2 = 1;
        @(negedge clk); ph2 = 0; cs = 2'b00; rw = 1;
    endtask
    task automatic rd(input [1:0] r, output [7:0] d);
        @(negedge clk); cs = 2'b01; rs = r; rw = 1; ph2 = 1;
        #1 d = dout;
        @(negedge clk); ph2 = 0; cs = 2'b00;
    endtask
    task automatic apple_send(input [7:0] b);       // wait for TDRE, then write the data register
        reg [7:0] st;
        integer n;
        for (n = 0; n < 2000000; n++) begin rd(2'b01, st); if (st[4]) break; end
        wr(2'b00, b);
        repeat (4) @(negedge clk);
    endtask
    task automatic apple_get(output [7:0] b, input integer limit);   // wait for RDRF, read the byte
        reg [7:0] st;
        integer n;
        b = 8'hxx;
        for (n = 0; n < limit; n++) begin rd(2'b01, st); if (st[3]) begin rd(2'b00, b); break; end end
    endtask
    task automatic host_pop(output [7:0] b);
        @(negedge clk); b = rxd; pop = 1;
        @(negedge clk); pop = 0;
    endtask
    task automatic host_push(input [7:0] b);
        @(negedge clk); txd = b; push = 1;
        @(negedge clk); push = 0;
    endtask

    integer errs = 0, k, n;
    reg [7:0] b;
    reg [7:0] out_msg [0:3];
    reg [7:0] in_msg [0:3];
    task automatic round(input [7:0] ctl_val, input integer byte_clocks, input string name);
        // Apple -> host
        wr(2'b11, ctl_val);                          // control: baud
        wr(2'b10, 8'h0B);                            // command: no parity, DTR on, IRQs off
        for (k = 0; k < 4; k++) apple_send(out_msg[k]);
        for (n = 0; n < 6 * byte_clocks && rxc != 10'd4; n++) @(posedge clk);
        if (rxc != 10'd4) begin errs++; $display("FAIL %s: host has %0d bytes, want 4", name, rxc); end
        for (k = 0; k < 4 && rxc != 0; k++) begin
            host_pop(b);
            if (b !== out_msg[k]) begin errs++; $display("FAIL %s: host byte %0d = %h, want %h", name, k, b, out_msg[k]); end
        end
        // host -> Apple: queue all four at once, the bridge paces them at the baud
        for (k = 0; k < 4; k++) host_push(in_msg[k]);
        for (k = 0; k < 4; k++) begin
            apple_get(b, 3 * byte_clocks / 2);
            if (b !== in_msg[k]) begin errs++; $display("FAIL %s: Apple byte %0d = %h, want %h", name, k, b, in_msg[k]); end
        end
        if (txfree != 10'd512) begin errs++; $display("FAIL %s: send FIFO not empty (%0d free)", name, txfree); end
    endtask

    initial begin
        out_msg[0] = "H"; out_msg[1] = "I"; out_msg[2] = 8'h0D; out_msg[3] = 8'hC1;
        in_msg[0] = "O";  in_msg[1] = "K";  in_msg[2] = 8'h0D; in_msg[3] = 8'h8A;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        round(8'h10, 10 * 469, "115200");             // control 0: 115200 in this core
        round(8'h1E, 10 * 5625, "9600");              // control E: 9600 (the SSC's DIP default)
        $display("RESULT_SSCNET errors=%0d", errs);
        $finish;
    end
endmodule
