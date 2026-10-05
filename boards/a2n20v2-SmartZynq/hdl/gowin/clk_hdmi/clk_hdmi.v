`timescale 1ns/1ps

// Xilinx 7-series replacement for the Gowin clk_hdmi rPLL.
//
// Original relationship:
//     clkin  = 27 MHz
//     clkout = 135 MHz
//
// VCO = 27 MHz * 40 = 1080 MHz
//     /8 = 135 MHz
module clk_hdmi (
    output wire clkout,
    output wire lock,
    input  wire reset,
    input  wire clkin
);

    wire clkfb;
    wire clkfb_buf;
    wire clk135_i;

    PLLE2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(37.037037),

        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT(40),

        .CLKOUT0_DIVIDE(8),

        .STARTUP_WAIT("FALSE")
    ) pll (
        .CLKIN1(clkin),
        .CLKFBIN(clkfb_buf),

        .RST(reset),
        .PWRDWN(1'b0),

        .CLKFBOUT(clkfb),
        .CLKOUT0(clk135_i),

        .CLKOUT1(),
        .CLKOUT2(),
        .CLKOUT3(),
        .CLKOUT4(),
        .CLKOUT5(),

        .LOCKED(lock)
    );

    BUFG fb_buf (
        .I(clkfb),
        .O(clkfb_buf)
    );

    BUFG hdmi_buf (
        .I(clk135_i),
        .O(clkout)
    );

endmodule
