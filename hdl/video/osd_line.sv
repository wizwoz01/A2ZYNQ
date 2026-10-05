// One line of notice text over the HDMI picture, just below the Apple window
// (a2hostd uses it to show which disk a mid-game swap put in the drive).
//
// Text comes from a2hostd over SPI memory space 5: byte 0 bit 0 = show,
// bytes 1-40 = ASCII. Glyphs are the Apple II ones (video.hex, codes $00-$3F:
// upper case, digits, punctuation; bit 0 = leftmost dot), doubled to 14x16
// pixels so the 40 columns line up with the 560-pixel Apple window.
module osd_line #(
    parameter [9:0] X0   = 80,     // Apple window: x 80-639 (560 wide, centred in 720)
    parameter [9:0] Y0   = 436,    // Apple window ends at y 431
    parameter int   COLS = 40
) (
    input  wire       clk_pixel,
    input  wire [9:0] cx,
    input  wire [9:0] cy,
    input  wire [7:0] r_i,
    input  wire [7:0] g_i,
    input  wire [7:0] b_i,
    output wire [7:0] r_o,
    output wire [7:0] g_o,
    output wire [7:0] b_o,

    input  wire       clk_logic,   // text write port
    input  wire       we,
    input  wire [5:0] wa,
    input  wire [7:0] wd
);
    localparam [9:0] LA = 10'd2;   // look-ahead: text RAM + glyph ROM take two clocks

    // Text (LUTRAM, async read in the pixel domain; a write lands between
    // frames as far as anyone can see).
    reg [7:0] text_r [0:63];
    initial for (int i = 0; i < 64; i++) text_r[i] = 8'h00;
    always @(posedge clk_logic) if (we) text_r[wa] <= wd;

    reg [7:0] glyph_r [0:4095];
    initial $readmemh("video.hex", glyph_r, 0);

    // Column counters for the pixel two clocks ahead.
    reg        run_r;
    reg [5:0]  col_r;
    reg [3:0]  sub_r;          // 0-13 within a 14-pixel cell
    wire       in_rows_w = (cy >= Y0) && (cy < Y0 + 10'd16);
    always @(posedge clk_pixel) begin
        if (cx == X0 - LA - 10'd1) begin
            run_r <= in_rows_w;
            col_r <= 6'd0;
            sub_r <= 4'd0;
        end else if (run_r) begin
            if (sub_r == 4'd13) begin
                sub_r <= 4'd0;
                col_r <= col_r + 6'd1;
                if (col_r == COLS - 1) run_r <= 1'b0;
            end else begin
                sub_r <= sub_r + 4'd1;
            end
        end
    end

    // Stage 1: character code -> glyph address
    wire [7:0] ch_w   = text_r[col_r + 6'd1];
    wire [6:0] up_w   = (ch_w[6:5] == 2'b11) ? {2'b10, ch_w[4:0]} : ch_w[6:0];   // a-z -> A-Z
    wire [5:0] idx_w  = (up_w == 7'h00) ? 6'h20 :                                  // NUL -> space
                        (up_w < 7'h20)  ? 6'h3F : up_w[5:0];                       // controls -> '?'
    wire [9:0] row_w  = cy - Y0;
    reg  [8:0] addr_r;
    reg  [2:0] dot1_r, dot2_r;
    reg        act1_r, act2_r;
    reg  [7:0] glyph_q_r;
    always @(posedge clk_pixel) begin
        addr_r    <= {idx_w, row_w[3:1]};
        dot1_r    <= sub_r[3:1];
        act1_r    <= run_r && text_r[0][0];
        // Stage 2: glyph row
        glyph_q_r <= glyph_r[{3'b000, addr_r}];
        dot2_r    <= dot1_r;
        act2_r    <= act1_r;
    end

    wire on_w = act2_r && glyph_q_r[dot2_r];
    assign r_o = act2_r ? (on_w ? 8'hFF : 8'h00) : r_i;
    assign g_o = act2_r ? (on_w ? 8'hFF : 8'h00) : g_i;
    assign b_o = act2_r ? (on_w ? 8'hFF : 8'h00) : b_i;
endmodule
