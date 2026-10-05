`timescale 1ns/1ps
// Bus-timing testbench: Apple II bus model -> a2_bus_phy -> a2bridge_pl_wrapper
// -> apple_bus (SMART_ZYNQ) -> simple card (ROM at $C5xx + dev reg at $C0Dx).
// All T_* times are measured from the slot PHI edge that starts the phase.
module tb_bus;
    parameter int  FINE   = 0;
    parameter int  DCFG   = 0;        // PHY drive cfg: [4] soft landing, [5] LSB first, [3:0] clocks/bit        // reg 0x07: PHY drive start, 216 MHz clocks after PHI0 (0 = off)
    parameter int ADDR_N  = 20;
    parameter int DATA_N  = 11;
    parameter int WRITE_N = 2;
    parameter int TUNE    = 0;        // {write,data,addr} runtime override (0 = params)
    parameter int HOLD    = 0;
    parameter int EARLY_DEF = 0;      // apple_bus EARLY_DEFAULT (top.sv uses 1)
    parameter int EARLY   = 0;
    parameter int REL     = 0;        // reg 0x07: release clocks after fast PHI0 edge (0 = off)        // reg 0x0F[3]: fast-PHI card drive        // extra drive-hold clocks after PHI0 (reg 0x0F[7:4])
    parameter real T_LAG  = 50.0;     // 6502 PHI2 lags slot PHI0 (CPU latches at PHI0 fall + T_LAG)
    parameter real T_AGARB= 100.0;    // address/RW start changing (garbage) after PHI1
    parameter real T_ADS  = 350.0;    // address/RW valid after PHI1
    parameter real T_MDS  = 250.0;    // CPU write data valid after PHI0
    parameter real T_HOLD = 20.0;     // data hold after the CPU latch edge
    parameter real T_RAM  = 300.0;    // Apple memory read data valid after PHI0
    parameter real T_DSU  = 60.0;     // CPU read-data setup before its latch edge
    parameter real T_LATCH = -1.0;    // >=0: CPU samples slot data at PHI0 + T_LATCH instead
    parameter int  NCYC   = 4000;

    reg clk = 0, clk4x = 0;
    always #9.259 clk = ~clk;
    always #2.31475 clk4x = ~clk4x;   // 216 MHz, phase-aligned with clk
    reg rst_n = 0;

    reg        phi0_pin = 0;
    reg        phi1_pin = 1;
    reg [15:0] addr_pin = 16'hFFFF;
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
        .ADDR_SAMPLE_COUNT(ADDR_N),
        .DATA_SAMPLE_COUNT(DATA_N),
        .WRITE_COUNT(WRITE_N), .EARLY_DEFAULT(EARLY_DEF[0])
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
        .sz_tune_i(TUNE[23:0]), .sz_hold_i(HOLD[3:0]), .sz_early_i(EARLY[0]), .sz_release_i(REL[7:0]), .sz_probe_sel_i(3'd1), .sz_probe_o(probe),
        .sz_drive_data_o(core_data_out), .sz_drive_en_o(core_data_drive));

    // Card model: ROM at $C500-$C5FF (registered 1 clk, like rom.sv); dev reg
    // at $C0D0-$C0DF. Selects use a2bus.phi0 like every real card.
    function automatic [7:0] rom_byte(input [7:0] a); rom_byte = a ^ 8'h5A; endfunction
    reg [7:0] rom_q;
    always @(posedge clk) rom_q <= rom_byte(a2bus.addr[7:0]);
    wire card_io  = a2bus.phi0 && (a2bus.addr[15:8] == 8'hC5);
    wire card_dev = a2bus.phi0 && (a2bus.addr[15:4] == 12'hC0D);
    assign card_rd_en = (card_io | card_dev) & a2bus.rw_n;
    assign card_data  = card_io ? rom_q : 8'hA5;

    // ---------------- Apple bus model ----------------
    localparam real T14 = 1000.0 / 14.31818;
    reg [15:0] cyc_addr;  reg cyc_rw;  reg [7:0] cyc_wdata;
    reg [15:0] cur_addr;  reg cur_rw;  reg [7:0] cur_wdata;  // cycle whose PHI0 most recently rose
    reg [15:0] pc = 16'hC500;
    integer n_card_rd = 0, n_cpu_bad = 0, n_wr = 0, n_wr_bad = 0, n_stale = 0;
    integer n_strobe_miss = 0;
    reg strobe_ok;
    reg scoring = 0;

    function automatic [7:0] exp_card(input [15:0] a);
        exp_card = (a[15:8] == 8'hC5) ? rom_byte(a[7:0]) : 8'hA5;
    endfunction
    function automatic [7:0] mem_byte(input [15:0] a); mem_byte = a[7:0] + a[15:8] * 3; endfunction

    // CPU read latch for one cycle: setup before, at, and hold after its edge
    task automatic check_latch(input [15:0] a, input rw, input real p0);
        reg [7:0] e, l, h;
        real tl;
        tl = (T_LATCH >= 0.0) ? T_LATCH : (p0 + T_LAG);
        #(tl - T_DSU) e = dbus;
        #(T_DSU) l = dbus;
        #(T_HOLD - 1.0) h = dbus;
        if (scoring && rw && (a[15:8] == 8'hC5 || a[15:4] == 12'hC0D)) begin
            n_card_rd++;
            if (e !== exp_card(a) || l !== exp_card(a) || h !== exp_card(a)) begin
                n_cpu_bad++;
                if (n_cpu_bad <= 5)
                    $display("CPU-LATCH BAD addr %h want %h: setup %h latch %h hold %h", a, exp_card(a), e, l, h);
            end
        end
    endtask

    task automatic one_cycle(input integer idx);
        integer k; real p0;
        k = $urandom_range(0, 99);
        if (k < 45) begin cyc_addr = pc; cyc_rw = 1; pc = (pc == 16'hC5FF) ? 16'hC500 : pc + 1; end
        else if (k < 55) begin cyc_addr = 16'hC0DC; cyc_rw = 1; end
        else if (k < 75) begin cyc_addr = $urandom_range(16'h0400, 16'h07FF); cyc_rw = 0; end
        else begin cyc_addr = $urandom_range(16'h0000, 16'hBFFF); cyc_rw = 1; end
        cyc_wdata = $urandom_range(0, 255);
        p0 = ((idx % 65) == 64) ? 9 * T14 : 7 * T14;   // long cycle: PHI0 stretched
        // ---- PHI1 half ----
        phi0_pin = 0; phi1_pin = 1;
        #(T_LAG + T_HOLD) apple_drive = 0;              // previous cycle's data hold ends
        // address bus: garbage while the 6502 switches, then valid
        #(T_AGARB - T_LAG - T_HOLD) begin addr_pin = $urandom; rw_pin = $urandom; end
        #(T_ADS - T_AGARB) begin addr_pin = cyc_addr; rw_pin = cyc_rw; end
        #(7 * T14 - T_ADS);
        // ---- PHI0 half ----
        phi0_pin = 1; phi1_pin = 0;
        if (scoring && idx > 0 && !strobe_ok) begin
            n_strobe_miss++;
            if (!cur_rw) n_wr_bad++;
            if (n_strobe_miss <= 5) $display("STROBE MISS/BAD addr %h rw %0d", cur_addr, cur_rw);
        end
        cur_addr = cyc_addr; cur_rw = cyc_rw; cur_wdata = cyc_wdata;
        strobe_ok = 0;
        fork check_latch(cyc_addr, cyc_rw, p0); join_none
        if (!cyc_rw) begin
            #(T_MDS - 60) begin apple_drive = 1; apple_data = $urandom; end   // bus still settling
            #(60) apple_data = cyc_wdata;
            #(p0 - T_MDS);
        end else if (cyc_addr[15:8] != 8'hC5 && cyc_addr[15:4] != 12'hC0D) begin
            #(T_RAM) begin apple_drive = 1; apple_data = mem_byte(cyc_addr); end
            #(p0 - T_RAM);
        end else #(p0);
        if (!cyc_rw) n_wr++;
    endtask

    always @(posedge clk) if (rst_n && a2bus.data_in_strobe) begin
        if (a2bus.addr === cur_addr && a2bus.rw_n === cur_rw &&
            (cur_rw || a2bus.data === cur_wdata)) strobe_ok <= 1;
    end
    // Stale-select check: card decode active on an address that isn't this cycle's
    always @(posedge clk) if (rst_n && scoring && (card_io | card_dev) && a2bus.addr !== cur_addr) begin
        n_stale++;
        if (n_stale <= 5) $display("STALE SELECT t=%0t addr_r %h cycle %h", $time, a2bus.addr, cur_addr);
    end

    integer i;
    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < 300; i++) one_cycle(i);   // warm-up (PHY ready count)
        scoring = 1;
        for (i = 0; i < NCYC; i++) one_cycle(i);
        $display("RESULT ADDR_N=%0d DATA_N=%0d WRITE_N=%0d TUNE=%h T_ADS=%0.0f T_MDS=%0.0f T_LAG=%0.0f: card_reads=%0d cpu_latch_bad=%0d writes=%0d write_strobe_bad=%0d strobe_miss_total=%0d stale_selects=%0d addr_bad_ctr=%0d",
                 ADDR_N, DATA_N, WRITE_N, TUNE, T_ADS, T_MDS, T_LAG, n_card_rd, n_cpu_bad, n_wr, n_wr_bad, n_strobe_miss, n_stale, probe);
        $finish;
    end
endmodule
