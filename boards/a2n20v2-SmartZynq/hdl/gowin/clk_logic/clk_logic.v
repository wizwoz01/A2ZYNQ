`timescale 1ns/1ps

// Xilinx 7-series replacement for the Gowin clk_logic rPLL.
//
// Original A2N20v2 clock relationships:
//     clkin   = 27 MHz
//     clkout  = 54 MHz logic/SDRAM clock
//     clkoutd = 27 MHz pixel clock
//     clkoutp = phase-shifted 54 MHz SDRAM output clock
//
// VCO = 27 MHz * 40 = 1080 MHz
//     /20 = 54 MHz
//     /40 = 27 MHz
//     /5  = 216 MHz (Smart-Zynq D0-D7 drive timing, phase-aligned with 54)
module clk_logic (
    output wire clkout,
    output wire clkout4x,
    output wire lock,
    output wire clkoutp,
    output wire clkoutd,
    input  wire reset,
    input  wire clkin
);

    wire clkfb;
    wire clkfb_buf;

    wire clk54_i;
    wire clk54_phase_i;
    wire clk27_i;
    wire clk216_i;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(37.037037),

        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(40.000),

        .CLKOUT0_DIVIDE_F(20.000),
        .CLKOUT0_PHASE(0.000),

        .CLKOUT1_DIVIDE(40),
        .CLKOUT1_PHASE(0.000),

        // External SDRAM clock is deliberately phase shifted from
        // the controller clock.
        .CLKOUT2_DIVIDE(20),
        .CLKOUT2_PHASE(180.000),

        .CLKOUT3_DIVIDE(5),
        .CLKOUT3_PHASE(0.000),

        .STARTUP_WAIT("FALSE")
    ) mmcm (
        .CLKIN1(clkin),
        .CLKFBIN(clkfb_buf),

        .RST(reset),
        .PWRDWN(1'b0),

        .CLKFBOUT(clkfb),

        .CLKOUT0(clk54_i),
        .CLKOUT1(clk27_i),
        .CLKOUT2(clk54_phase_i),

        .CLKOUT3(clk216_i),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),

        .LOCKED(lock)
    );

    BUFG fb_buf (
        .I(clkfb),
        .O(clkfb_buf)
    );

    BUFG logic_buf (
        .I(clk54_i),
        .O(clkout)
    );

    BUFG pixel_buf (
        .I(clk27_i),
        .O(clkoutd)
    );

    BUFG fast_buf (
        .I(clk216_i),
        .O(clkout4x)
    );

    BUFG sdram_phase_buf (
        .I(clk54_phase_i),
        .O(clkoutp)
    );

endmodule
