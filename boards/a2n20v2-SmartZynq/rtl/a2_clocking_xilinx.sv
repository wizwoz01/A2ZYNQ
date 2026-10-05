`timescale 1ns/1ps
// Input-clock conditioner used only to derive the Enhanced core's native 27 MHz
// board input from the Smart-Zynq 50 MHz oscillator.  The Enhanced top then
// creates its own 54 MHz logic and 135 MHz HDMI clocks from this 27 MHz clock,
// exactly as on the original board.  clk_54/108/135 are compatibility outputs
// only and intentionally mirror/hold benign values; no second PLL is required.
module a2_clocking_xilinx(
    input  wire clk_50,
    input  wire reset,
    output wire clk_27,
    output wire clk_54,
    output wire clk_108,
    output wire clk_135,
    output wire locked
);
`ifdef SYNTHESIS
    wire clkfb;
    wire clkfb_buf;
    wire clk27_i;
    wire lock_i;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.000),
        .DIVCLK_DIVIDE(1),
        // 50 MHz * 27 / 2 = 675 MHz VCO; /25 = 27 MHz.
        .CLKFBOUT_MULT_F(13.500),
        .CLKOUT0_DIVIDE_F(25.000),
        .STARTUP_WAIT("FALSE")
    ) mmcm_27 (
        .CLKIN1(clk_50),
        .CLKFBIN(clkfb_buf),
        .RST(reset),
        .PWRDWN(1'b0),
        .CLKFBOUT(clkfb),
        .CLKOUT0(clk27_i),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(lock_i)
    );

    BUFG fb_buf  (.I(clkfb),  .O(clkfb_buf));
    BUFG clk27_b (.I(clk27_i), .O(clk_27));
    assign locked = lock_i;
    assign clk_54  = clk_27;
    assign clk_108 = 1'b0;
    assign clk_135 = clk_27;
`else
    assign clk_27  = clk_50;
    assign clk_54  = clk_50;
    assign clk_108 = clk_50;
    assign clk_135 = clk_50;
    assign locked  = !reset;
`endif
endmodule
