//
// Top module for Tang Nano 20K and A2N20v2 Apple II card
//
// This version uses the Tang Nano 20K SDRAM for extended functionality
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

// Feature selection via defines. The on-FPGA PicoSoC soft core and its Disk II
// RAMDISK have been removed; the coprocessor is the external BL616 MCU.

`define ENSONIQ
`define BL616_SPI

// DUAL_RATE_SDRAM: run the SDRAM controller at 108 MHz (GS-style split clock,
// PLL 27->108 + CLKDIV2 for the 54 MHz logic clock, mem_port_cdc on every
// port). Prerequisite for the beam-accurate framebuffer. Leave undefined for
// the shipping single 54 MHz domain; the a2n20v2_enhanced_dualrate.gprj
// project defines it via top_dualrate.sv and uses the matching .sdc.
//`define DUAL_RATE_SDRAM

// VIDEO_FRAMEBUFFER: render Apple/SHR video in Apple II native timing
// (scan_timer) into an SDRAM framebuffer read out at HDMI rate — the GS
// board's beam-accurate architecture. Fetch jitter lands in the buffer,
// never on glass, and beam-racing software displays correctly. Requires
// DUAL_RATE_SDRAM; used by a2n20v2_enhanced_fb.gprj via top_fb.sv (whose
// file list also selects the f18a `_fb` VHDL variants).
//`define VIDEO_FRAMEBUFFER

`include "datetime.svh"

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 0,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter bit [7:0] SUPERSPRITE_ID = 1,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    parameter bit SUPERSERIAL_ENABLE = 1,
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter bit DISK_II_ENABLE = 1,
    parameter bit [7:0] DISK_II_ID = 4,

    parameter bit UTHERNET2_ENABLE = 1,
    parameter bit [7:0] UTHERNET2_ID = 5,

    parameter bit HDD_ENABLE = 1,
    parameter bit [7:0] HDD_ID = 6,

    parameter bit ENSONIQ_ENABLE = 1,
    parameter bit ENSONIQ_MONO_MIX = 0, // If true, mono mix is used instead of stereo

    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit SHADOW_ALL_MEMORY = 0,        // Shadoow all memory in SDRAM, not just video ram
    parameter bit HDMI_SLEEP_ENABLE = 0,        // Sleep HDMI output on CPU stop
    // Smart-Zynq bring-up: force OSD so locked-black HDMI is distinguishable
    // from "TMDS alive but Apple VRAM fetch wedged".
    parameter bit FORCE_DEBUG_OVERLAY = 1,
    // DIP switch 4. Upstream it puts the card in Apple IIgs mode. I run a IIe,
    // so here switch 4 hides the HDMI debug numbers instead (ON = hidden).
    // One switch can't do both jobs separately, so while this is 0 IIgs mode
    // stays off. Set it to 1 to give switch 4 back to IIgs mode (the debug
    // numbers then always show).
    parameter bit DIP4_IIGS_MODE = 0,
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1,      // Allow driving data to Apple bus

    // Video generation path:
    //   0 = legacy raster-locked apple_video + vgc (combinational on hdmi_x/y)
    //   1 = pixel_stream_if generators (apple_video_gen + vgc_gen) feeding
    //       direct_display, HDMI-locked but using the new interface
    parameter bit USE_PIXEL_STREAM = 1,

    // direct_display hsync cx offsets used to center each window in the 720px
    // visible area (apple = 560 wide, SHR = 640 wide). The apple value differs
    // from the plain a2n20v2 board because the main video read goes through
    // SDRAM (longer priming latency) here. Tune on hardware against a test
    // pattern until each image is centered.
    parameter [9:0] DD_APPLE_H_START = 58,  // was 66; recentered for PIXEL_START_TICK=20 fixed start
    parameter [9:0] DD_VGC_H_START   = 14

) (
    // fpga clocks
    input clk,

    // fpga buttons
    input s1,
    input s2,

    // A2 signals
    input a2_reset_n,
    input a2_phi1,
    input a2_7M,
`ifdef SMART_ZYNQ
    input a2_q3,
    // Slot 5V sense (J5[13] via PHY). When low, translators are off and the
    // Apple bus floats — must not shadow-capture or the text page fills with
    // flash-attribute junk that keeps blinking on HDMI after power-off.
    input a2_5v_present,
    // The four DIP switch pins, live (active low: a switch that's ON pulls its
    // pin to ground; the FPGA's pull-ups hold an OFF switch high).
    input [3:0] dip_live_n,
`endif

    // A2Bridge signals
    output [2:0] a2_bridge_sel,
    output a2_bridge_bus_a_oe_n,
    output a2_bridge_bus_d_oe_n,
    output a2_bridge_rd_n,
    output a2_bridge_wr_n,
`ifdef SMART_ZYNQ
    input [7:0] a2_bridge_d,
    output [7:0] a2_bridge_d_wr,
    // Direct D0-D7 drive (apple_bus sz_drive_*), used by the PHY instead of
    // the emulated bridge data latch.
    output [7:0] a2_sz_drive_data,
    output a2_sz_drive_en,
    output [7:0] a2_sz_drive_fine,     // PHY: [7] early start, [6:0] drive start in 216 MHz clocks after PHI0
    output [15:0] a2_sz_drive_cfg,     // PHY: [3:0] clocks, [4] soft, [5] LSB first, [6] fall/high first, [8] early release, [13:9] delay, [14] open drain, [15] weak first
    input [1:0] a2_sz_slot_sel_n,      // this card's own slot selects {/DEVSEL, /IOSEL}, raw from the connector
`else
    inout [7:0] a2_bridge_d,
`endif

    // hdmi ports
    output tmds_clk_p,
    output tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n,

    // leds
    output reg [4:0] led,

    output ws2812,

    // uart
    output uart_tx,
    input  uart_rx,

    // MicroSD
    output sd_clk,
    output sd_cmd,      // MOSI
    input  sd_dat0,     // MISO
    //output sd_dat1,   // 1
    //output sd_dat2,   // 1
    output sd_dat3,     // CS

    // BL616 SPI
    input  spi_cs_n,
    input  spi_sclk,
    input  spi_mosi,
    output spi_miso,

    // "Magic" port names that the gowin compiler connects to the on-chip SDRAM
    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,   // chip select
    output        O_sdram_cas_n,  // columns address select
    output        O_sdram_ras_n,  // row address select
    output        O_sdram_wen_n,  // write enable
    inout  [31:0] IO_sdram_dq,    // 32 bit bidirectional data bus
    output [10:0] O_sdram_addr,   // 11 bit multiplexed address bus
    output [ 1:0] O_sdram_ba,     // two banks
    output [ 3:0] O_sdram_dqm     // 32/4
`ifdef SMART_ZYNQ
    ,output wire smart_zynq_clk_logic
    ,output wire smart_zynq_clk_4x          // 216 MHz, phase-aligned with clk_logic
    ,output wire smart_zynq_clocks_locked
    ,mem_port_if.client smart_zynq_mem
`endif

);

    wire rst_n = ~s1;

    // Clocks

    wire clk_logic_w;
    wire clk_logic_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_hdmi_lock_w;
    wire hdmi_rst_n_w;
    wire a2_2M;

`ifdef SMART_ZYNQ
    wire clk_logic_4x_w;
    assign smart_zynq_clk_logic = clk_logic_w;
    assign smart_zynq_clk_4x = clk_logic_4x_w;
    assign smart_zynq_clocks_locked = clk_logic_lock_w & clk_hdmi_lock_w;
`endif

    wire clk_sdram_w;      // SDRAM controller clock (== clk_logic_w single-rate)
    wire clk_sdram_p_w;    // phase-shifted SDRAM output clock
    wire clk_pixel_pll_w;  // raw clkoutd from PLL

`ifdef DUAL_RATE_SDRAM
    // PLL - 108 MHz from 27 (split clock: SDRAM at 108, logic at 54)
    clk_logic_108 clk_logic_inst (
        .clkout(clk_sdram_w),  //output clkout (108 MHz)
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_sdram_p_w),  //output clkoutp (108 MHz phase-shifted)
        .clkoutd(clk_pixel_pll_w),  //output clkoutd (27 MHz)
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    // 108 MHz -> 54 MHz logic clock
    CLKDIV clkdiv2_inst(
        .CLKOUT(clk_logic_w),
        .HCLKIN(clk_sdram_w),
        .RESETN(rst_n),
        .CALIB(1'b0)
    );
    defparam clkdiv2_inst.DIV_MODE = "2";
    defparam clkdiv2_inst.GSREN = "false";
`else
    // PLL - 54hz from 27
    wire clk_logic_p_w;
    clk_logic clk_logic_inst (
        .clkout(clk_logic_w),  //output clkout
`ifdef SMART_ZYNQ
        .clkout4x(clk_logic_4x_w),
`endif
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_logic_p_w),  //output clkoutp
        .clkoutd(clk_pixel_pll_w),  //output clkoutd
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    assign clk_sdram_w = clk_logic_w;
    assign clk_sdram_p_w = clk_logic_p_w;
`endif

    // Force pixel clock onto global clock network via BUFG.
    // Pin 13 (spi_sclk) is a clock-capable pin whose routing conflicts with
    // clkoutd (PR1014), pushing it to generic routing. BUFG ensures the pixel
    // clock reaches the clk_hdmi PLL and all clock sinks reliably.
    BUFG pixel_bufg (
        .O(clk_pixel_w),
        .I(clk_pixel_pll_w)
    );

    // PLL - 135Mhz from 27
    clk_hdmi clk_hdmi_inst (
        .clkout(clk_hdmi_w),  //output clkout
        .lock(clk_hdmi_lock_w),  //output lock
        .reset(~clk_logic_lock_w),  //input reset
        .clkin(clk_pixel_w)  //input clkin
    );

    // Reset

    wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;

    /*
    wire a2_reset_n_w;
    cdc cdc_a2reset (
        .clk(clk_logic_w),
        .i(a2_reset_n),
        .o(a2_reset_n_w),
        .o_n(),
        .o_posedge(),
        .o_negedge()
    );
    */

    wire a2_reset_cdc_w;
    cdc_fifo #(
        .WIDTH(1)
    ) cdc_a2reset (
        .clk(clk_logic_w),
        .i(a2_reset_n),
        .o(a2_reset_cdc_w)
    );

    // Apple-bus side still tracks /RES. Video generators must NOT: a stuck or
    // inverted Q7 /RES sense would hold system_reset_n low forever and leave
    // HDMI as black+OSD only (exactly the Smart-Zynq bring-up failure mode).
`ifdef SMART_ZYNQ
    wire system_reset_n_w = device_reset_n_w;
    wire video_reset_n_w  = device_reset_n_w;

    // Bus-side reset: Apple /RES (Ctrl-Reset, power-on, our own reset hold)
    // must reset the cards again, or the Disk II keeps its motor/Q6/Q7/track
    // state across every reboot. The Q7 sense reads correctly (low only while
    // /RES is held), so only the video generators stay on device reset. A
    // ~1.2 us filter keeps a sense glitch from resetting every card.
    reg [5:0] a2_res_cnt_r;
    reg       a2_res_n_r;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            a2_res_cnt_r <= 6'd0;
            a2_res_n_r   <= 1'b1;
        end else if (a2_reset_cdc_w == a2_res_n_r) begin
            a2_res_cnt_r <= 6'd0;
        end else if (&a2_res_cnt_r) begin
            a2_res_n_r   <= a2_reset_cdc_w;
            a2_res_cnt_r <= 6'd0;
        end else begin
            a2_res_cnt_r <= a2_res_cnt_r + 6'd1;
        end
    end
    wire bus_reset_n_w = device_reset_n_w & a2_res_n_r;

    // apple_bus live tuning / error counters over SPI (see mcu_scratch_w below):
    // 0x0C/0x0D/0x0E = addr/data/write sample counts (0 = default), 0x0F[2:0] =
    // counter select, read back through regs 0x7B-0x7E.
    wire [23:0] sz_tune_w;
    wire [3:0]  sz_hold_w;       // reg 0x0F[7:4]: data drive hold, clocks
    wire        sz_early_w;      // reg 0x0F[3]: 1 = disable early mode (fall back)
    wire [7:0]  mcu_scratch_early_w;  // reg 0x07: D0-D7 drive start in 216 MHz clocks after PHI0 (0 = off)
    wire [2:0]  sz_probe_sel_w;
    wire [31:0] sz_probe_w;

    // Sync slot 5V for diagnostics + bus-FSM recovery (do NOT blank HDMI on it —
    // that left OSD-only after Apple power-cycle when sense/debounce disagreed).
    (* ASYNC_REG = "TRUE" *) reg a2_5v_sync1, a2_5v_sync2;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            a2_5v_sync1 <= 1'b0;
            a2_5v_sync2 <= 1'b0;
        end else begin
            a2_5v_sync1 <= a2_5v_present;
            a2_5v_sync2 <= a2_5v_sync1;
        end
    end
    wire apple_powered_w = a2_5v_sync2;
`else
    wire system_reset_n_w = device_reset_n_w & a2_reset_cdc_w;
    wire video_reset_n_w  = system_reset_n_w;
    wire bus_reset_n_w    = system_reset_n_w;
`endif

    // SDRAM Controller signals
    wire sdram_init_complete;

`ifdef DUAL_RATE_SDRAM
    localparam int MEM_CLOCK_MHZ = 108;
`else
    localparam int MEM_CLOCK_MHZ = MEM_MHZ;
`endif

    // SDRAM ports, lower number is higher priority
`ifdef VIDEO_FRAMEBUFFER
    // Framebuffer config (requires ENSONIQ + BL616_SPI). sdram_ports'
    // arbitration cone fails 108 MHz above 7 ports, so the three storage
    // clients (MCU XFER, Disk II window, HDD window) share one port through
    // mem_port_arb.
    // The DOC has the hardest real-time deadline in the system (missed
    // oscillator fetches are audible pops), so it sits directly behind the
    // framebuffer ports. Video reads and CPU writes are latency-tolerant
    // here: the framebuffer absorbs late line priming (active-keyed writer)
    // and the shadow write path queues through a FIFO.
    localparam FB_READ_PORT      = 0;   // framebuffer line reads (display)
    localparam FB_WRITE_PORT     = 1;   // framebuffer pixel writes
    localparam DOC_MEM_PORT      = 2;
    localparam GLU_MEM_PORT      = 3;
    localparam VIDEO_MEM_PORT    = 4;   // shadow reads (apple_video_gen + VGC via arbiter)
    localparam MAIN_MEM_PORT     = 5;   // CPU shadow/aux writes
    localparam STORAGE_MEM_PORT  = 6;   // MCU + Disk II + HDD via mem_port_arb
    localparam NUM_PORTS         = 7;
`else
    localparam VIDEO_MEM_PORT = 0;
    localparam MAIN_MEM_PORT = 1;
    `ifdef ENSONIQ
    localparam GLU_MEM_PORT = 3;
    localparam DOC_MEM_PORT = 2;
        `ifdef BL616_SPI
    localparam MCU_MEM_PORT = 4;
    localparam DISK_MEM_PORT = 5;   // Disk II track-on-demand window (read)
    localparam HDD_MEM_PORT = 6;    // ProDOS HDD block window (read/write)
    localparam NUM_PORTS = 7;
        `else
    localparam NUM_PORTS = 4;
        `endif
    `else
        `ifdef BL616_SPI
    localparam MCU_MEM_PORT = 2;
    localparam NUM_PORTS = 3;
        `else
    localparam NUM_PORTS = 2;
        `endif
    `endif
`endif

    localparam PORT_ADDR_WIDTH = 21;
    localparam DATA_WIDTH = 32;
    localparam DQM_WIDTH = 4;
    localparam PORT_OUTPUT_WIDTH = 32;

    // SDRAM memory map — word address offsets (32-bit word addressing)
    // Applied per-port inside sdram_ports via PORT_BASE_ADDR parameter.
    // NOTE: the video/main shadow port address is {bank, a2_addr[15:1]}.
    // Bank 0 = Apple shadow (words 0x0000-0x7FFF); bank 1 = the MCU's
    // private display space (words 0x8000-0xFFFF; OSD text page at word
    // 0x8200 = byte 0x20800, see firmware fpga_screen.c). Do NOT allocate
    // SDRAM regions in words 0x8000-0xFFFF.
    localparam [PORT_ADDR_WIDTH-1:0] SHADOW_WORD_BASE  = 21'h000000;  // 0MB
`ifdef ENSONIQ
    localparam [PORT_ADDR_WIDTH-1:0] ENSONIQ_WORD_BASE = 21'h010000;  // 128KB
`endif
    // Disk II track windows: 2 drives x 8KB, one resident track each. Lives in
    // free SDRAM at byte 0x200000 (word 0x080000). The MCU streams a track here
    // via XFER SPACE 1; drive d's window is byte 0x200000 + d*0x2000.
    localparam [PORT_ADDR_WIDTH-1:0] DISK_WORD_BASE    = 21'h080000;  // byte 0x200000
    // ProDOS HDD block windows: 2 units x 512 bytes, one block each, right
    // after the Disk II track windows. The MCU streams a block here via XFER
    // SPACE 1; unit u's window is byte 0x204000 + u*0x200.
    localparam [PORT_ADDR_WIDTH-1:0] HDD_WORD_BASE     = 21'h081000;  // byte 0x204000
    // Framebuffer pixel storage (VIDEO_FRAMEBUFFER config): 1.5MB in, well
    // above every other region.
    localparam [PORT_ADDR_WIDTH-1:0] FB_WORD_BASE      = 21'h180000;  // byte 0x600000

    // Signals for the multiple ports (client side, 54 MHz logic domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports[NUM_PORTS-1:0]();

`ifdef DUAL_RATE_SDRAM
    // SDRAM-side port interfaces (108 MHz domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports_sdram[NUM_PORTS-1:0]();

    wire sdram_init_complete_raw;  // from sdram_ports (108 MHz domain)
`endif

`ifndef SMART_ZYNQ
    sdram_ports #(
        .CLOCK_SPEED_MHZ(MEM_CLOCK_MHZ),
        .NUM_PORTS(NUM_PORTS),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
`ifdef VIDEO_FRAMEBUFFER
        .PORT_BASE_ADDR('{FB_WORD_BASE, FB_WORD_BASE,
                          ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE,
                          SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          SHADOW_WORD_BASE}),
`elsif ENSONIQ
    `ifdef BL616_SPI
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE,
                          SHADOW_WORD_BASE, DISK_WORD_BASE,
                          HDD_WORD_BASE}),
    `else
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE}),
    `endif
`else
    `ifdef BL616_SPI
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          SHADOW_WORD_BASE}),
    `else
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE}),
    `endif
`endif
        .CAS_LATENCY(2),
        .SETTING_REFRESH_TIMER_NANO_SEC(15000),
        .SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC(16),
`ifdef DUAL_RATE_SDRAM
        .SETTING_USE_FAST_INPUT_REGISTER(1),
        .BURST_LENGTH(2),
        .READ_BURST_LENGTH(8),
`else
        .BURST_LENGTH(1),
`endif
        .PORT_BURST_LENGTH(1),
        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(11),
        .COL_WIDTH(8),
        .PRECHARGE_BIT(10),
        .DQM_WIDTH(DQM_WIDTH)
    ) sdram_ports (
        .clk(clk_sdram_w),
        .sdram_clk(clk_sdram_p_w),
        .reset(!device_reset_n_w),
`ifdef DUAL_RATE_SDRAM
        .init_complete(sdram_init_complete_raw),

        .ports(mem_ports_sdram),
`else
        .init_complete(sdram_init_complete),

        .ports(mem_ports),
`endif

        .SDRAM_DQ(IO_sdram_dq),
        .SDRAM_A(O_sdram_addr),
        .SDRAM_DQM(O_sdram_dqm),
        .SDRAM_BA(O_sdram_ba),
        .SDRAM_nCS(O_sdram_cs_n),
        .SDRAM_nWE(O_sdram_wen_n),
        .SDRAM_nRAS(O_sdram_ras_n),
        .SDRAM_nCAS(O_sdram_cas_n),
        .SDRAM_CKE(O_sdram_cke),
        .SDRAM_CLK(O_sdram_clk)
    );
`else
    // Smart-Zynq: replace Tang Nano SDRAM with PS DDR through one shared port.
    a2_mem_port_arb_safe #(
        .NUM_CLIENTS(NUM_PORTS),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
`ifdef VIDEO_FRAMEBUFFER
        .CLIENT_BASE_ADDR('{FB_WORD_BASE, FB_WORD_BASE, ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE, SHADOW_WORD_BASE, SHADOW_WORD_BASE, SHADOW_WORD_BASE})
`elsif ENSONIQ
    `ifdef BL616_SPI
        .CLIENT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE, ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE, SHADOW_WORD_BASE, DISK_WORD_BASE, HDD_WORD_BASE})
    `else
        .CLIENT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE, ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE})
    `endif
`else
    `ifdef BL616_SPI
        .CLIENT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE, SHADOW_WORD_BASE})
    `else
        .CLIENT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE})
    `endif
`endif
    ) smart_zynq_mem_arb (
        .clk_i(clk_logic_w), .rst_n_i(device_reset_n_w),
        .clients(mem_ports), .controller(smart_zynq_mem)
    );
    assign sdram_init_complete = device_reset_n_w;
    assign O_sdram_clk=1'b0; assign O_sdram_cke=1'b0; assign O_sdram_cs_n=1'b1;
    assign O_sdram_cas_n=1'b1; assign O_sdram_ras_n=1'b1; assign O_sdram_wen_n=1'b1;
    assign IO_sdram_dq=32'h0; assign O_sdram_addr=11'b0; assign O_sdram_ba=2'b0; assign O_sdram_dqm=4'hf;
`endif

`ifdef DUAL_RATE_SDRAM
`ifndef SMART_ZYNQ
    // CDC wrappers: 54 MHz clients <-> 108 MHz SDRAM
    generate
        for (genvar mem_cdc_i = 0; mem_cdc_i < NUM_PORTS; mem_cdc_i++) begin : mem_cdc
            mem_port_cdc #(
                .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .DQM_WIDTH(DQM_WIDTH),
                .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
            ) cdc_inst (
                .clk_client(clk_logic_w),   // 54 MHz
                .clk_sdram(clk_sdram_w),    // 108 MHz
                .rst_n(device_reset_n_w),
                .client(mem_ports[mem_cdc_i]),
                .sdram(mem_ports_sdram[mem_cdc_i])
            );
        end
    endgenerate

    // Sync sdram_init_complete from 108 MHz -> 54 MHz (2FF synchronizer)
    reg sdram_init_sync1, sdram_init_sync2;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            {sdram_init_sync1, sdram_init_sync2} <= 2'b0;
        end else begin
            sdram_init_sync1 <= sdram_init_complete_raw;
            sdram_init_sync2 <= sdram_init_sync1;
        end
    end
    assign sdram_init_complete = sdram_init_sync2;
`endif
`endif

    // Interface to Apple II

    // data and address latches on input

    a2bus_if a2bus_if ();

    a2bus_control_if a2bus_control_if();

    wire sleep_w;
    wire data_in_strobe_w;

    wire irq_n_w;

    wire inh_n_w;
    wire harness_w;              // reg 0x2E bit 2: self-test /INH ROM (see harness_byte)
    wire test7_w;                // reg 0x2E bit 3: slot 7 autostart test ROM (see test7_byte)
    wire [2:0] phys_slot_w;      // slot the card is plugged into (0 = not seen yet), reg 0x2E [6:4]
`ifdef SMART_ZYNQ
    phys_slot_detect phys_slot_detect (
        .a2bus_if(a2bus_if),
        .iosel_n_i(a2_sz_slot_sel_n[0]),
        .devsel_n_i(a2_sz_slot_sel_n[1]),
        .slot_o(phys_slot_w)
    );
`else
    assign phys_slot_w = 3'd0;
`endif

    wire data_out_en_w;
    wire [7:0] data_out_w;

    wire [7:0] a2_bridge_d_buf_w;
    wire [7:0] a2_bridge_d_o_w;
    wire a2_bridge_d_oe_w;

    wire [3:0] dip_switches_n_w;
    wire sw_scanlines_w = !dip_switches_n_w[0];
    wire sw_apple_speaker_w = !dip_switches_n_w[1];
    // Switch 3 is the Power-on-Reset hold (por_hold_w below, read live).
    // Upstream's sw_slot_7_w = !dip_switches_n_w[2] was never used.
    // Switch 4 is the IIgs switch only when DIP4_IIGS_MODE = 1 (see above).
    // Upstream: wire sw_gs_w = !dip_switches_n_w[3];
    wire sw_gs_w = DIP4_IIGS_MODE && !dip_switches_n_w[3];
    wire phi_dead_w;

`ifdef SMART_ZYNQ
    // Fabric-side a2bridge: unidirectional mux, no IOBUF.
    assign a2_bridge_d_buf_w = a2_bridge_d;
    assign a2_bridge_d_wr = a2_bridge_d_o_w;
`else
    IOBUF a2_bridge_d_iobuf[7:0] (
        .O  (a2_bridge_d_buf_w),
        .IO (a2_bridge_d),
        .I  (a2_bridge_d_o_w),
        .T  (!a2_bridge_d_oe_w)
    );
`endif

    apple_bus #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .BUS_DATA_OUT_ENABLE(BUS_DATA_OUT_ENABLE),
        .IRQ_OUT_ENABLE(IRQ_OUT_ENABLE)
`ifdef SMART_ZYNQ
        // Counts are from the cdc_denoise'd PHI edge, which lags the pin by
        // 8 clocks (~150 ns). Address is sampled at PHI1+592..685 ns, i.e. in
        // PHI0: measured on a IIe, the address lines are unsettled/noisy around
        // the PHI1->PHI0 edge (0.08% mismatch here vs 2% at 14) and the commit
        // still opens card selects by PHI0+~215 ns. Card read data is on the
        // pins by PHI0+~330 ns, write data is sampled at PHI0+444/463 ns. The old
        // 14/20/12 with the 11-step address read put read data on the bus at the
        // CPU latch edge, sampled write data after PHI0 ended, and ran selects
        // on the previous cycle's address. All three plus the drive hold can be
        // overridden live over SPI (scratch regs 0x0C-0x0F).
        //
        // Early mode (default here): the IIe samples slot data well before
        // PHI0 ends (measured: ~4% CPU read errors with the byte on the pins
        // at PHI0+~330 ns, 0% when driven off the fast PHI edge). So an early
        // address pass in late PHI1 feeds the card decode, the byte goes out
        // right after PHI0 rises, and a late pass inside PHI0 (where the
        // address is settled) is what the data strobe / soft switches use.
        // Reg 0x0F bit 3 = 1 falls back to the PHI0-only timing above.
        ,.ADDR_SAMPLE_COUNT(20)
        ,.DATA_SAMPLE_COUNT(11)
        ,.WRITE_COUNT(2)
        ,.ADDR_EARLY_COUNT(15)     // clocks after the fast PHI1 edge: samples ~390-455 ns into PHI1
        ,.ADDR_LATE_COUNT(1)
        ,.EARLY_DEFAULT(1'b1)
`endif
        ,.GS_SWITCH_ENABLE(DIP4_IIGS_MODE)
    ) apple_bus (
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_pixel_w),
        .system_reset_n_i(bus_reset_n_w),
        .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1),
`ifdef SMART_ZYNQ
        .a2_q3_i(a2_q3),
`else
        .a2_q3_i(1'b0),
`endif
        .a2_7M_i(a2_7M),

        .a2bus_if(a2bus_if),
        .a2bus_control_if(a2bus_control_if),

        .a2_bridge_sel_o(a2_bridge_sel),
        .a2_bridge_bus_a_oe_n_o(a2_bridge_bus_a_oe_n),
        .a2_bridge_bus_d_oe_n_o(a2_bridge_bus_d_oe_n),
        .a2_bridge_rd_n_o(a2_bridge_rd_n),
        .a2_bridge_wr_n_o(a2_bridge_wr_n),
        .a2_bridge_d_i(a2_bridge_d_buf_w),
        .a2_bridge_d_o(a2_bridge_d_o_w),
        .a2_bridge_d_oe_o(a2_bridge_d_oe_w),

        .data_out_en_i(data_out_en_w),
        .data_out_i(data_out_w),

        .irq_n_i(irq_n_w),
        .inh_n_i(inh_n_w),

        .dip_switches_n_o(dip_switches_n_w),

        .sleep_o(sleep_w),
        .phi_dead_o(phi_dead_w)
`ifdef SMART_ZYNQ
        ,.sz_tune_i(sz_tune_w)
        ,.sz_hold_i(sz_hold_w)
        ,.sz_early_i(sz_early_w)
        ,.sz_release_i(mcu_scratch_early_w[7:0])
        ,.sz_probe_sel_i(sz_probe_sel_w)
        ,.sz_probe_o(sz_probe_w)
        ,.sz_drive_data_o(a2_sz_drive_data)
        ,.sz_drive_en_o(a2_sz_drive_en)
`endif
    );

    // Memory

    a2mem_if a2mem_if();

    wire [15:0] video_address_w;
    wire video_bank_w;
    wire video_rd_w;
    wire [31:0] video_data_w;
    wire video_ready_w;

    wire vgc_active_w;
    wire [12:0] vgc_address_w;
    wire vgc_rd_w;
    wire [31:0] vgc_data_w;
    wire vgc_ready_w;
    wire [7:0] wq_drops_w;      // shadow write-queue drops (diagnostics)
    wire [7:0] aux_wr_cnt_w;    // captured aux/SHR writes (diagnostics)
    wire [7:0] m2b0_wr_cnt_w;   // captured m2b0 writes (diagnostics)

    apple_memory_sdram #(
        .VGC_MEMORY(1),
        .SHADOW_ALL_MEMORY(SHADOW_ALL_MEMORY),
`ifdef DUAL_RATE_SDRAM
        .VGC_IN_SDRAM(1)
`else
        .VGC_IN_SDRAM(0)
`endif
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(mem_ports[MAIN_MEM_PORT]),
        .video_mem_if(mem_ports[VIDEO_MEM_PORT]),

        .video_address_i(video_address_w),
        .video_bank_i(video_bank_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),
        .video_ready_o(video_ready_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w),
        .vgc_ready_o(vgc_ready_w),
        .wq_drops_o(wq_drops_w),
        .aux_wr_cnt_o(aux_wr_cnt_w),
        .m2b0_wr_cnt_o(m2b0_wr_cnt_w)
`ifdef SMART_ZYNQ
        ,.phi_dead_i(phi_dead_w)
`endif
    );

    // Slots

    slot_if slot_if();
    slotmaker_config_if slotmaker_config_if();

    slotmaker slotmaker (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .cfg_if(slotmaker_config_if),

        .slot_if(slot_if)
    );


`ifdef BL616_SPI

    // -------------------------------------------------------
    // BL616 SPI Controller (replaces PicoSOC)
    // -------------------------------------------------------

    wire standalone_w;   // from bl616_spi_connector: no BL616 detected

    // CardROM excised: when active it overlaid the Apple $F8xx monitor ROM
    // region (driving the data bus and asserting /INH). That collided with an
    // Apple Language Card's own F8 ROM — both drove $F800-$FFFF at the reset
    // vector / DOS cold-start, corrupting the fetch and hanging the machine
    // (deterministic; a pure-RAM language card had no F8 ROM so was immune).
    // The mechanism also never worked on the IIgs. Removed entirely rather
    // than parameter-disabled so no stale/optimized-away logic can linger.
    // /INH is released except in the self-test harness below.
    assign inh_n_w = ~harness_w;

    video_control_if video_control_if();
    f18a_gpu_if f18a_gpu_if();
    assign f18a_gpu_if.running = 1'b0;
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = 1'b0;
    assign f18a_gpu_if.vaddr = 14'b0;
    assign f18a_gpu_if.vdout = 8'b0;
    assign f18a_gpu_if.pwe = 1'b0;
    assign f18a_gpu_if.paddr = 6'b0;
    assign f18a_gpu_if.pdout = 12'b0;
    assign f18a_gpu_if.rwe = 1'b0;
    assign f18a_gpu_if.raddr = 13'b0;
    assign f18a_gpu_if.gstatus = 7'b0;

`ifdef VIDEO_FRAMEBUFFER
    // Storage clients (MCU XFER, Disk II window, HDD window) share one
    // controller port — see the port map note. MCU first (it streams whole
    // tracks/blocks and the others wait on its acks anyway).
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) storage_ports[2:0] ();

    mem_port_arb #(
        .NUM_CLIENTS(3),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
        // Replaces the PORT_BASE_ADDR each client's dedicated port had
        .CLIENT_BASE_ADDR('{SHADOW_WORD_BASE, DISK_WORD_BASE, HDD_WORD_BASE})
    ) storage_arb (
        .clk_i(clk_logic_w),
        .rst_n_i(device_reset_n_w),
        .clients(storage_ports),
        .controller(mem_ports[STORAGE_MEM_PORT])
    );
`endif

    drive_volume_if volumes[2]();

    wire [7:0] diskii_d_w;
    wire diskii_rd;
    wire disk_nib_we_w;
    wire disk_nib_drive_w;
    wire [12:0] disk_nib_addr_w;
    wire [7:0] disk_nib_data_w;
    wire disk_nib_rdrive_w;          // SPACE 6: Disk II track read-back for saves
    wire [12:0] disk_nib_raddr_w;
    wire [7:0] disk_nib_rdata_w;
    wire hdd_buf_we_w;               // SPACE 7: hard disk sector buffer, host side
    wire [8:0] hdd_buf_addr_w;
    wire [7:0] hdd_buf_wdata_w;
    wire [7:0] hdd_buf_rdata_w;
    wire osd_wr_w;
    wire [5:0] osd_addr_w;
    wire [7:0] osd_wdata_w;
    wire disk_menu_wr_w;
    wire [10:0] disk_menu_addr_w;
    wire [7:0] disk_menu_wdata_w;
    wire [7:0] disk_menu_rdata_w;

    // Disk II controller (track-on-demand). drive_ii drives the drive side of
    // volumes[] (lba/blk_cnt/rd) on a seek; the BL616 (bl616_spi_connector
    // volume regs 0x40-0x5F) streams the requested track into the
    // DISK_MEM_PORT SDRAM window via XFER SPACE 1, then pulses ack.
    DiskII #(
        .ENABLE(DISK_II_ENABLE),
        .ID(DISK_II_ID)
    ) diskii (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(diskii_d_w),
        .rd_en_o(diskii_rd),
`ifdef VIDEO_FRAMEBUFFER
        .ram_disk_if(storage_ports[1]),
`else
        .ram_disk_if(mem_ports[DISK_MEM_PORT]),
`endif
        .volumes(volumes),
        .host_nib_we_i(disk_nib_we_w),
        .host_nib_drive_i(disk_nib_drive_w),
        .host_nib_addr_i(disk_nib_addr_w),
        .host_nib_data_i(disk_nib_data_w),
        .host_nib_rdrive_i(disk_nib_rdrive_w),
        .host_nib_raddr_i(disk_nib_raddr_w),
        .host_nib_rdata_o(disk_nib_rdata_w),
        .menu_host_wr_i(disk_menu_wr_w),
        .menu_host_addr_i(disk_menu_addr_w),
        .menu_host_wdata_i(disk_menu_wdata_w),
        .menu_host_rdata_o(disk_menu_rdata_w)
    );

    drive_volume_if hdd_volumes[2]();

    wire [7:0] hdd_d_w;
    wire hdd_rd;

    // ProDOS hard disk (block device). The card requests one 512-byte block
    // at a time over hdd_volumes[] (compact BL616 regs 0x26-0x2D); the BL616
    // serves it from a .hdv/.po image into the HDD_MEM_PORT SDRAM window via
    // XFER SPACE 1, then pulses ack and the card streams it to the 6502
    // through its sector buffer.
    HDD #(
        .ENABLE(HDD_ENABLE),
        .ID(HDD_ID)
    ) hdd (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(hdd_d_w),
        .rd_en_o(hdd_rd),
`ifdef VIDEO_FRAMEBUFFER
        .ram_hdd_if(storage_ports[2]),
`else
        .ram_hdd_if(mem_ports[HDD_MEM_PORT]),
`endif
        .volumes(hdd_volumes),
        .host_buf_we_i(hdd_buf_we_w),
        .host_buf_addr_i(hdd_buf_addr_w),
        .host_buf_wdata_i(hdd_buf_wdata_w),
        .host_buf_rdata_o(hdd_buf_rdata_w)
    );

    // Bus event FIFO
    wire        fifo_empty_w;
    wire        fifo_full_w;
    wire [8:0]  fifo_count_w;
    wire [31:0] fifo_rdata_w;
    wire        fifo_pop_w;
    wire [2:0]  capture_mode_w;
    wire        capture_enable_w;
    wire        trig_enable_w;
    wire [15:0] trig_addr_w;
    wire [15:0] trig_mask_w;
    wire        trig_matched_w;
    wire        oneshot_w;

    a2bus_event_fifo #(
        .ENABLE(1'b1)
    ) a2bus_event_fifo (
        .a2bus_if(a2bus_if),
        .fifo_empty(fifo_empty_w),
        .fifo_full(fifo_full_w),
        .fifo_count(fifo_count_w),
        .fifo_rdata(fifo_rdata_w),
        .fifo_pop(fifo_pop_w),
        .capture_enable(capture_enable_w),
        .capture_mode(capture_mode_w),
        .trig_enable(trig_enable_w),
        .trig_addr(trig_addr_w),
        .trig_mask(trig_mask_w),
        .trig_matched(trig_matched_w),
        .oneshot(oneshot_w)
    );

    // BL616 SPI connector -- drives LED and WS2812 internally
    wire [4:0] mcu_led_w;
    wire       mcu_ws2812_w;
    wire       mcu_ready_w;
    wire       mcu_access_stb_w;  // any MCU SPI transaction (liveness watchdog feed)
    wire [47:0] mcu_scratch_w;   // 6 MCU scratch regs {s5,s4,s3,s2,s1,s0} (s5 = reg 0x6F)
`ifdef SMART_ZYNQ
    assign sz_tune_w      = mcu_scratch_w[31:8];   // regs 0x0E,0x0D,0x0C
    assign sz_probe_sel_w = mcu_scratch_w[34:32];  // reg 0x0F[2:0]
    assign sz_hold_w      = mcu_scratch_w[39:36];  // reg 0x0F[7:4]
    assign sz_early_w     = mcu_scratch_w[35];     // reg 0x0F[3]
    assign mcu_scratch_early_w = mcu_scratch_w[7:0];  // reg 0x07
    assign a2_sz_drive_fine = mcu_scratch_early_w;
    // D0-D7 drive options (rtl/a2_bus_phy.sv; U5 on the Rev 3.0 red card is a
    // TXB0108): reg 0x07[7] early start (drive when requested, not at PHI0),
    // [6:0] start delay after PHI0; reg 0x0D bit 6 soft landing, reg 0x0C bit 7
    // LSB first, reg 0x0E[7:4] clocks per bit (that field is the select-window
    // delay only when the window does not open at the early commit), reg 0x0D
    // bit 5 falling bits first (soft) / high first (immediate); reg 0x6F[0]
    // early release, [5:1] its delay after PHI1 rises, [6] open drain (TXS0108E
    // U5: drive the 0 bits only), [7] soft walk in weakest-line-first order.
    assign a2_sz_drive_cfg = {mcu_scratch_w[47:40], 1'b0, sz_tune_w[13], sz_tune_w[7], sz_tune_w[14], sz_tune_w[23:20]};
`endif

    // Uthernet2 (W5100) backing-store host link (SPI SPACE 3 <-> card port B)
    wire        u2_host_wr_w;
    wire [15:0] u2_host_addr_w;
    wire [7:0]  u2_host_wdata_w;
    wire [7:0]  u2_host_rdata_w;   // driven by the card
    wire [3:0]  u2_cmd_pending_w;  // driven by the card
    wire [3:0]  u2_cmd_clr_w;
    wire [15:0] u2_dbg_wr_count_w; // DEBUG: port-B write instrumentation (card -> connector)
    wire [15:0] u2_dbg_last_addr_w;
    wire [7:0]  u2_dbg_last_wdata_w;

    wire [7:0] ssc_ctl_w;
    wire       ssc_net_rx_pop_w, ssc_net_tx_push_w;   // SSC serial port <-> a2hostd
    wire [7:0] ssc_net_rx_data_w, ssc_net_tx_data_w;
    wire [9:0] ssc_net_rx_count_w, ssc_net_tx_free_w;

    // DIP switch 3 ON = Power-on-Reset hold: after power-on the Apple stays in
    // reset until a2hostd has set up the cards, so the boot scan finds them.
    // OFF = the Apple starts right away and the cards show up once a2hostd is
    // running (PR#6 then brings up the menu). Read live from the pin; it only
    // matters until a2hostd's first slot setup.
`ifdef SMART_ZYNQ
    reg [1:0] dip3_live_r = 2'b00;      // start out holding
    always @(posedge clk_logic_w) dip3_live_r <= {dip3_live_r[0], dip_live_n[2]};
    wire por_hold_w = !dip3_live_r[1];
`else
    wire por_hold_w = 1'b1;
`endif
    bl616_spi_connector #(
        .USE_CRC(0),
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
`ifdef SMART_ZYNQ
        .STANDALONE_FALLBACK_ENABLE(0),
        .HOST_MANAGED_RESET(1),
`else
        .STANDALONE_FALLBACK_ENABLE(1),
        .HOST_MANAGED_RESET(0),
`endif
        .VERSION_STR(`BUILD_DATETIME)
    ) bl616_spi (
        .ssc_ctl_i(ssc_ctl_w),
        .ssc_rx_pop_o(ssc_net_rx_pop_w),
        .ssc_rx_data_i(ssc_net_rx_data_w),
        .ssc_rx_count_i(ssc_net_rx_count_w),
        .ssc_tx_push_o(ssc_net_tx_push_w),
        .ssc_tx_data_o(ssc_net_tx_data_w),
        .ssc_tx_free_i(ssc_net_tx_free_w),
        .clk(clk_logic_w),
        .rst_n(device_reset_n_w),
        .spi_cs_n(spi_cs_n),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .a2bus_control_if(a2bus_control_if),
        .video_control_if(video_control_if),
        .slotmaker_config_if(slotmaker_config_if),
        .volumes(volumes),
        .hdd_volumes(hdd_volumes),
`ifdef VIDEO_FRAMEBUFFER
        .mem_if(storage_ports[0]),
`else
        .mem_if(mem_ports[MCU_MEM_PORT]),
`endif
        .sdram_init_complete_i(sdram_init_complete),
        .mcu_ready_o(mcu_ready_w),
        .standalone_o(standalone_w),
        .mcu_access_stb_o(mcu_access_stb_w),
        .scratch_o(mcu_scratch_w),
        .harness_o(harness_w),
        .test7_o(test7_w),
        .por_hold_i(por_hold_w),
        .phys_slot_i(phys_slot_w),
        .cardrom_active_i(1'b0),        // CardROM excised
        .cardrom_release_o(),           // CardROM excised
        .button_i(s2),
        .led_o(mcu_led_w),
        .ws2812_o(mcu_ws2812_w),
        .sd_clk_o(sd_clk),
        .sd_cmd_o(sd_cmd),
        .sd_dat0_i(sd_dat0),
        .sd_dat3_o(sd_dat3),
        .fifo_empty(fifo_empty_w),
        .fifo_full(fifo_full_w),
        .fifo_count(fifo_count_w),
        .fifo_rdata(fifo_rdata_w),
        .fifo_pop(fifo_pop_w),
        .capture_mode_o(capture_mode_w),
        .capture_enable_o(capture_enable_w),
        .oneshot_o(oneshot_w),
        .trig_enable_o(trig_enable_w),
        .trig_addr_o(trig_addr_w),
        .trig_mask_o(trig_mask_w),
        .trig_matched_i(trig_matched_w),
        .w5100_host_wr(u2_host_wr_w),
        .w5100_host_addr(u2_host_addr_w),
        .w5100_host_wdata(u2_host_wdata_w),
        .w5100_host_rdata(u2_host_rdata_w),
        .w5100_cmd_pending(u2_cmd_pending_w),
        .w5100_cmd_clr(u2_cmd_clr_w),
`ifdef SMART_ZYNQ
        // Regs 0x7B-0x7E carry the apple_bus counter picked by reg 0x0F.
        .w5100_dbg_wr_count({8'h00, sz_probe_w[7:0]}),
        .w5100_dbg_last_addr(sz_probe_w[23:8]),
        .w5100_dbg_last_wdata(sz_probe_w[31:24]),
`else
        .w5100_dbg_wr_count(u2_dbg_wr_count_w),
        .w5100_dbg_last_addr(u2_dbg_last_addr_w),
        .w5100_dbg_last_wdata(u2_dbg_last_wdata_w),
`endif
        .disk_nib_we_o(disk_nib_we_w),
        .disk_nib_drive_o(disk_nib_drive_w),
        .disk_nib_addr_o(disk_nib_addr_w),
        .disk_nib_data_o(disk_nib_data_w),
        .disk_nib_rdrive_o(disk_nib_rdrive_w),
        .disk_nib_raddr_o(disk_nib_raddr_w),
        .disk_nib_rdata_i(disk_nib_rdata_w),
        .hdd_buf_we_o(hdd_buf_we_w),
        .hdd_buf_addr_o(hdd_buf_addr_w),
        .hdd_buf_wdata_o(hdd_buf_wdata_w),
        .hdd_buf_rdata_i(hdd_buf_rdata_w),
        .menu_host_wr(disk_menu_wr_w),
        .menu_host_addr(disk_menu_addr_w),
        .menu_host_wdata(disk_menu_wdata_w),
        .menu_host_rdata(disk_menu_rdata_w),
        .osd_wr(osd_wr_w),
        .osd_addr(osd_addr_w),
        .osd_wdata(osd_wdata_w)
    );

    // WS2812 status LED: FPGA-side MCU liveness watchdog + boot-progression
    // colors from the stage codes the firmware already writes to scratch reg
    // 0x07. Replaces the raw reg-0x69 bit (mcu_ws2812_w), which no firmware
    // ever wrote and which can't speak the WS2812 serial protocol anyway.
    // Blinking red = MCU silent >10 s (wedged update / dead app region) — the
    // user-visible failure signal that needs no DebugOverlay.
    wire [23:0] mcu_led_rgb_w;

    mcu_status_led #(
        .CLK_HZ(CLOCK_SPEED_HZ)
    ) mcu_status_led_inst (
        .clk(clk_logic_w),
        .rst_n(device_reset_n_w),
        .mcu_access_stb_i(mcu_access_stb_w),
        .standalone_i(standalone_w),
        .stage_i(mcu_scratch_w[7:0]),
        .rgb_o(mcu_led_rgb_w)
    );

    ws2812 #(
        .CLK_FRE(CLOCK_SPEED_HZ)
    ) ws2812_inst (
        .clk(clk_logic_w),
        .rgb(mcu_led_rgb_w),
        .WS2812(ws2812)
    );

`else

    // Stub out the external interfaces if not using PicoSOC or BL616

    assign slotmaker_config_if.slot = 3'b0;
    assign slotmaker_config_if.wr = 1'b0;
    assign slotmaker_config_if.card_i = 8'b0;
    assign slotmaker_config_if.reconfig = 1'b0;

    // No BL616: Uthernet2 backing store has no host -- tie the link idle
    assign u2_host_wr_w    = 1'b0;
    assign u2_host_addr_w  = 16'b0;
    assign u2_host_wdata_w = 8'b0;
    assign u2_cmd_clr_w    = 4'b0;

    video_control_if video_control_if();
    assign video_control_if.enable = 1'b0;
    assign video_control_if.TEXT_MODE = 1'b0;
    assign video_control_if.MIXED_MODE = 1'b0;
    assign video_control_if.PAGE2 = 1'b0;
    assign video_control_if.HIRES_MODE = 1'b0;
    assign video_control_if.AN3 = 1'b0;
    assign video_control_if.STORE80 = 1'b0;
    assign video_control_if.COL80 = 1'b0;
    assign video_control_if.ALTCHAR = 1'b0;
    assign video_control_if.TEXT_COLOR = 4'b0;
    assign video_control_if.BACKGROUND_COLOR = 4'b0;
    assign video_control_if.BORDER_COLOR = 4'b0;
    assign video_control_if.MONOCHROME_MODE = 1'b0;
    assign video_control_if.MONOCHROME_DHIRES_MODE = 1'b0;
    assign video_control_if.SHRG_MODE = 1'b0;

    f18a_gpu_if f18a_gpu_if();
    assign f18a_gpu_if.running = 1'b0;
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = 1'b0;
    assign f18a_gpu_if.vaddr = 14'b0;
    assign f18a_gpu_if.vdout = 8'b0;
    assign f18a_gpu_if.pwe = 1'b0;
    assign f18a_gpu_if.paddr = 6'b0;
    assign f18a_gpu_if.pdout = 12'b0;
    assign f18a_gpu_if.rwe = 1'b0;
    assign f18a_gpu_if.raddr = 13'b0;
    assign f18a_gpu_if.gstatus = 7'b0;

    wire [7:0] diskii_d_w = 8'b0;
    wire diskii_rd = 1'b0;

    wire [7:0] hdd_d_w = 8'b0;
    wire hdd_rd = 1'b0;

    assign a2bus_control_if.ready = 1'b1;

    assign inh_n_w = 1'b1;   // CardROM excised


    assign spi_miso = 1'b1;
    assign ws2812 = 1'b0;
    assign sd_clk  = 1'b0;
    assign sd_cmd  = 1'b1;
    assign sd_dat3 = 1'b1;

`endif


    // Video

    // HDMI raster position (driven by the HDMI encoder, clk_pixel domain)
    wire [9:0] hdmi_x;
    wire [9:0] hdmi_y;

    // Apple-side RGB + active that feed the SuperSprite compositor. Driven by
    // the legacy raster-locked generators (USE_PIXEL_STREAM=0), the
    // pixel_stream / direct_display generators (USE_PIXEL_STREAM=1), or the
    // framebuffer writers (VIDEO_FRAMEBUFFER).
    wire [7:0] ssp_apple_r_w;
    wire [7:0] ssp_apple_g_w;
    wire [7:0] ssp_apple_b_w;
    wire       ssp_apple_active_w;

    // SuperSprite composited output + scanline flag (hoisted above the video
    // pipeline: the framebuffer writers consume rgb_*_w, which the SSP
    // produces further down)
    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;
    wire scanlines_w;

`ifdef VIDEO_FRAMEBUFFER

    // =====================================================================
    // Framebuffer path (the GS board's architecture): generators run in
    // Apple II native timing from scan_timer, SuperSprite composites in the
    // clk_logic domain inside the write path, and the SDRAM framebuffer is
    // read out at HDMI rate. Beam-racing software displays correctly, and
    // SDRAM fetch jitter lands in the buffer instead of on glass.
    // =====================================================================

    wire [8:0] scanline_w;
    wire       hsync_w;
    wire       vsync_w;

    wire [7:0] scan_dbg_vbl_correct_w;
    wire [7:0] scan_dbg_vertcnt_correct_w;

    scan_timer #(
        .VGC_VERTCNT_LOCK(1),
        .VGC_VBL_LOCK(1),
        .RESYNC_THRESHOLD(2)
    ) scan_timer (
        .a2bus_if(a2bus_if),
        .scanline_o(scanline_w),
        .hsync_o(hsync_w),
        .vsync_o(vsync_w),
        .pixel_o(),
        .dbg_vbl_correct_o(scan_dbg_vbl_correct_w),
        .dbg_vertcnt_correct_o(scan_dbg_vertcnt_correct_w)
    );

    // Border color: 4-bit palette index to RGB666, VDP backdrop override
    wire [3:0] vdp_border_r_w, vdp_border_g_w, vdp_border_b_w;
    wire vdp_border_active_w;

    wire border_gsp_w = a2bus_if.sw_gs;
    wire [4:0] border_idx_w = {border_gsp_w, a2mem_if.BORDER_COLOR};
    wire [11:0] border_palette_w [0:31];
    assign border_palette_w = '{
        12'h000, 12'h924, 12'h42a, 12'hd4e,   // Apple II  0-3
        12'h064, 12'h888, 12'h39e, 12'hcbf,   //           4-7
        12'h450, 12'hc73, 12'h888, 12'hfac,   //           8-11
        12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,   //          12-15
        12'h000, 12'hd03, 12'h009, 12'hd2d,   // IIgs      0-3
        12'h072, 12'h555, 12'h22f, 12'h6af,   //           4-7
        12'h850, 12'hf60, 12'haaa, 12'hf98,   //           8-11
        12'h1d0, 12'hff0, 12'h4f9, 12'hfff    //          12-15
    };
    wire [11:0] border_rgb444_w = border_palette_w[border_idx_w];
    wire [17:0] apple_border_rgb666_w = {
        border_rgb444_w[11:8], 2'b00,
        border_rgb444_w[7:4],  2'b00,
        border_rgb444_w[3:0],  2'b00
    };
    wire [17:0] vdp_border_rgb666_w = {vdp_border_r_w, 2'b00,
                                       vdp_border_g_w, 2'b00,
                                       vdp_border_b_w, 2'b00};
    wire [17:0] border_rgb666_w = vdp_border_active_w ? vdp_border_rgb666_w
                                                      : apple_border_rgb666_w;

    // --- Apple II generator -> framebuffer writer (SSP composited in) ---
    wire        fb_we_w;
    wire [17:0] fb_data_w;
    wire        fb_vsync_w;
    wire        vgc_fb_we_w;
    wire [17:0] vgc_fb_data_w;
    wire        vgc_fb_vsync_w;

    pixel_stream_if apple_ps();

    apple_video_gen #(
        .VRAM_READ_LATENCY(16),      // SDRAM via mem_port_cdc
        .PIXEL_START_TICK(10)        // fixed start for deterministic SSP overlay
    ) apple_video_gen (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),
        .sw_gs_i(sw_gs_w),

        .pixel_stream(apple_ps),

        .video_address_o(video_address_w),
        .video_bank_o(video_bank_w),
        .video_rd_o(video_rd_w),
        .video_data_i(video_data_w),
        .video_ready_i(video_ready_w)
    );

    framebuffer_writer #(
        .GAP_CYCLES(4)
    ) apple_fb_writer (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .pixel_stream(apple_ps),

        .scanline_i(scanline_w),
        .hsync_i(hsync_w),
        .vsync_i(vsync_w),

        .fb_we_o(fb_we_w),
        .fb_data_o(fb_data_w),
        .fb_vsync_o(fb_vsync_w),

        .apple_r_o(ssp_apple_r_w),
        .apple_g_o(ssp_apple_g_w),
        .apple_b_o(ssp_apple_b_w),
        .apple_active_o(ssp_apple_active_w),

        .ssp_r_i(rgb_r_w),
        .ssp_g_i(rgb_g_w),
        .ssp_b_i(rgb_b_w),
        .ssp_active_i(1'b1)
    );

    // --- VGC (SHR) generator -> its own framebuffer writer ---
    pixel_stream_if vgc_ps();

    vgc_gen vgc_gen (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),

        .pixel_stream(vgc_ps),

        .vgc_active_o(vgc_active_w),
        .vgc_address_o(vgc_address_w),
        .vgc_rd_o(vgc_rd_w),
        .vgc_data_i(vgc_data_w),
        .vgc_ready_i(vgc_ready_w),
        .dbg_missed_hsync_o()
    );

    framebuffer_writer #(
        .GAP_CYCLES(4)
    ) vgc_fb_writer (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .pixel_stream(vgc_ps),

        .scanline_i(scanline_w),
        .hsync_i(hsync_w),
        .vsync_i(vsync_w),

        .fb_we_o(vgc_fb_we_w),
        .fb_data_o(vgc_fb_data_w),
        .fb_vsync_o(vgc_fb_vsync_w),

        .apple_r_o(),
        .apple_g_o(),
        .apple_b_o(),
        .apple_active_o(),
        .ssp_r_i(8'd0),
        .ssp_g_i(8'd0),
        .ssp_b_i(8'd0),
        .ssp_active_i(1'b0)
    );

    // Framebuffer source mux — apple or SHR, latched at the frame boundary.
    // Must go through the video_control_if override: when the MCU takeover
    // (boot console / menu) forces text mode while the machine is in SHR
    // (GS/OS flips SHRG during boot), the console renders into the APPLE
    // plane — latching raw SHRG here kept displaying the stale VGC plane
    // as garbage.
    reg use_vgc_r;
    always @(posedge clk_logic_w) begin
        if (vsync_w) use_vgc_r <= video_control_if.shrg_mode(a2mem_if.SHRG_MODE);
    end

    wire fb_we_mux_w          = use_vgc_r ? vgc_fb_we_w    : fb_we_w;
    wire [17:0] fb_data_mux_w = use_vgc_r ? vgc_fb_data_w  : fb_data_w;
    wire fb_vsync_mux_w       = use_vgc_r ? vgc_fb_vsync_w : fb_vsync_w;

    wire [10:0] fb_width_w  = use_vgc_r ? 11'd640 : 11'd560;
    wire [9:0]  fb_height_w = use_vgc_r ? 10'd200 : 10'd192;

    // VDP raster counter for SuperSprite — synced to scan_timer; the f18a
    // `_fb` VHDL variants (selected by this config's file list) take this
    // external raster instead of free-running. HMAX matches f18a_vga_cont_fb.
    localparam VDP_HMAX = 10'd856;

    reg [9:0] vdp_cx;
    reg [1:0] vdp_div;

    always @(posedge clk_logic_w) begin
        if (hsync_w) begin
            vdp_cx <= 10'd0;
            vdp_div <= 2'd0;
        end else begin
            vdp_div <= vdp_div + 2'd1;
            if (vdp_div == 2'd3 && vdp_cx < VDP_HMAX) begin
                vdp_cx <= vdp_cx + 10'd1;
            end
        end
    end

    // SDRAM framebuffer: write accumulate (clk_logic) + line-fetch readout
    // at HDMI rate (clk_pixel)
    wire [7:0] fb_r_w, fb_g_w, fb_b_w;
    wire [7:0] fb_dbg_fifo_overflow_w;
    wire [7:0] fb_dbg_late_line_w;
    wire [7:0] fb_dbg_line_not_ready_w;
    wire [7:0] fb_dbg_line_lag_max_w;

    // Blank the display until there is meaningful content. The first frame
    // is rendered immediately from power-up SDRAM noise, so gating on the
    // first frame alone still flashed garbage; hold dark until the MCU
    // takeover asserts (console cleared and shown) or the Apple II has been
    // released from reset — whichever comes first — and a frame has been
    // written since.
    reg fb_display_live_r;
    always @(posedge clk_logic_w) begin
        if (!device_reset_n_w)
            fb_display_live_r <= 1'b0;
        else if (video_control_if.enable || !a2bus_control_if.reset_hold)
            fb_display_live_r <= 1'b1;
    end
    // Two vsyncs after going live = one COMPLETE frame painted in between.
    // Gating on the first vsync alone still flashed raw SDRAM noise: a
    // vsync is a frame boundary, not proof the writer has painted anything.
    reg [1:0] fb_seen_frame_cnt_r;
    always @(posedge clk_logic_w) begin
        if (!device_reset_n_w) fb_seen_frame_cnt_r <= 2'd0;
        else if (fb_display_live_r && fb_vsync_mux_w && fb_seen_frame_cnt_r != 2'd2)
            fb_seen_frame_cnt_r <= fb_seen_frame_cnt_r + 2'd1;
    end
    wire fb_seen_frame_r = (fb_seen_frame_cnt_r == 2'd2);
    reg fb_seen_frame_p1_r, fb_seen_frame_pix_r;
    always @(posedge clk_pixel_w) begin
        fb_seen_frame_p1_r  <= fb_seen_frame_r;
        fb_seen_frame_pix_r <= fb_seen_frame_p1_r;
    end

    sdram_framebuffer #(
        .TEST_PATTERN(0),
        .THRESHOLD_DIAG(0)
    ) sdram_framebuffer (
        .clk(clk_logic_w),
        .clk_pixel(clk_pixel_w),
        .rst_n(device_reset_n_w),

        .fb_vsync(fb_vsync_mux_w),
        .fb_we(fb_we_mux_w),
        .fb_data(fb_data_mux_w),
        .fb_width(fb_width_w),
        .fb_height(fb_height_w),

        .fb_write_port(mem_ports[FB_WRITE_PORT]),
        .fb_read_port(mem_ports[FB_READ_PORT]),

        .hdmi_cx({1'b0, hdmi_x}),
        .hdmi_cy(hdmi_y),

        .r_o(fb_r_w),
        .g_o(fb_g_w),
        .b_o(fb_b_w),

        .border_color(border_rgb666_w),
        .scanline_en(scanlines_w),
        .sleep_i(sleep_w),

        .dbg_fifo_overflow_o(fb_dbg_fifo_overflow_w),
        .dbg_late_line_o(fb_dbg_late_line_w),
        .dbg_line_not_ready_o(fb_dbg_line_not_ready_w),
        .dbg_line_lag_max_o(fb_dbg_line_lag_max_w)
    );

`else

    generate if (!USE_PIXEL_STREAM) begin : gen_legacy_video

        // -----------------------------------------------------------------
        // Legacy path: apple_video -> vgc, combinational on hdmi_x/hdmi_y in
        // the clk_pixel domain (the original A2N20v2-Enhanced pipeline).
        // -----------------------------------------------------------------
        wire apple_vga_active;
        wire [7:0] apple_vga_r;
        wire [7:0] apple_vga_g;
        wire [7:0] apple_vga_b;

        apple_video apple_video (
            .a2bus_if(a2bus_if),
            .a2mem_if(a2mem_if),

            .video_control_if(video_control_if),

            .screen_x_i(hdmi_x),
            .screen_y_i(hdmi_y),

            .video_address_o(video_address_w),
            .video_bank_o(video_bank_w),
            .video_rd_o(video_rd_w),
            .video_data_i(video_data_w),

            .video_active_o(apple_vga_active),
            .video_r_o(apple_vga_r),
            .video_g_o(apple_vga_g),
            .video_b_o(apple_vga_b)
        );

        wire [7:0] vgc_vga_r;
        wire [7:0] vgc_vga_g;
        wire [7:0] vgc_vga_b;

        vgc vgc (
            .a2bus_if(a2bus_if),
            .a2mem_if(a2mem_if),

            .video_control_if(video_control_if),

            .cx_i(hdmi_x),
            .cy_i(hdmi_y),

            .apple_vga_r_i(apple_vga_r),
            .apple_vga_g_i(apple_vga_g),
            .apple_vga_b_i(apple_vga_b),

            .vgc_vga_r_o(vgc_vga_r),
            .vgc_vga_g_o(vgc_vga_g),
            .vgc_vga_b_o(vgc_vga_b),

            .R_o(),
            .G_o(),
            .B_o(),

            .vgc_active_o(vgc_active_w),
            .vgc_address_o(vgc_address_w),
            .vgc_rd_o(vgc_rd_w),
            .vgc_data_i(vgc_data_w)
        );

        assign ssp_apple_r_w      = vgc_vga_r;
        assign ssp_apple_g_w      = vgc_vga_g;
        assign ssp_apple_b_w      = vgc_vga_b;
        assign ssp_apple_active_w = apple_vga_active;

    end else begin : gen_pixel_stream_video

        // -----------------------------------------------------------------
        // Pixel-stream path: apple_video_gen + vgc_gen run on clk_logic
        // (54 MHz) with direct_display supplying pixel_clk_en at the 27 MHz
        // display rate (PIX_CLK_DIV=2), HDMI-locked via cx_i/cy_i. Equivalent
        // to the legacy pipeline but through pixel_stream_if. The composited
        // Apple/SHR RGB is CDC'd back to clk_pixel for the SuperSprite
        // compositor.
        //
        // Unlike the plain a2n20v2 board, the Apple II VRAM read goes through
        // SDRAM (mem_port_if), so apple_video_gen uses a real video_ready_i
        // handshake (video_ready_w) rather than tying it high. The SHR aux
        // memory is BSRAM, so vgc_gen still uses a 2-cycle-delayed ready.
        // -----------------------------------------------------------------

        // CDC HDMI raster counters into clk_logic (synchronous 2:1 clocks)
        reg [9:0] hdmi_x_logic_r;
        reg [9:0] hdmi_y_logic_r;
        always @(posedge clk_logic_w) begin
            hdmi_x_logic_r <= hdmi_x;
            hdmi_y_logic_r <= hdmi_y;
        end

        // Border color: 4-bit palette index -> RGB444 (Apple II + IIgs palettes)
        wire border_gsp_w = a2bus_if.sw_gs;
        wire [4:0] border_idx_w = {border_gsp_w, a2mem_if.BORDER_COLOR};
        wire [11:0] border_palette_w [0:31];
        assign border_palette_w = '{
            12'h000, 12'h924, 12'h42a, 12'hd4e,
            12'h064, 12'h888, 12'h39e, 12'hcbf,
            12'h450, 12'hc73, 12'h888, 12'hfac,
            12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,
            12'h000, 12'hd03, 12'h009, 12'hd2d,
            12'h072, 12'h555, 12'h22f, 12'h6af,
            12'h850, 12'hf60, 12'haaa, 12'hf98,
            12'h1d0, 12'hff0, 12'h4f9, 12'hfff
        };
        wire [11:0] border_rgb444_w = border_palette_w[border_idx_w];
        // Match the generators' RGB888 format ({nibble,4'h0}) so the border
        // shade matches the same palette index inside the active window.
        wire [7:0] border_r_w = {border_rgb444_w[11:8], 4'h0};
        wire [7:0] border_g_w = {border_rgb444_w[7:4],  4'h0};
        wire [7:0] border_b_w = {border_rgb444_w[3:0],  4'h0};

        // --- Apple II generator + direct display ---
        pixel_stream_if apple_ps();

        apple_video_gen #(
            .VRAM_READ_LATENCY(16),  // SDRAM via mem_port_if
            // Fixed raster-locked output start. The SDRAM VRAM read has variable
            // priming latency (refresh/arbitration jitter), so PIXEL_START_TICK=0
            // let the line's first pixel begin "whenever the fetch finished",
            // shifting the whole line by 1 px when a refresh collided with the
            // first-chunk fetch — a 1-px band sweeping vertically as the 15us
            // refresh beat against the scanline rate. Holding output until a fixed
            // tick (> worst-case priming) raster-locks the start and removes the
            // jitter. Plain a2n20v2 keeps 0 (BSRAM = constant latency).
            .PIXEL_START_TICK(20)
            // Full NTSC color path (FORCE_MONOCHROME stays at module default 0).
        ) apple_video_gen (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),

            .a2mem_if(a2mem_if),
            .video_control_if(video_control_if),
            .sw_gs_i(sw_gs_w),

            .pixel_stream(apple_ps),

            .video_address_o(video_address_w),
            .video_bank_o(video_bank_w),
            .video_rd_o(video_rd_w),
            .video_data_i(video_data_w),
            .video_ready_i(video_ready_w)   // SDRAM read-data beat
        );

        wire [7:0] dd_apple_r_w, dd_apple_g_w, dd_apple_b_w;
        direct_display #(
            .PIX_CLK_DIV(2),
            .H_GEN_START(DD_APPLE_H_START)
        ) apple_direct (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),
            .pixel_stream(apple_ps),
            .cx_i(hdmi_x_logic_r),
            .cy_i(hdmi_y_logic_r),
            .border_r_i(border_r_w),
            .border_g_i(border_g_w),
            .border_b_i(border_b_w),
            .video_r_o(dd_apple_r_w),
            .video_g_o(dd_apple_g_w),
            .video_b_o(dd_apple_b_w)
        );

        // --- VGC (Super Hi-Res) generator + direct display ---
        pixel_stream_if vgc_ps();

        // Read-ready for vgc_gen comes from apple_memory_sdram: a fixed
        // 2-cycle sdpram32 latency in BSRAM mode, or the real SDRAM port
        // ready when VGC_IN_SDRAM (dual-rate config).

        vgc_gen vgc_gen (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),

            .a2mem_if(a2mem_if),
            .video_control_if(video_control_if),

            .pixel_stream(vgc_ps),

            .vgc_active_o(vgc_active_w),
            .vgc_address_o(vgc_address_w),
            .vgc_rd_o(vgc_rd_w),
            .vgc_data_i(vgc_data_w),
            .vgc_ready_i(vgc_ready_w),
            .dbg_missed_hsync_o()
        );

        wire [7:0] dd_vgc_r_w, dd_vgc_g_w, dd_vgc_b_w;
        direct_display #(
            .PIX_CLK_DIV(2),
            .WINDOW_WIDTH(640),
            .WINDOW_HEIGHT(400),     // 200 * 2
            .H_GEN_START(DD_VGC_H_START)
        ) vgc_direct (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),
            .pixel_stream(vgc_ps),
            .cx_i(hdmi_x_logic_r),
            .cy_i(hdmi_y_logic_r),
            .border_r_i(border_r_w),
            .border_g_i(border_g_w),
            .border_b_i(border_b_w),
            .video_r_o(dd_vgc_r_w),
            .video_g_o(dd_vgc_g_w),
            .video_b_o(dd_vgc_b_w)
        );

        // Select Apple II vs Super Hi-Res, latched once per frame. Goes
        // through the video_control_if override so the MCU takeover shows
        // the Apple plane (where the console/menu renders) even when the
        // machine itself is in SHR mode.
        reg use_vgc_r;
        always @(posedge clk_logic_w) begin
            if (apple_ps.vsync) use_vgc_r <= video_control_if.shrg_mode(a2mem_if.SHRG_MODE);
        end

        wire [7:0] ps_r_w      = use_vgc_r ? dd_vgc_r_w : dd_apple_r_w;
        wire [7:0] ps_g_w      = use_vgc_r ? dd_vgc_g_w : dd_apple_g_w;
        wire [7:0] ps_b_w      = use_vgc_r ? dd_vgc_b_w : dd_apple_b_w;
        wire       ps_active_w = use_vgc_r ? vgc_ps.active : apple_ps.active;

        // Register the composited pixel in clk_logic first, so the clk_pixel
        // sampler below captures a clean single-FF source rather than a deep
        // combinational chain (palette LUT -> active/border mux in
        // direct_display -> Apple/SHR mux here). Collapsing the cross-domain
        // launch path to a flop removes the per-pixel CDC timing hazard that
        // produced faint flicker on high-spatial-frequency content (80-column
        // text); lower-frequency content such as SHR masked it.
        reg [7:0] ps_r_logic_r, ps_g_logic_r, ps_b_logic_r;
        reg       ps_active_logic_r;
        always @(posedge clk_logic_w) begin
            ps_r_logic_r      <= ps_r_w;
            ps_g_logic_r      <= ps_g_w;
            ps_b_logic_r      <= ps_b_w;
            ps_active_logic_r <= ps_active_w;
        end

        // CDC clk_logic -> clk_pixel (synchronous 2:1 clocks)
        reg [7:0] ps_r_pix_r, ps_g_pix_r, ps_b_pix_r;
        reg       ps_active_pix_r;
        always @(posedge clk_pixel_w) begin
            ps_r_pix_r      <= ps_r_logic_r;
            ps_g_pix_r      <= ps_g_logic_r;
            ps_b_pix_r      <= ps_b_logic_r;
            ps_active_pix_r <= ps_active_logic_r;
        end

        assign ssp_apple_r_w      = ps_r_pix_r;
        assign ssp_apple_g_w      = ps_g_pix_r;
        assign ssp_apple_b_w      = ps_b_pix_r;
        assign ssp_apple_active_w = ps_active_pix_r;

    end endgenerate

`endif  // !VIDEO_FRAMEBUFFER

    wire [15:0] sg_audio_l;
    wire [15:0] sg_audio_r;
    wire [7:0] glu_drops_w;     // GLU write-queue drops (diagnostics)
`ifdef ENSONIQ
    wire [7:0] sg_d_w;
    wire sg_rd_w;
    wire [7:0] doc_osc_en_w;   // Debug signal for DOC oscillator enable register
    wire [1:0] doc_osc_mode_w[8];
    wire [7:0]  doc_osc_halt_w;

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE),
        .MONO_MIX(ENSONIQ_MONO_MIX) // If true, mono mix is used instead of stereo
    ) sg (
        .a2bus_if(a2bus_if),
        .data_o(sg_d_w),                 
        .rd_en_o(sg_rd_w),

        .audio_l_o(sg_audio_l),               
        .audio_r_o(sg_audio_r),

        .debug_osc_en_o(doc_osc_en_w),   // Capture oscillator enable register value
        .debug_osc_mode_o(doc_osc_mode_w), // Capture oscillator mode register values
        .debug_osc_halt_o(doc_osc_halt_w), // Capture oscillator halt register value
    
        .glu_mem_if(mem_ports[GLU_MEM_PORT]),
        .doc_mem_if(mem_ports[DOC_MEM_PORT]),
        .glu_wq_drops_o(glu_drops_w)
    );
`else
    assign glu_drops_w = 8'd0;
    assign sg_audio_l = 16'b0;
    assign sg_audio_r = 16'b0;
    wire [7:0] doc_osc_en_w = 8'h00; // Default value when ENSONIQ is disabled
`endif

    // SuperSprite

    wire VDP_OVERLAY_SW;
    wire APPLE_VIDEO_SW;
    wire [0:7] ssp_d_w;
    wire ssp_rd;
    wire [3:0] vdp_r;
    wire [3:0] vdp_g;
    wire [3:0] vdp_b;
    wire vdp_transparent;
    wire vdp_ext_video;
    wire vdp_irq_n;
    wire [9:0] ssp_audio_w;
    wire vdp_unlocked_w;
    wire [3:0] vdp_gmode_w;
    // (rgb_*_w and scanlines_w are declared above the video pipeline)

    SuperSprite #(
        .ENABLE(SUPERSPRITE_ENABLE),
        .ID(SUPERSPRITE_ID),
        .FORCE_VDP_OVERLAY(SUPERSPRITE_FORCE_VDP_OVERLAY)
    ) supersprite (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),

        .data_o(ssp_d_w),
        .rd_en_o(ssp_rd),
        .irq_n_o(vdp_irq_n),

`ifdef VIDEO_FRAMEBUFFER
        // clk_logic domain, raster from scan_timer (f18a _fb variants)
        .screen_x_i(vdp_cx),
        .screen_y_i({1'b0, scanline_w}),
`else
        .screen_x_i(hdmi_x),
        .screen_y_i(hdmi_y),
`endif
        .apple_vga_r_i(ssp_apple_r_w),
        .apple_vga_g_i(ssp_apple_g_w),
        .apple_vga_b_i(ssp_apple_b_w),
        .apple_vga_active_i(ssp_apple_active_w),

        .scanlines_i(SCANLINES_ENABLE | sw_scanlines_w),

        .ssp_r_o(rgb_r_w),
        .ssp_g_o(rgb_g_w),
        .ssp_b_o(rgb_b_w),

        .scanlines_o(scanlines_w),

        .vdp_ext_video_o(vdp_ext_video),
        .vdp_unlocked_o(vdp_unlocked_w),
        .vdp_gmode_o(vdp_gmode_w),

`ifdef VIDEO_FRAMEBUFFER
        .vdp_border_r_o(vdp_border_r_w),
        .vdp_border_g_o(vdp_border_g_w),
        .vdp_border_b_o(vdp_border_b_w),
        .vdp_border_active_o(vdp_border_active_w),
`endif

        .f18a_gpu_if(f18a_gpu_if),

        .ssp_audio_o(ssp_audio_w)
    );

    // Mockingboard

    wire [7:0] mb_d_w;
    wire mb_rd;
    wire mb_irq_n;
    wire [9:0] mb_audio_l;
    wire [9:0] mb_audio_r;

    Mockingboard #(
        .ENABLE(MOCKINGBOARD_ENABLE),
        .ID(MOCKINGBOARD_ID)
    ) mockingboard (
        .a2bus_if(a2bus_if),  // use system_reset_n
        .slot_if(slot_if),

        .data_o(mb_d_w),
        .rd_en_o(mb_rd),
        .irq_n_o(mb_irq_n),

        .audio_l_o(mb_audio_l),
        .audio_r_o(mb_audio_r)
    );

    // SuperSerial Card

    wire [7:0] ssc_d_w;
    wire ssc_rd;
    wire ssc_irq_n;
    wire ssc_rom_en;

    wire ssc_uart_rx;
    wire ssc_uart_tx;
    assign uart_tx = ssc_uart_tx;
    // The card's serial port goes to a2hostd (TCP port 6551 on the board), not to
    // the board's uart_rx/uart_tx pins (unconnected on Smart-Zynq).
    ssc_net_bridge #(.CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)) ssc_net (
        .clk(clk_logic_w),
        .rst_n(system_reset_n_w),
        .ssc_ctl_i(ssc_ctl_w),
        .ssc_tx_i(ssc_uart_tx),
        .ssc_rx_o(ssc_uart_rx),
        .rx_pop_i(ssc_net_rx_pop_w),
        .rx_data_o(ssc_net_rx_data_w),
        .rx_count_o(ssc_net_rx_count_w),
        .tx_push_i(ssc_net_tx_push_w),
        .tx_data_i(ssc_net_tx_data_w),
        .tx_free_o(ssc_net_tx_free_w)
    );

    SuperSerial #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE(SUPERSERIAL_ENABLE),
        .IRQ_ENABLE(SUPERSERIAL_IRQ_ENABLE),
        .ID(SUPERSERIAL_ID)
    ) superserial (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .slot_if(slot_if),

        .data_o(ssc_d_w),
        .rd_en_o(ssc_rd),
        .irq_n_o(ssc_irq_n),

        .rom_en_o(ssc_rom_en),
        .uart_rx_i(ssc_uart_rx),
        .uart_tx_o(ssc_uart_tx),
        .ssc_ctl_o(ssc_ctl_w)
    );

    // Uthernet II (W5100) Ethernet card

    wire [7:0] u2_d_w;
    wire u2_rd;
    wire u2_irq_n;

    Uthernet2 #(
        .ENABLE(UTHERNET2_ENABLE),
        .ID(UTHERNET2_ID)
    ) uthernet2 (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),

        .data_o(u2_d_w),
        .rd_en_o(u2_rd),
        .irq_n_o(u2_irq_n),

        .w5100_host_wr(u2_host_wr_w),
        .w5100_host_addr(u2_host_addr_w),
        .w5100_host_wdata(u2_host_wdata_w),
        .w5100_host_rdata(u2_host_rdata_w),
        .cmd_pending_o(u2_cmd_pending_w),
        .cmd_pending_clr(u2_cmd_clr_w),
        .dbg_portb_wr_count(u2_dbg_wr_count_w),
        .dbg_portb_last_addr(u2_dbg_last_addr_w),
        .dbg_portb_last_wdata(u2_dbg_last_wdata_w)
    );

    // Data output

    // Self-test harness (reg 0x2E bit 2, test use only): with /INH asserted the
    // IIe's ROM and language card are off the bus at $D000-$FFFF and this
    // 256-byte ROM (mirrored) answers instead. Every vector points to $FF00,
    // which resets the IIe memory switches and stack, counts the restart at
    // $0330 and jumps into the Disk II P5 ROM's nibble loop ($C55E, X=$50):
    // every bus cycle a card read. A card-forced Apple reset therefore always
    // restarts the stress loop, whatever state a crash left behind.
    function automatic [7:0] harness_byte(input [7:0] a);
        case (a)
            8'h00: harness_byte = 8'h78;  // SEI
            8'h01: harness_byte = 8'hD8;  // CLD
            8'h02: harness_byte = 8'h8D;  8'h03: harness_byte = 8'h06;  8'h04: harness_byte = 8'hC0;  // STA $C006
            8'h05: harness_byte = 8'h8D;  8'h06: harness_byte = 8'h08;  8'h07: harness_byte = 8'hC0;  // STA $C008
            8'h08: harness_byte = 8'h8D;  8'h09: harness_byte = 8'h02;  8'h0A: harness_byte = 8'hC0;  // STA $C002
            8'h0B: harness_byte = 8'h8D;  8'h0C: harness_byte = 8'h04;  8'h0D: harness_byte = 8'hC0;  // STA $C004
            8'h0E: harness_byte = 8'h8D;  8'h0F: harness_byte = 8'h00;  8'h10: harness_byte = 8'hC0;  // STA $C000
            8'h11: harness_byte = 8'hA2;  8'h12: harness_byte = 8'hFF;                                // LDX #$FF
            8'h13: harness_byte = 8'h9A;                                                               // TXS
            8'h14: harness_byte = 8'hEE;  8'h15: harness_byte = 8'h30;  8'h16: harness_byte = 8'h03;  // INC $0330
            8'h17: harness_byte = 8'hA2;  8'h18: harness_byte = 8'h50;                                // LDX #$50
            8'h19: harness_byte = 8'h4C;  8'h1A: harness_byte = 8'h5E;  8'h1B: harness_byte = 8'hC5;  // JMP $C55E
            8'hFB, 8'hFD, 8'hFF: harness_byte = 8'hFF;   // NMI / RESET / IRQ vectors -> $FF00
            default: harness_byte = 8'h00;               // BRK
        endcase
    endfunction
    wire harness_rd = harness_w && a2bus_if.phi0 && a2bus_if.rw_n && (a2bus_if.addr[15:12] >= 4'hD);

    // Autostart test ROM (reg 0x2E bit 3, test use only): answers $C700-$C7FF
    // with a Disk II style boot signature, so an IIe cold start boots it. Needs
    // no /INH (this IIe does not honour it) and never touches $C08x (a crash
    // that switched the language card in left the IIe needing a power cycle).
    // $C700: boot signature; SEI/CLD; LDA $C082 (ROM); $3F4=0 (next reset is a
    // cold start); BRK vector $3F0 -> $C700; S=$FF; marker STA $C090; CLV; BVC.
    // $C730: 40 x LDA $F8vv, vv = the byte values under test, then CLV / BVC
    // $C730. Every opcode and operand is a card read; a misread operand only
    // moves the load to another monitor ROM address (the capture shows which
    // byte arrived wrong), a misread AD stays a 3-byte read, and a bad branch
    // lands in this page, where the $00 fill restarts the test via BRK.
    // Values: 00 BD 9D 7E F8 FE FD FB F7 EF DF BF 7F FF 78 3E 3C BA D7 E6 87 C9 A5 A9 AA 55 B1 8B 3F F0 0F 1E E1 CC 33 66 99 C3 5A 01
    function automatic [7:0] test7_byte(input [7:0] a);
        case (a)
            8'h00: test7_byte = 8'hA2;
            8'h01: test7_byte = 8'h20;
            8'h02: test7_byte = 8'hA0;
            8'h04: test7_byte = 8'hA2;
            8'h05: test7_byte = 8'h03;
            8'h06: test7_byte = 8'h86;
            8'h07: test7_byte = 8'h3C;
            8'h08: test7_byte = 8'h78;
            8'h09: test7_byte = 8'hD8;
            8'h0A: test7_byte = 8'hAD;
            8'h0B: test7_byte = 8'h82;
            8'h0C: test7_byte = 8'hC0;
            8'h0D: test7_byte = 8'hA9;
            8'h0F: test7_byte = 8'h8D;
            8'h10: test7_byte = 8'hF4;
            8'h11: test7_byte = 8'h03;
            8'h12: test7_byte = 8'h8D;
            8'h13: test7_byte = 8'hF0;
            8'h14: test7_byte = 8'h03;
            8'h15: test7_byte = 8'hA9;
            8'h16: test7_byte = 8'hC7;
            8'h17: test7_byte = 8'h8D;
            8'h18: test7_byte = 8'hF1;
            8'h19: test7_byte = 8'h03;
            8'h1A: test7_byte = 8'hA2;
            8'h1B: test7_byte = 8'hFF;
            8'h1C: test7_byte = 8'h9A;
            8'h1D: test7_byte = 8'h8D;
            8'h1E: test7_byte = 8'h90;
            8'h1F: test7_byte = 8'hC0;
            8'h20: test7_byte = 8'hB8;
            8'h21: test7_byte = 8'h50;
            8'h22: test7_byte = 8'h0D;
            8'h30: test7_byte = 8'hAD;
            8'h32: test7_byte = 8'hF8;
            8'h33: test7_byte = 8'hAD;
            8'h34: test7_byte = 8'hBD;
            8'h35: test7_byte = 8'hF8;
            8'h36: test7_byte = 8'hAD;
            8'h37: test7_byte = 8'h9D;
            8'h38: test7_byte = 8'hF8;
            8'h39: test7_byte = 8'hAD;
            8'h3A: test7_byte = 8'h7E;
            8'h3B: test7_byte = 8'hF8;
            8'h3C: test7_byte = 8'hAD;
            8'h3D: test7_byte = 8'hF8;
            8'h3E: test7_byte = 8'hF8;
            8'h3F: test7_byte = 8'hAD;
            8'h40: test7_byte = 8'hFE;
            8'h41: test7_byte = 8'hF8;
            8'h42: test7_byte = 8'hAD;
            8'h43: test7_byte = 8'hFD;
            8'h44: test7_byte = 8'hF8;
            8'h45: test7_byte = 8'hAD;
            8'h46: test7_byte = 8'hFB;
            8'h47: test7_byte = 8'hF8;
            8'h48: test7_byte = 8'hAD;
            8'h49: test7_byte = 8'hF7;
            8'h4A: test7_byte = 8'hF8;
            8'h4B: test7_byte = 8'hAD;
            8'h4C: test7_byte = 8'hEF;
            8'h4D: test7_byte = 8'hF8;
            8'h4E: test7_byte = 8'hAD;
            8'h4F: test7_byte = 8'hDF;
            8'h50: test7_byte = 8'hF8;
            8'h51: test7_byte = 8'hAD;
            8'h52: test7_byte = 8'hBF;
            8'h53: test7_byte = 8'hF8;
            8'h54: test7_byte = 8'hAD;
            8'h55: test7_byte = 8'h7F;
            8'h56: test7_byte = 8'hF8;
            8'h57: test7_byte = 8'hAD;
            8'h58: test7_byte = 8'hFF;
            8'h59: test7_byte = 8'hF8;
            8'h5A: test7_byte = 8'hAD;
            8'h5B: test7_byte = 8'h78;
            8'h5C: test7_byte = 8'hF8;
            8'h5D: test7_byte = 8'hAD;
            8'h5E: test7_byte = 8'h3E;
            8'h5F: test7_byte = 8'hF8;
            8'h60: test7_byte = 8'hAD;
            8'h61: test7_byte = 8'h3C;
            8'h62: test7_byte = 8'hF8;
            8'h63: test7_byte = 8'hAD;
            8'h64: test7_byte = 8'hBA;
            8'h65: test7_byte = 8'hF8;
            8'h66: test7_byte = 8'hAD;
            8'h67: test7_byte = 8'hD7;
            8'h68: test7_byte = 8'hF8;
            8'h69: test7_byte = 8'hAD;
            8'h6A: test7_byte = 8'hE6;
            8'h6B: test7_byte = 8'hF8;
            8'h6C: test7_byte = 8'hAD;
            8'h6D: test7_byte = 8'h87;
            8'h6E: test7_byte = 8'hF8;
            8'h6F: test7_byte = 8'hAD;
            8'h70: test7_byte = 8'hC9;
            8'h71: test7_byte = 8'hF8;
            8'h72: test7_byte = 8'hAD;
            8'h73: test7_byte = 8'hA5;
            8'h74: test7_byte = 8'hF8;
            8'h75: test7_byte = 8'hAD;
            8'h76: test7_byte = 8'hA9;
            8'h77: test7_byte = 8'hF8;
            8'h78: test7_byte = 8'hAD;
            8'h79: test7_byte = 8'hAA;
            8'h7A: test7_byte = 8'hF8;
            8'h7B: test7_byte = 8'hAD;
            8'h7C: test7_byte = 8'h55;
            8'h7D: test7_byte = 8'hF8;
            8'h7E: test7_byte = 8'hAD;
            8'h7F: test7_byte = 8'hB1;
            8'h80: test7_byte = 8'hF8;
            8'h81: test7_byte = 8'hAD;
            8'h82: test7_byte = 8'h8B;
            8'h83: test7_byte = 8'hF8;
            8'h84: test7_byte = 8'hAD;
            8'h85: test7_byte = 8'h3F;
            8'h86: test7_byte = 8'hF8;
            8'h87: test7_byte = 8'hAD;
            8'h88: test7_byte = 8'hF0;
            8'h89: test7_byte = 8'hF8;
            8'h8A: test7_byte = 8'hAD;
            8'h8B: test7_byte = 8'h0F;
            8'h8C: test7_byte = 8'hF8;
            8'h8D: test7_byte = 8'hAD;
            8'h8E: test7_byte = 8'h1E;
            8'h8F: test7_byte = 8'hF8;
            8'h90: test7_byte = 8'hAD;
            8'h91: test7_byte = 8'hE1;
            8'h92: test7_byte = 8'hF8;
            8'h93: test7_byte = 8'hAD;
            8'h94: test7_byte = 8'hCC;
            8'h95: test7_byte = 8'hF8;
            8'h96: test7_byte = 8'hAD;
            8'h97: test7_byte = 8'h33;
            8'h98: test7_byte = 8'hF8;
            8'h99: test7_byte = 8'hAD;
            8'h9A: test7_byte = 8'h66;
            8'h9B: test7_byte = 8'hF8;
            8'h9C: test7_byte = 8'hAD;
            8'h9D: test7_byte = 8'h99;
            8'h9E: test7_byte = 8'hF8;
            8'h9F: test7_byte = 8'hAD;
            8'hA0: test7_byte = 8'hC3;
            8'hA1: test7_byte = 8'hF8;
            8'hA2: test7_byte = 8'hAD;
            8'hA3: test7_byte = 8'h5A;
            8'hA4: test7_byte = 8'hF8;
            8'hA5: test7_byte = 8'hAD;
            8'hA6: test7_byte = 8'h01;
            8'hA7: test7_byte = 8'hF8;
            8'hA8: test7_byte = 8'hB8;
            8'hA9: test7_byte = 8'h50;
            8'hAA: test7_byte = 8'h85;
            default: test7_byte = 8'h00;                                                          // BRK
        endcase
    endfunction
    wire test7_rd = test7_w && a2bus_if.phi0 && a2bus_if.rw_n && (a2bus_if.addr[15:8] == 8'hC7);

    assign data_out_en_w = test7_rd || harness_rd || ssp_rd || mb_rd || ssc_rd || u2_rd || diskii_rd || hdd_rd;

    assign data_out_w = test7_rd ? test7_byte(a2bus_if.addr[7:0]) :
        harness_rd ? harness_byte(a2bus_if.addr[7:0]) :
        ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w :
        mb_rd ? mb_d_w :
        u2_rd ? u2_d_w :
        diskii_rd ? diskii_d_w :
        hdd_rd ? hdd_d_w :
        a2bus_if.data;

    // Interrupts

    assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n && u2_irq_n;

    // Audio

    wire speaker_audio_w;

    apple_speaker apple_speaker (
        .a2bus_if(a2bus_if),
        .enable(APPLE_SPEAKER_ENABLE | sw_apple_speaker_w),
        .speaker_o(speaker_audio_w)
    );

    // Extend all the unsigned audio signals to 13 bits
    wire [12:0] speaker_audio_ext_w = {speaker_audio_w, 12'b0};
    wire [12:0] ssp_audio_ext_w = {ssp_audio_w, 3'b0};
    wire [12:0] mb_audio_l_ext_w = {mb_audio_l, 3'b0};
    wire [12:0] mb_audio_r_ext_w = {mb_audio_r, 3'b0};

    wire signed [15:0] core_audio_l_w;
    wire signed [15:0] core_audio_r_w;
    // Combine all the audio sources into a single 16-bit signed audio signal
    // This could theoretically overflow by 1 bit and clip, but unlikely
    assign core_audio_l_w = sg_audio_l + ssp_audio_ext_w + mb_audio_l_ext_w + speaker_audio_ext_w;
    assign core_audio_r_w = sg_audio_r + ssp_audio_ext_w + mb_audio_r_ext_w + speaker_audio_ext_w;

    // CDC to shift audio to the pixel clock domain from the logic clock domain

`ifdef DUAL_RATE_SDRAM
    // Audio CDC: 54 MHz (CLKDIV2) -> 108 MHz (PLL CLKOUT) -> 27 MHz (PLL CLKOUTD)
    //
    // Stage 1: 54->108 MHz is safe because CLKDIV2 guarantees every 54 MHz edge
    //          IS a 108 MHz edge. The 108 MHz register captures stable data.
    // Stage 2: 108->27 MHz is safe because both come from the same PLL
    //          (CLKOUT and CLKOUTD), with PLL-guaranteed phase alignment.
    //
    // A direct 54->27 MHz cdc_sampling would be broken here because CLKDIV2
    // output (54 MHz) and PLL CLKOUTD (27 MHz) don't have a PLL-guaranteed
    // phase relationship — their alignment depends on the asynchronous
    // CLKDIV2 RESETN timing. (See the identical structure in the GS board.)

    // Register the 4-input adder result to break the timing path
    reg signed [15:0] core_audio_l_r, core_audio_r_r;
    always @(posedge clk_logic_w) begin
        core_audio_l_r <= core_audio_l_w;
        core_audio_r_r <= core_audio_r_w;
    end

    // Stage 1: 54 MHz -> 108 MHz (CLKDIV2 alignment guarantee)
    reg signed [15:0] audio_l_sdram_r, audio_r_sdram_r;
    always @(posedge clk_sdram_w) begin
        audio_l_sdram_r <= core_audio_l_r;
        audio_r_sdram_r <= core_audio_r_r;
    end

    // Stage 2: 108 MHz -> 27 MHz (PLL CLKOUT/CLKOUTD phase guarantee)
    reg [15:0] cdc_audio_l, cdc_audio_r;
    always @(posedge clk_pixel_w) begin
        cdc_audio_l <= audio_l_sdram_r;
        cdc_audio_r <= audio_r_sdram_r;
    end
`else
    wire [15:0] cdc_audio_l;
    wire [15:0] cdc_audio_r;

    cdc_sampling #(
        .WIDTH(16)
    ) audio_cdc_left (
        .rst_n(device_reset_n_w),
        .clk_fast(clk_logic_w),
        .clk_slow(clk_pixel_w),
        .data_in(core_audio_l_w),
        .data_out(cdc_audio_l)
    );

    cdc_sampling #(
        .WIDTH(16)
    ) audio_cdc_right (
        .rst_n(device_reset_n_w),
        .clk_fast(clk_logic_w),
        .clk_slow(clk_pixel_w),
        .data_in(core_audio_r_w),
        .data_out(cdc_audio_r)
    );
`endif

    localparam [31:0] aflt_rate = 7_056_000;
    localparam [39:0] acx  = 4258969;
    localparam  [7:0] acx0 = 3;
    localparam  [7:0] acx1 = 3;
    localparam  [7:0] acx2 = 1;
    localparam [23:0] acy0 = -24'd6216759;
    localparam [23:0] acy1 =  24'd6143386;
    localparam [23:0] acy2 = -24'd2023767;

    localparam AUDIO_RATE = 44100;
    localparam AUDIO_BIT_WIDTH = 16;
    wire clk_audio_w;
    audio_timing #(
        .CLK_RATE(CLOCK_SPEED_HZ / 2),
        .AUDIO_RATE(AUDIO_RATE)
    ) audio_timing (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),
        .audio_clk(clk_audio_w),
        .i2s_bclk(),
        .i2s_lrclk(),
        .i2s_data_shift_strobe(),
        .i2s_data_load_strobe()
    );

    wire [15:0] audio_sample_word[1:0];
    audio_out #(
        .CLK_RATE(CLOCK_SPEED_HZ / 2),
        .AUDIO_RATE(AUDIO_RATE)
    ) audio_out
    (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),

        .flt_rate(aflt_rate),
        .cx(acx),
        .cx0(acx0),
        .cx1(acx1),
        .cx2(acx2),
        .cy0(acy0),
        .cy1(acy1),
        .cy2(acy2),

        .is_signed(1'b1),
        .core_l(cdc_audio_l),
        .core_r(cdc_audio_r),

        .audio_clk(clk_audio_w),
        .audio_l(audio_sample_word[0]),
        .audio_r(audio_sample_word[1])
    );

    // HDMI

    wire scanline_en = scanlines_w && hdmi_y[0];

    reg show_debug_overlay_r = 1'b0;

    // DIP switch 4 ON hides the debug numbers (unless it's the IIgs switch,
    // DIP4_IIGS_MODE = 1). Read live from the pin, so it takes effect as soon
    // as the switch is flipped; the other switches are read once at start-up.
    reg [1:0] dip4_live_r = 2'b11;
`ifdef SMART_ZYNQ
    always @(posedge clk_pixel_w) dip4_live_r <= {dip4_live_r[0], dip_live_n[3]};
`endif
    wire hide_debug_overlay_w = !DIP4_IIGS_MODE && !dip4_live_r[1];

    wire [7:0] debug_r_w;
    wire [7:0] debug_g_w;
    wire [7:0] debug_b_w;
    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),  // 14-digit timestamp version
        .ENABLE(1'b1)
    ) debug_overlay (
        .clk_i          (clk_pixel_w),
        .reset_n (device_reset_n_w),
        .enable_i((FORCE_DEBUG_OVERLAY ? 1'b1 : show_debug_overlay_r) && !hide_debug_overlay_w),

        // MCU/BL616 debug instrumentation: 5 scratch regs (0x07,0x0C-0x0F) the
        // firmware writes over SPI. hex[0]=stage, [1]=btn-lo, [2]=btn-hi,
        // [3]=event counter (heartbeat), [4]=status flags.
`ifdef VIDEO_FRAMEBUFFER
        // Framebuffer diagnostics: overlay shows the glitch counters live.
        // hex[0]=fw stage, [1]=heartbeat, [2]=CAPTURED AUX/SHR WRITES
        // (rolling; frozen while an SHR game draws = writes not reaching
        // the bus capture), [3]=CAPTURED M2B0 WRITES (IIgs bank-E1 style),
        // [4]=line not ready, [5]=max line lag, [6]=shadow write-queue
        // drops, [7]=GLU write-queue drops.
        .hex_values ({
            mcu_scratch_w[7:0],
            mcu_scratch_w[31:24],
            aux_wr_cnt_w,
            m2b0_wr_cnt_w,
            fb_dbg_line_not_ready_w,
            fb_dbg_line_lag_max_w,
            wq_drops_w,
            glu_drops_w
        }),
`else
        // Smart-Zynq / no-framebuffer diagnostics (no BL616 scratch traffic):
        // hex[0]=TEXT soft-switch, [1]=HIRES, [2]=PAGE2, [3]=SHRG,
        // [4]=shadow write-queue drops, [5]=Apple /RES sense (1=released),
        // [6]=slot 5V sense, [7]=0
        .hex_values ({
            {7'b0, a2mem_if.TEXT_MODE},
            {7'b0, a2mem_if.HIRES_MODE},
            {7'b0, a2mem_if.PAGE2},
            {7'b0, a2mem_if.SHRG_MODE},
            wq_drops_w,
            {7'b0, a2_reset_cdc_w},
`ifdef SMART_ZYNQ
            {7'b0, apple_powered_w},
`else
            8'h0,
`endif
            8'h0
        }),
`endif

        // Bit row 0 = what the FPGA + firmware think the MCU is doing:
        //   bit0 = mcu_ready (FPGA saw MCU register traffic), bit1 = standalone
        //   (watchdog fired, no MCU), bits2-7 = firmware status flags (scratch4).
        .debug_bits_0_i ({mcu_scratch_w[37:32], standalone_w, mcu_ready_w}),
`ifdef VIDEO_FRAMEBUFFER
        // Bit row 1 = LIVE captured Apple II soft switches, MSB first:
        // {TEXT, MIXED, HIRES, PAGE2, COL80, STORE80, SHRG, LINEARIZE} —
        // lets a wrong-boot-state be compared against post-reset on glass.
        .debug_bits_1_i ({a2mem_if.TEXT_MODE, a2mem_if.MIXED_MODE,
                          a2mem_if.HIRES_MODE, a2mem_if.PAGE2,
                          a2mem_if.COL80, a2mem_if.STORE80,
                          a2mem_if.SHRG_MODE, a2mem_if.LINEARIZE_MODE}),
`else
        // Smart-Zynq: live soft switches (same layout as framebuffer build).
        .debug_bits_1_i ({a2mem_if.TEXT_MODE, a2mem_if.MIXED_MODE,
                          a2mem_if.HIRES_MODE, a2mem_if.PAGE2,
                          a2mem_if.COL80, a2mem_if.STORE80,
                          a2mem_if.SHRG_MODE, a2mem_if.LINEARIZE_MODE}),
`endif

        .screen_x_i     (hdmi_x),
        .screen_y_i     (hdmi_y),

`ifdef VIDEO_FRAMEBUFFER
        // Framebuffer readout (clk_pixel); the scanline effect is applied
        // inside sdram_framebuffer via its scanline_en input.
        .r_i            (fb_seen_frame_pix_r ? fb_r_w : 8'h00),
        .g_i            (fb_seen_frame_pix_r ? fb_g_w : 8'h00),
        .b_i            (fb_seen_frame_pix_r ? fb_b_w : 8'h00),
`else
        .r_i            (scanline_en ? {1'b0, rgb_r_w[7:1]} : rgb_r_w),
        .g_i            (scanline_en ? {1'b0, rgb_g_w[7:1]} : rgb_g_w),
        .b_i            (scanline_en ? {1'b0, rgb_b_w[7:1]} : rgb_b_w),
`endif

        .r_o            (debug_r_w),
        .g_o            (debug_g_w),
        .b_o            (debug_b_w)
    );  

    // a2hostd notice line (disk swaps) below the Apple window, SPI space 5
    wire [7:0] osd_r_w, osd_g_w, osd_b_w;
`ifdef BL616_SPI
    osd_line osd_line (
        .clk_pixel(clk_pixel_w),
        .cx(hdmi_x[9:0]),
        .cy(hdmi_y[9:0]),
        .r_i(debug_r_w), .g_i(debug_g_w), .b_i(debug_b_w),
        .r_o(osd_r_w), .g_o(osd_g_w), .b_o(osd_b_w),
        .clk_logic(clk_logic_w),
        .we(osd_wr_w),
        .wa(osd_addr_w),
        .wd(osd_wdata_w)
    );
`else
    assign {osd_r_w, osd_g_w, osd_b_w} = {debug_r_w, debug_g_w, debug_b_w};
`endif

    logic [2:0] tmds;
    wire tmdsClk;

    hdmi #(
        .VIDEO_ID_CODE(2),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(59.94),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .VENDOR_NAME({"Unknown", 8'd0}),  // Must be 8 bytes null-padded 7-bit ASCII
        .PRODUCT_DESCRIPTION({"FPGA", 96'd0}),  // Must be 16 bytes null-padded 7-bit ASCII
        .SOURCE_DEVICE_INFORMATION(8'h00), // See README.md or CTA-861-G for the list of valid codes
        .START_X(0),
        .START_Y(0)
    ) hdmi (
        .clk_pixel_x5(clk_hdmi_w),
        .clk_pixel(clk_pixel_w),
        .clk_audio(clk_audio_w),
        .rgb({
            osd_r_w,
            osd_g_w,
            osd_b_w
        }),
        .reset(~device_reset_n_w),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds),
        .tmds_clock(tmdsClk),
        .cx(hdmi_x),
        .cy(hdmi_y),
        .frame_width(),
        .frame_height(),
        .screen_width(),
        .screen_height()
    );

    // Gowin LVDS output buffer
    ELVDS_TBUF tmds_bufds[3:0] (
        .I({tmdsClk, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n}),
        .OEN(sleep_w && HDMI_SLEEP_ENABLE)
    );

    wire s2_debounced_w;
    debounce #(
        .DEBOUNCE_TIME(10000)
    ) debounce_a2reset (
        .clk(clk_logic_w),
        .rst(~device_reset_n_w),
        .i(s2),
        .o(s2_debounced_w)
    );

    reg prev_button_s2 = 1'b0;
    wire button_s2_posedge_w = s2_debounced_w && !prev_button_s2;
    always @(posedge clk_logic_w) begin 
        prev_button_s2 <= s2_debounced_w;
        if (button_s2_posedge_w) begin
            show_debug_overlay_r <= !show_debug_overlay_r;
        end
        //if (!s2) 
        led <= {!a2mem_if.TEXT_MODE, !a2mem_if.SHRG_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        //else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end


endmodule
