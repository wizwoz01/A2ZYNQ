`timescale 1ns/1ps
// osd_line: write a notice over the write port, scan the rows it covers and
// print the pixels as text; checks the first row against the glyph ROM.
module tb_osd;
    reg clkp = 0, clkl = 0;
    always #18.5 clkp = ~clkp;   // 27 MHz
    always #9.25 clkl = ~clkl;   // 54 MHz
    reg [9:0] cx = 0, cy = 0;
    always @(posedge clkp) begin
        if (cx == 10'd857) begin cx <= 0; cy <= (cy == 10'd524) ? 10'd0 : cy + 10'd1; end
        else cx <= cx + 10'd1;
    end
    reg we = 0; reg [5:0] wa = 0; reg [7:0] wd = 0;
    wire [7:0] r, g, b;
    osd_line dut(.clk_pixel(clkp), .cx(cx), .cy(cy), .r_i(8'h40), .g_i(8'h40), .b_i(8'h40),
                 .r_o(r), .g_o(g), .b_o(b), .clk_logic(clkl), .we(we), .wa(wa), .wd(wd));
    task automatic put(input [5:0] a, input [7:0] d);
        @(posedge clkl); we <= 1; wa <= a; wd <= d; @(posedge clkl); we <= 0;
    endtask
    string msg = "Drive 1: ultima32.dsk";
    reg [7:0] rom [0:4095];
    initial $readmemh("video.hex", rom, 0);
    string line;
    integer i, errs = 0, box = 0;
    initial begin
        for (i = 0; i < 40; i++) put(6'(i + 1), (i < msg.len()) ? msg[i] : " ");
        put(0, 8'h01);
        // wait for the first OSD row (cy == 436), then sample one row of pixels
        wait (cy == 10'd436 && cx == 10'd0);
        line = "";
        for (i = 0; i < 858; i++) begin
            @(negedge clkp);
            if (cx >= 70 && cx < 70 + 44 * 14) line = {line, (r == 8'hFF) ? "#" : (r == 8'h00) ? "." : " "};
            if (r != 8'h40) box++;
        end
        $display("%s", line);
        // expected: 'D' glyph row 0 at x 80..93
        begin : chk
            string want; integer k, d;
            want = "";
            for (k = 0; k < 44 * 14; k++) begin
                integer x; x = 70 + k;
                if (x < 80 || x >= 80 + 40 * 14) want = {want, " "};
                else begin
                    integer c; reg [7:0] ch; reg [5:0] idx;
                    c = (x - 80) / 14; d = ((x - 80) % 14) / 2;
                    ch = (c < msg.len()) ? msg[c] : " ";
                    if (ch >= "a" && ch <= "z") ch = ch - 8'h20;
                    idx = ch[5:0];
                    want = {want, rom[{idx, 3'd0}][d] ? "#" : "."};
                end
            end
            if (line != want) begin errs++; $display("WANT\n%s", want); end
        end
        $display("RESULT_OSD errors=%0d box_pixels=%0d (want %0d)", errs, box, 40 * 14);
        $finish;
    end
endmodule
