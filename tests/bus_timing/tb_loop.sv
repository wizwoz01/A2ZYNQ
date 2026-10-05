`timescale 1ns/1ps
// Replays the IIe test loop  300: AD 05 C5 C9 03 F0 F9 (LDA $C505 / CMP #$03 /
// BEQ) against apple_bus, and records what the card puts on the slot bus in
// every $C505 cycle: the byte left in the output latch from before (stale), when
// the drive starts, when the pins carry the right byte for good, and whether the
// card drove in any cycle it should not have (early-address slip).
// Apple model: the 6502 moves each address bit at its own time between T_AGARB
// and T_ADS after PHI1 (so the early PHI1 address pass can catch a half-settled
// address); the IIe drives RAM data from PHI0+T_RAM, and video data onto the
// slot bus during PHI1 (from PHI1+T_VID until PHI0+T_TURN) except while the
// address decodes as a slot-ROM read. XT_P = chance per card drive that the
// drive start disturbs the card's view of the address lines for XT_T ns.
module tb_loop;
    parameter int  FINE   = 0;
    parameter int  DCFG   = 0;        // PHY drive cfg: [4] soft landing, [5] LSB first, [3:0] clocks/bit        // reg 0x07: PHY drive start, 216 MHz clocks after PHI0 (0 = off)
    parameter int TUNE    = 0;        // {sd:4 w:4, late_dis:1 - data:6, addr:8}
    parameter int EARLY_DEF = 1;
    parameter int EARLY   = 0;
    parameter int HOLD    = 0;
    parameter real T_AGARB = 150.0;
    parameter real T_ADS  = 430.0;
    parameter real T_RAM  = 250.0;
    parameter real T_VID  = 60.0;
    parameter real T_TURN = 40.0;
    parameter real T_LATCH = 489.0;   // CPU latch, from PHI0 rise
    parameter int  XT_P   = 0;        // percent
    parameter real XT_T   = 60.0;
    parameter int  NITER  = 3000;
    parameter int  SEED   = 1;

    reg clk = 0, clk4x = 0;
    always #9.259 clk = ~clk;
    always #2.31475 clk4x = ~clk4x;   // 216 MHz, phase-aligned with clk
    reg rst_n = 0;

    reg        phi0_pin = 0, phi1_pin = 1;
    reg [15:0] addr_apple = 16'h0300;   // what the 6502 drives
    reg [15:0] xt_mask = 16'h0000;      // crosstalk seen by the card's address inputs
    wire [15:0] addr_pin = addr_apple ^ xt_mask;
    reg        rw_pin = 1;
    reg        apple_drive = 0;
    reg [7:0]  apple_data = 8'h00;
    wire [7:0] dbus;
    assign dbus = apple_drive ? apple_data : 8'hzz;
    // Undriven slot data lines float high (the IIe's LS inputs source current).
    genvar pu; for (pu = 0; pu < 8; pu++) begin : g_pu pullup (dbus[pu]); end

    wire [7:0] core_data_in, core_data_out;
    wire core_data_drive;
    wire [15:0] ba;
    wire brw, bp0, bp1, b7, bq3, bsync, biosel, biostrb, bdevsel, bm2sel, bm2b0;
    wire breset, brdy, bdma, bnmi, birq, binh;
    wire pull_inh, pull_irq, pull_rdy, pull_dma, pull_nmi, pull_reset;
    wire phy_drive_q;

    a2_bus_phy phy(
        .clk(clk), .reset_n(rst_n), .clocks_locked(1'b1), .host_ready(1'b1), .a2_5v_present(1'b1),
        .a2_data(dbus), .a2_addr(addr_pin), .a2_rw(rw_pin), .a2_phi0(phi0_pin), .a2_phi1(phi1_pin),
        .a2_7m(1'b0), .a2_q3(1'b0), .a2_sync(1'b0), .a2_iosel_n(1'b1), .a2_iostrb_n(1'b1),
        .a2_devsel_n(1'b1), .a2_m2sel(1'b0), .a2_m2b0(1'b0),
        .a2_reset_asserted_sense(1'b0), .a2_rdy_n_sense(1'b1), .a2_dma_n_sense(1'b1),
        .a2_nmi_n_sense(1'b1), .a2_irq_n_sense(1'b1), .a2_inh_n_sense(1'b1),
        .core_data_out(core_data_out), .core_data_drive(core_data_drive), .clk4x(clk4x), .core_drive_fine(FINE[7:0]), .core_drive_cfg(DCFG[15:0]),
        .core_data_in(core_data_in),
        .core_irq_assert(pull_irq), .core_nmi_assert(pull_nmi), .core_rdy_assert(pull_rdy),
        .core_dma_assert(pull_dma), .core_inh_assert(pull_inh), .core_reset_assert(pull_reset),
        .a2_data_dir(), .a2_data_oe_n(), .a2_input_oe_n(),
        .a2_irq_assert(), .a2_nmi_assert(), .a2_rdy_assert(),
        .a2_dma_assert(), .a2_inh_assert(), .a2_reset_assert(), .pl_ready(),
        .bus_addr(ba), .bus_rw(brw), .bus_phi0(bp0), .bus_phi1(bp1), .bus_7m(b7), .bus_q3(bq3),
        .bus_sync(bsync), .bus_iosel_n(biosel), .bus_iostrb_n(biostrb), .bus_devsel_n(bdevsel),
        .bus_m2sel(bm2sel), .bus_m2b0(bm2b0), .bus_reset_n(breset), .bus_rdy_n(brdy),
        .bus_dma_n(bdma), .bus_nmi_n(bnmi), .bus_irq_n(birq), .bus_inh_n(binh));
    assign phy_drive_q = ~phy.pin_t[0];

    wire [2:0] bridge_sel;
    wire bridge_rd, bridge_wr, bridge_phi1, bridge_7m, bridge_q3, bridge_reset_n_o;
    wire bridge_addr_oe_n, bridge_data_oe_n;
    wire [7:0] bridge_to_core, bridge_from_core, bus_data_out;
    // D0-D7 straight from apple_bus (sz_drive_*), as in smart_zynq_a2_application

    a2bridge_pl_wrapper bridge(
        .clk(clk), .reset_n(rst_n), .switch_n(4'hF),
        .bus_addr(ba), .bus_data(core_data_in), .bus_data_out(bus_data_out),
        .bus_rw(brw), .bus_sync(bsync), .bus_7m(b7), .bus_q3(bq3),
        .bus_phi0(bp0), .bus_phi1(bp1), .bus_iosel_n(biosel), .bus_iostrb_n(biostrb),
        .bus_devsel_n(bdevsel), .bus_reset_n(breset & ~pull_reset), .bus_m2sel(bm2sel), .bus_m2b0(bm2b0),
        .bus_rdy_n(brdy), .bus_dma_n(bdma), .bus_irq_n(birq), .bus_nmi_n(bnmi), .bus_inh_n(binh),
        .pull_inh(pull_inh), .pull_irq(pull_irq), .pull_rdy(pull_rdy),
        .pull_dma(pull_dma), .pull_nmi(pull_nmi), .pull_reset(pull_reset),
        .bus_dmain_n(1'b1), .bus_intin_n(1'b1), .bus_dmaout_n(), .bus_intout_n(),
        .bridge_data_i(bridge_from_core), .bridge_data_o(bridge_to_core),
        .bridge_sel(bridge_sel), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
        .bridge_phi1(bridge_phi1), .bridge_7m(bridge_7m), .bridge_q3(bridge_q3),
        .bridge_reset_n(bridge_reset_n_o),
        .bridge_addr_oe_n(bridge_addr_oe_n), .bridge_data_oe_n(bridge_data_oe_n));

    a2bus_if a2bus();
    a2bus_control_if ctl();
    assign ctl.ready = 1'b1;
    assign ctl.reset_hold = 1'b0;

    wire card_rd_en;
    wire [7:0] card_data;
    wire [31:0] probe;

    apple_bus #(
        .CLOCK_SPEED_HZ(54_000_000),
        .ADDR_SAMPLE_COUNT(20), .DATA_SAMPLE_COUNT(11), .WRITE_COUNT(2),
        .EARLY_DEFAULT(EARLY_DEF[0])
    ) bus (
        .clk_logic_i(clk), .clk_pixel_i(clk),
        .system_reset_n_i(rst_n), .device_reset_n_i(rst_n),
        .a2_phi1_i(bridge_phi1), .a2_q3_i(1'b0), .a2_7M_i(1'b0),
        .a2bus_if(a2bus), .a2bus_control_if(ctl),
        .a2_bridge_sel_o(bridge_sel), .a2_bridge_bus_a_oe_n_o(bridge_addr_oe_n),
        .a2_bridge_bus_d_oe_n_o(bridge_data_oe_n),
        .a2_bridge_rd_n_o(bridge_rd), .a2_bridge_wr_n_o(bridge_wr),
        .a2_bridge_d_i(bridge_to_core), .a2_bridge_d_o(bridge_from_core), .a2_bridge_d_oe_o(),
        .data_out_en_i(card_rd_en), .data_out_i(card_data),
        .irq_n_i(1'b1), .inh_n_i(1'b1),
        .dip_switches_n_o(), .sleep_o(), .phi_dead_o(),
        .sz_tune_i(TUNE[23:0]), .sz_hold_i(HOLD[3:0]), .sz_early_i(EARLY[0]), .sz_release_i(8'h3C),
        .sz_probe_sel_i(3'd6), .sz_probe_o(probe),
        .sz_drive_data_o(core_data_out), .sz_drive_en_o(core_data_drive));

    // Cards like the real slot map: every slot ROM $C100-$C7FF answers (the
    // Disk II P5 PROM in slot 5, a stand-in pattern elsewhere), registered one
    // clock like rom.v; the Disk II data register at $C0DC.
    reg [7:0] p5 [0:255];
    initial $readmemh("diskii.hex", p5);
    function automatic [7:0] slot_rom(input [15:0] a);
        slot_rom = (a[10:8] == 3'd5) ? p5[a[7:0]] : (a[7:0] ^ {a[10:8], 5'h15});
    endfunction
    reg [7:0] rom_q;
    always @(posedge clk) rom_q <= slot_rom(a2bus.addr);
    wire card_io  = a2bus.phi0 && (a2bus.addr[15:11] == 5'b11000) && (a2bus.addr[10:8] != 3'd0);
    wire card_dev = a2bus.phi0 && (a2bus.addr[15:4] == 12'hC0D);
    assign card_rd_en = (card_io | card_dev) & a2bus.rw_n;
    assign card_data  = card_io ? rom_q : 8'hD5;

    // ---------------- Apple side ----------------
    localparam real T14 = 1000.0 / 14.31818;
    localparam [15:0] LA [0:8] = '{16'h0300, 16'h0301, 16'h0302, 16'hC505, 16'h0303,
                                   16'h0304, 16'h0305, 16'h0306, 16'h0307};
    localparam [7:0]  LD [0:8] = '{8'hAD, 8'h05, 8'hC5, 8'h03, 8'hC9, 8'h03, 8'hF0, 8'hF9, 8'h8D};

    integer n_rd = 0, n_bad = 0, n_stale = 0, n_stale_d7 = 0, n_slip = 0, n_gap = 0;
    integer late_hist [0:15];      // time pins carry $03 for good, 50 ns bins from PHI0
    integer start_hist [0:15];     // drive start, 50 ns bins
    integer n_multi = 0;           // latch written more than once in a $C505 cycle
    real t_start_min = 1.0e9, t_start_max = 0.0;
    real t_p0;
    reg  in_c505 = 0, scoring = 0;
    real t_start, t_good;
    reg  seen_drive, good_now;
    integer nwrites;
    reg [7:0] stale_b;

    // card must not drive outside $C505 cycles (after its own hold)
    always @(posedge clk) if (scoring && !in_c505 && phy_drive_q && ($realtime - t_p0) > 30.0 && phi0_pin) begin
        n_slip++;
        if (n_slip <= 4) $display("SLIP: card drove in a %h cycle at PHI0+%0.0f, byte %h", addr_apple, $realtime - t_p0, phy.pin_d);
    end
    always @(posedge clk4x) if (in_c505 && phi0_pin) begin
        #0.5;
        if (phy_drive_q && !seen_drive) begin seen_drive = 1; t_start = $realtime - t_p0; stale_b = phy.pin_d; end
        if (seen_drive && !phy_drive_q) n_gap++;
        if (phy_drive_q && phy.pin_d == 8'h03) begin if (!good_now) begin good_now = 1; t_good = $realtime - t_p0; end end
        else good_now = 0;
    end
    reg wr_q = 1;
    always @(posedge clk) begin
        wr_q <= bridge_wr;
        if (in_c505 && wr_q && !bridge_wr && bridge_sel == 3'd1) nwrites++;
    end

    task automatic move_addr(input [15:0] to);
        // each bit settles at its own time in [T_AGARB, T_ADS]
        real t[16]; integer order[16]; integer i, j, tmp; real last;
        for (i = 0; i < 16; i++) begin t[i] = T_AGARB + (T_ADS - T_AGARB) * ($urandom_range(0, 1000) / 1000.0); order[i] = i; end
        for (i = 0; i < 16; i++) for (j = i + 1; j < 16; j++) if (t[order[j]] < t[order[i]]) begin tmp = order[i]; order[i] = order[j]; order[j] = tmp; end
        last = 0.0;
        #(T_AGARB);
        last = T_AGARB;
        for (i = 0; i < 16; i++) begin
            #(t[order[i]] - last) addr_apple[order[i]] = to[order[i]];
            last = t[order[i]];
        end
        #(T_ADS - last);
    endtask

    task automatic one_cycle(input integer k, input integer idx);
        real p0; reg [15:0] a; reg [7:0] vid;
        a = LA[k];
        p0 = ((idx % 65) == 64) ? 9 * T14 : 7 * T14;
        vid = ($urandom_range(0, 99) < 85) ? ($urandom | 8'h80) : ($urandom & 8'h7F);
        // ---- PHI1 ----
        phi0_pin = 0; phi1_pin = 1;
        fork
            begin #(20.0) apple_drive = 0; #(T_VID - 20.0) begin if (!(a[15:11] == 5'b11000)) begin apple_drive = 1; apple_data = vid; end end end
            move_addr(a);
        join
        #(7 * T14 - T_ADS);
        // ---- PHI0 ----
        phi0_pin = 1; phi1_pin = 0; t_p0 = $realtime;
        in_c505 = (a == 16'hC505); seen_drive = 0; good_now = 0; nwrites = 0; t_good = 1.0e9;
        if (XT_P > 0 && in_c505 && $urandom_range(0, 99) < XT_P) fork
            begin wait (phy_drive_q); xt_mask = $urandom & 16'hFFFF; #(XT_T) xt_mask = 16'h0000; end
        join_none
        if (in_c505) begin
            #(T_TURN) apple_drive = 0;
            #(T_LATCH - T_TURN);
            if (scoring) begin
                n_rd++;
                if (dbus !== 8'h03) begin
                    n_bad++;
                    if (n_bad <= 6) $display("CPU BAD it%0d: latched %h  stale %h start +%0.0f good +%0.0f writes %0d", idx, dbus, stale_b, t_start, t_good, nwrites);
                end
                if (seen_drive && stale_b != 8'h03) begin n_stale++; if (stale_b[7]) n_stale_d7++; end
                late_hist[(dbus === 8'h03 && t_good < 800.0) ? int'(t_good / 50.0) : 15]++;
                start_hist[seen_drive ? int'(t_start / 50.0) : 15]++;
                if (seen_drive && t_start < t_start_min) t_start_min = t_start;
                if (seen_drive && t_start > t_start_max) t_start_max = t_start;
                if (nwrites > 1) n_multi++;
            end
            #(p0 - T_LATCH);
        end else begin
            #(T_RAM) begin apple_drive = 1; apple_data = LD[k]; end
            #(p0 - T_RAM);
        end
    endtask

    integer i, k, it;
    initial begin
        process::self().srandom(SEED);
        for (i = 0; i < 16; i++) begin late_hist[i] = 0; start_hist[i] = 0; end
        repeat (40) @(posedge clk);
        rst_n = 1;
        it = 0;
        for (i = 0; i < 60; i++) for (k = 0; k < 9; k++) begin one_cycle(k, it); it++; end
        scoring = 1;
        for (i = 0; i < NITER; i++) for (k = 0; k < 9; k++) begin one_cycle(k, it); it++; end
        $display("RESULT TUNE=%h XT_P=%0d T_ADS=%0.0f: c505_reads=%0d cpu_bad=%0d stale_latch=%0d (d7 %0d) slips=%0d drive_gaps=%0d multi_writes=%0d late_fix=%0d",
                 TUNE, XT_P, T_ADS, n_rd, n_bad, n_stale, n_stale_d7, n_slip, n_gap, n_multi, probe);
        $display("RESULT   drive start PHI0+%0.1f .. %0.1f ns (FINE=%0d)", t_start_min, t_start_max, FINE);
        $write("RESULT   start(50ns bins):"); for (i = 0; i < 16; i++) $write(" %0d", start_hist[i]); $write("\n");
        $write("RESULT   good (50ns bins):"); for (i = 0; i < 16; i++) $write(" %0d", late_hist[i]); $write("\n");
        $finish;
    end
endmodule
