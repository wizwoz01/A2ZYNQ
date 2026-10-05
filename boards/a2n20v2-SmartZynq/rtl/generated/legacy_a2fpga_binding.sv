`timescale 1ns/1ps

// Smart-Zynq binding for the patched A2N20v2-Enhanced core.
module legacy_a2fpga_binding (
    input wire clk_27,
    input wire reset,
    input wire reset_n,
    input wire [7:0] bridge_data_i,
    output wire [7:0] bridge_data_o,
    output wire [2:0] bridge_sel,
    output wire bridge_rd,
    output wire bridge_wr,
    input wire bridge_phi1,
    input wire bridge_7m,
    input wire bridge_q3,
    input wire bridge_reset_n,
    input wire a2_5v_present,
    output wire bridge_addr_oe_n,
    output wire bridge_data_oe_n,
    output wire [7:0] bridge_drive_data,
    output wire bridge_drive_en,
    output wire [7:0] bridge_drive_fine,
    output wire [15:0] bridge_drive_cfg,
    input wire [1:0] bridge_slot_sel_n,   // {/DEVSEL, /IOSEL} of the card's own slot
    input wire [3:0] switch_n,
    input wire legacy_spi_sck,
    input wire legacy_spi_cs_n,
    input wire legacy_spi_mosi,
    output wire legacy_spi_miso,
    output wire legacy_mcu_irq,
    output wire hdmi_clk_p,
    output wire hdmi_clk_n,
    output wire [2:0] hdmi_data_p,
    output wire [2:0] hdmi_data_n,
    output wire core_clk_logic,
    output wire core_clk_4x,
    output wire core_clocks_locked,
    mem_port_if.client legacy_mem_port
);
    wire board_reset = reset | ~reset_n;
    wire [4:0] unused_led;
    wire unused_ws2812, unused_uart_tx;
    wire unused_sd_clk, unused_sd_cmd, unused_sd_dat3;
    wire unused_sdram_clk, unused_sdram_cke, unused_sdram_cs_n;
    wire unused_sdram_cas_n, unused_sdram_ras_n, unused_sdram_wen_n;
    wire [31:0] unused_sdram_dq;
    wire [10:0] unused_sdram_addr;
    wire [1:0] unused_sdram_ba;
    wire [3:0] unused_sdram_dqm;

    // The Enhanced board top has no dedicated companion interrupt output.
    assign legacy_mcu_irq = 1'b0;

    top legacy_core_i (
        .clk(clk_27), .s1(board_reset), .s2(1'b0),
        .a2_reset_n(bridge_reset_n), .a2_phi1(bridge_phi1), .a2_7M(bridge_7m),
        .a2_q3(bridge_q3),
        .a2_5v_present(a2_5v_present),
        .dip_live_n(switch_n),
        .a2_bridge_sel(bridge_sel),
        .a2_bridge_bus_a_oe_n(bridge_addr_oe_n),
        .a2_bridge_bus_d_oe_n(bridge_data_oe_n),
        .a2_bridge_rd_n(bridge_rd), .a2_bridge_wr_n(bridge_wr),
        .a2_bridge_d(bridge_data_i),
        .a2_bridge_d_wr(bridge_data_o),
        .a2_sz_drive_data(bridge_drive_data), .a2_sz_drive_en(bridge_drive_en),
        .a2_sz_drive_fine(bridge_drive_fine), .a2_sz_drive_cfg(bridge_drive_cfg),
        .a2_sz_slot_sel_n(bridge_slot_sel_n),
        .tmds_clk_p(hdmi_clk_p), .tmds_clk_n(hdmi_clk_n),
        .tmds_d_p(hdmi_data_p), .tmds_d_n(hdmi_data_n),
        .led(unused_led), .ws2812(unused_ws2812),
        .uart_tx(unused_uart_tx), .uart_rx(1'b1),
        .sd_clk(unused_sd_clk), .sd_cmd(unused_sd_cmd), .sd_dat0(1'b1), .sd_dat3(unused_sd_dat3),
        .spi_cs_n(legacy_spi_cs_n), .spi_sclk(legacy_spi_sck),
        .spi_mosi(legacy_spi_mosi), .spi_miso(legacy_spi_miso),
        .O_sdram_clk(unused_sdram_clk), .O_sdram_cke(unused_sdram_cke),
        .O_sdram_cs_n(unused_sdram_cs_n), .O_sdram_cas_n(unused_sdram_cas_n),
        .O_sdram_ras_n(unused_sdram_ras_n), .O_sdram_wen_n(unused_sdram_wen_n),
        .IO_sdram_dq(unused_sdram_dq), .O_sdram_addr(unused_sdram_addr),
        .O_sdram_ba(unused_sdram_ba), .O_sdram_dqm(unused_sdram_dqm),
        .smart_zynq_clk_logic(core_clk_logic),
        .smart_zynq_clk_4x(core_clk_4x),
        .smart_zynq_clocks_locked(core_clocks_locked),
        .smart_zynq_mem(legacy_mem_port)
    );
endmodule
