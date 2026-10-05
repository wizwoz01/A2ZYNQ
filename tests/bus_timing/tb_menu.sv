`timescale 1ns/1ps
// Disk II boot menu: Apple bus model -> PHY -> bridge -> apple_bus -> slotmaker
// -> DiskII. Checks the $C800-$CFFF ownership protocol, Apple reads of the menu
// RAM, mailbox-only Apple writes, the host (SPI space 4) port, and the drive's
// track invalidation / flush when a2hostd unmounts to swap disks.
module tb_menu;
    parameter int  FINE   = 0;
    parameter int  DCFG   = 0;        // PHY drive cfg: [4] soft landing, [5] LSB first, [3:0] clocks/bit        // reg 0x07: PHY drive start, 216 MHz clocks after PHI0 (0 = off)
    parameter int ADDR_N  = 20;
    parameter int DATA_N  = 11;
    parameter int WRITE_N = 2;
    parameter int HOLD    = 0;
    parameter int EARLY_DEF = 0;      // apple_bus EARLY_DEFAULT (top.sv uses 1)
    parameter int EARLY   = 0;
    parameter int  TUNE   = 0;        // regs {0x0E,0x0D,0x0C} (0 = parameter defaults)
    parameter int REL     = 0;        // reg 0x07: release clocks after fast PHI0 edge (0 = off)        // reg 0x0F[3]: fast-PHI card drive
    parameter real T_LAG  = 50.0;     // 6502 PHI2 lags slot PHI0
    parameter real T_AGARB= 100.0;    // address starts changing after PHI1
    parameter real T_ADS  = 350.0;    // address valid after PHI1
    parameter real T_MDS  = 250.0;    // write data valid after PHI0
    parameter real T_HOLD = 20.0;     // data hold after the CPU latch
    parameter real T_RAM  = 300.0;
    parameter int  NNIB   = 1200;

    reg clk = 0, clk4x = 0;
    always #9.259 clk = ~clk;
    always #2.31475 clk4x = ~clk4x;   // 216 MHz, phase-aligned with clk
    reg rst_n = 0;

    reg        phi0_pin = 0, phi1_pin = 1;
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

    wire diskii_rd;
    wire [7:0] diskii_d;

    apple_bus #(.CLOCK_SPEED_HZ(54_000_000), .ADDR_SAMPLE_COUNT(ADDR_N),
                .DATA_SAMPLE_COUNT(DATA_N), .WRITE_COUNT(WRITE_N), .EARLY_DEFAULT(EARLY_DEF[0])) bus (
        .clk_logic_i(clk), .clk_pixel_i(clk),
        .system_reset_n_i(rst_n), .device_reset_n_i(rst_n),
        .a2_phi1_i(bridge_phi1), .a2_q3_i(1'b0), .a2_7M_i(1'b0),
        .a2bus_if(a2bus), .a2bus_control_if(ctl),
        .a2_bridge_sel_o(bridge_sel), .a2_bridge_bus_a_oe_n_o(bridge_addr_oe_n),
        .a2_bridge_bus_d_oe_n_o(bridge_data_oe_n),
        .a2_bridge_rd_n_o(bridge_rd), .a2_bridge_wr_n_o(bridge_wr),
        .a2_bridge_d_i(bridge_to_core), .a2_bridge_d_o(bridge_from_core), .a2_bridge_d_oe_o(),
        .data_out_en_i(diskii_rd), .data_out_i(diskii_d),
        .irq_n_i(1'b1), .inh_n_i(1'b1),
        .dip_switches_n_o(), .sleep_o(), .phi_dead_o(),
        .sz_tune_i(TUNE[23:0]), .sz_hold_i(HOLD[3:0]), .sz_early_i(EARLY[0]), .sz_release_i(REL[7:0]), .sz_probe_sel_i(3'd0), .sz_probe_o(),
        .sz_drive_data_o(core_data_out), .sz_drive_en_o(core_data_drive));

    a2mem_if a2mem();
    assign a2mem.INTCXROM = 1'b0;
    assign a2mem.INTC8ROM = 1'b0;
    slotmaker_config_if cfg();
    assign cfg.slot = 3'd0; assign cfg.wr = 1'b0; assign cfg.card_i = 8'd0; assign cfg.reconfig = 1'b0;
    slot_if slot();
    slotmaker slotmaker(.a2bus_if(a2bus), .a2mem_if(a2mem), .cfg_if(cfg), .slot_if(slot));

    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) ram_disk();
    assign ram_disk.q = 32'd0; assign ram_disk.available = 1'b1; assign ram_disk.ready = 1'b0;

    drive_volume_if volumes[2]();
    reg ack0 = 0, ack1 = 0;
    reg mounted0 = 1;
    assign volumes[0].ready = 1'b1; assign volumes[0].mounted = mounted0; assign volumes[0].readonly = 1'b0;
    assign volumes[0].size = 32'd280; assign volumes[0].ack = ack0;
    assign volumes[1].ready = 1'b1; assign volumes[1].mounted = 1'b1; assign volumes[1].readonly = 1'b0;
    assign volumes[1].size = 32'd280; assign volumes[1].ack = ack1;

    reg        mh_wr = 0;
    reg [10:0] mh_addr = 0;
    reg [7:0]  mh_wdata = 0;
    wire [7:0] mh_rdata;
    // Host (SPI space 4) accesses run alongside a RAM bus cycle, so they do not
    // stretch the modelled PHI1 (which would shift the next address sample).
    task automatic host_wr(input [10:0] a, input [7:0] d);
        reg [7:0] tt;
        fork
            begin @(posedge clk); mh_wr <= 1; mh_addr <= a; mh_wdata <= d; @(posedge clk); mh_wr <= 0; end
            bus_cycle(16'h0301, 1, 0, tt);
        join
    endtask
    task automatic host_rd(input [10:0] a, output [7:0] d);
        reg [7:0] tt;
        fork
            begin @(posedge clk); mh_addr <= a; @(posedge clk); @(posedge clk); d = mh_rdata; end
            bus_cycle(16'h0301, 1, 0, tt);
        join
    endtask
    reg        nib_we = 0, nib_drive = 0;
    reg [12:0] nib_addr = 0;
    reg [7:0]  nib_data = 0;

    reg        nib_rdrive = 0;          // SPACE 6 read-back (a2hostd's save path)
    reg [12:0] nib_raddr = 0;
    wire [7:0] nib_rdata;
    DiskII #(.ID(4)) dut (
        .a2bus_if(a2bus), .slot_if(slot),
        .data_o(diskii_d), .rd_en_o(diskii_rd),
        .ram_disk_if(ram_disk), .volumes(volumes),
        .host_nib_we_i(nib_we), .host_nib_drive_i(nib_drive),
        .host_nib_addr_i(nib_addr), .host_nib_data_i(nib_data),
        .host_nib_rdrive_i(nib_rdrive), .host_nib_raddr_i(nib_raddr), .host_nib_rdata_o(nib_rdata),
        .menu_host_wr_i(mh_wr), .menu_host_addr_i(mh_addr), .menu_host_wdata_i(mh_wdata), .menu_host_rdata_o(mh_rdata));

    // a2hostd's save path: SPI memory SPACE 6 reads the drive's copy of the track
    task automatic host_nib_rd(input drv, input [12:0] a, output [7:0] d);
        @(posedge clk); nib_rdrive <= drv; nib_raddr <= a;
        @(posedge clk); @(posedge clk); d = nib_rdata;
    endtask

    // ---------------- a2hostd model: serve track loads ----------------
    reg [7:0] track [0:6655];
    initial $readmemh("track0.hex", track);  // made by mktrack.c
    integer served = 0, saves = 0, served1 = 0;
    task automatic serve(input integer drv);
        integer j;
        for (j = 0; j < 6656; j++) begin
            @(posedge clk); nib_we <= 1; nib_drive <= drv[0]; nib_addr <= j[12:0];
            nib_data <= (drv == 0) ? track[j] : 8'hFF;
        end
        @(posedge clk); nib_we <= 0;
        repeat (20) @(posedge clk);
        if (drv == 0) ack0 <= 1; else ack1 <= 1;
        @(posedge clk); ack0 <= 0; ack1 <= 0;
        served++;
    endtask
    always begin
        @(posedge clk);
        if (rst_n && volumes[0].wr) begin
            $display("t=%0t save drive1 lba %0d", $time, volumes[0].lba);
            saves++; repeat (50) @(posedge clk); ack0 <= 1; @(posedge clk); ack0 <= 0;
        end else if (rst_n && volumes[0].rd) begin
            $display("t=%0t serve drive1 lba %0d", $time, volumes[0].lba);
            serve(0); served1++;
        end else if (rst_n && volumes[1].rd) begin
            serve(1);
        end
    end

    // ---------------- reference: nibbles shifted into the latch ----------------
    reg [7:0]  ref_q [$];
    reg [12:0] prev_tba;
    always @(posedge clk) begin
        prev_tba <= dut.drive_1.track_byte_addr_r;
        if (rst_n && dut.drive_1.track_byte_addr_r != prev_tba && dut.drive_1.track_resident_w)
            ref_q.push_back(dut.drive_1.nib_mem[prev_tba]);
    end

    // ---------------- Apple bus cycle ----------------
    localparam real T14 = 1000.0 / 14.31818;
    integer cyc = 0;
    // One CPU cycle. Entered part-way into PHI1 (phi1_elapsed); returns with
    // the next PHI1 started and the CPU's latched read value in rd.
    real phi1_elapsed = 0.0;
    task automatic bus_cycle(input [15:0] a, input rw, input [7:0] wd, output [7:0] rd);
        real ph0;
        ph0 = ((cyc % 65) == 64) ? 9 * T14 : 7 * T14;
        cyc++;
        #(T_AGARB - phi1_elapsed) begin addr_pin = $urandom; rw_pin = $urandom; end
        #(T_ADS - T_AGARB) begin addr_pin = a; rw_pin = rw; end
        #(7 * T14 - T_ADS);
        phi0_pin = 1; phi1_pin = 0;
        if (!rw) begin #(T_MDS) begin apple_drive = 1; apple_data = wd; end #(ph0 - T_MDS); end
        else if (a[15:8] != 8'hC5 && a[15:4] != 12'hC0D && a[15:11] != 5'b11001) begin
            #(T_RAM) begin apple_drive = 1; apple_data = a[7:0]; end #(ph0 - T_RAM);
        end else #(ph0);
        phi0_pin = 0; phi1_pin = 1;
        #(T_LAG) rd = dbus;
        #(T_HOLD) apple_drive = 0;
        phi1_elapsed = T_LAG + T_HOLD;
    endtask
    // LDA abs,X (no page cross): 3 ROM fetches + the effective read
    task automatic lda_absx(input [15:0] pc, input [15:0] ea, output [7:0] v);
        reg [7:0] t;
        bus_cycle(pc, 1, 0, t); bus_cycle(pc + 1, 1, 0, t); bus_cycle(pc + 2, 1, 0, t);
        bus_cycle(ea, 1, 0, v);
    endtask

    reg [7:0] code [0:2047];
    initial $readmemh("diskmenu.hex", code);
    integer errs = 0, k;
    // The card's own /IOSEL and /DEVSEL, as the IIe drives them for the slot the
    // card is plugged into (during PHI0 of $Cn00-$CnFF / $C0n0-$C0nF).
    integer card_slot = 6;
    wire phys_iosel_n  = !(phi0_pin && addr_pin[15:11] == 5'b11000 && addr_pin[10:8] == card_slot[2:0]);
    wire phys_devsel_n = !(phi0_pin && addr_pin[15:8] == 8'hC0 && addr_pin[7:4] == 4'h8 + card_slot[3:0]);
    wire [2:0] phys_slot;
    phys_slot_detect slotdet(.a2bus_if(a2bus), .iosel_n_i(phys_iosel_n), .devsel_n_i(phys_devsel_n), .slot_o(phys_slot));
    task automatic expect_slot(input [2:0] want, input string what);
        reg [7:0] tt;
        bus_cycle(16'h0300, 1, 0, tt);   // the detector decides at the end of the cycle (core PHI1 rising)
        if (phys_slot !== want) begin errs++; $display("FAIL slot detect %s: %0d, want %0d", what, phys_slot, want); end
    endtask
    // The reads diskmenu.a65 makes before its hello: $C0n0 twice for slots 1-3
    // (/DEVSEL only; the menu must not touch $C1xx-$C3xx), $Cn00/$Cn01 for 4-7.
    task automatic menu_probes();
        reg [7:0] tt;
        for (int s = 1; s <= 3; s++) begin
            bus_cycle(16'hC080 + 16'(s * 16), 1, 0, tt);
            bus_cycle(16'hC080 + 16'(s * 16), 1, 0, tt);
        end
        for (int s = 4; s <= 7; s++) begin
            bus_cycle({8'hC0 + 8'(s), 8'h00}, 1, 0, tt);
            bus_cycle({8'hC0 + 8'(s), 8'h01}, 1, 0, tt);
        end
    endtask
    reg [7:0] v, t;
    task automatic expect_rd(input [15:0] a, input [7:0] want, input string what);
        bus_cycle(a, 1, 0, v);
        if (v !== want) begin errs++; $display("FAIL %s: read %h = %h, want %h", what, a, v, want); end
    endtask
    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        for (k = 0; k < 400; k++) bus_cycle(16'h0300 + k, 1, 0, t);   // settle, slot config
        // physical slot detection (card in slot 6)
        expect_slot(0, "before any select");
        bus_cycle(16'hC500, 1, 0, t); bus_cycle(16'hC700, 1, 0, t);
        expect_slot(0, "other slots");
        bus_cycle(16'hC600, 1, 0, t);
        expect_slot(0, "one hit");
        bus_cycle(16'hC601, 1, 0, t);
        expect_slot(6, "two hits");
        bus_cycle(16'hC0E8, 1, 0, t); bus_cycle(16'hC0EC, 1, 0, t); bus_cycle(16'h0300, 1, 0, t);
        expect_slot(6, "devsel + RAM");
        card_slot = 5;   // card moved (the detector keeps the old slot until two new hits)
        bus_cycle(16'hC0D8, 1, 0, t);
        expect_slot(6, "one devsel hit in 5");
        bus_cycle(16'hC501, 1, 0, t);
        expect_slot(5, "moved to 5");
        // the menu's probe sequence names every slot the card can be in, 1-3 included
        for (k = 1; k <= 7; k++) begin
            card_slot = k;
            menu_probes();
            expect_slot(k[2:0], "menu probe sequence");
        end
        card_slot = 5;
        menu_probes();
        expect_slot(5, "menu probe sequence, back in 5");
        bus_cycle(16'hCFFF, 1, 0, t);   // the $C5xx probes above claimed $C800: let it go
        // not owned yet: nobody drives $C800 (pull-ups read $FF)
        expect_rd(16'hC800, 8'hFF, "unclaimed $C800");
        // any $C5xx access claims $C800-$CFFF
        bus_cycle(16'hC524, 1, 0, t);
        for (k = 0; k < 16; k++) expect_rd(16'hC800 + k, code[k], "menu code");
        expect_rd(16'hC8B0, code[16'h0B0], "menu code tail");
        expect_rd(16'hCA05, 8'hA0, "blank screen image");
        // Apple writes: mailbox yes, code no
        bus_cycle(16'hCE08, 0, 8'h42, t);
        bus_cycle(16'hC810, 0, 8'h77, t);
        host_rd(11'h608, v); if (v !== 8'h42) begin errs++; $display("FAIL mailbox write: host sees %h", v); end
        host_rd(11'h010, v); if (v !== code[16'h010]) begin errs++; $display("FAIL code overwritten: %h", v); end
        expect_rd(16'hCE08, 8'h42, "mailbox readback");
        // host writes show up for the Apple
        host_wr(11'h602, 8'h99);
        host_wr(11'h600, 8'hA5);
        expect_rd(16'hCE02, 8'h99, "host frame byte");
        expect_rd(16'hCE00, 8'hA5, "host magic byte");
        // $CFFF releases; the next $C800 read is not driven
        bus_cycle(16'hCFFF, 1, 0, t);
        expect_rd(16'hC800, 8'hFF, "released $C800");
        bus_cycle(16'hCE08, 0, 8'h55, t);   // not owned: ignored
        host_rd(11'h608, v); if (v !== 8'h42) begin errs++; $display("FAIL write while released: %h", v); end
        // another slot's page does not claim it
        bus_cycle(16'hC600, 1, 0, t);
        expect_rd(16'hC800, 8'hFF, "slot 6 access");
        bus_cycle(16'hC5FF, 1, 0, t);
        expect_rd(16'hC800, code[0], "reclaimed");
        // the stock ROM still reads right
        expect_rd(16'hC501, 8'h20, "P5 signature");
        expect_rd(16'hC521, 8'h2C, "P5 hook");
        // drive: load track 0, then unmount -> cached track dropped, remount -> reload
        lda_absx(16'hC538, 16'hC0D9, v);   // motor on (drive 1)
        for (k = 0; k < 400 && served1 == 0; k++) bus_cycle(16'hC55E, 1, 0, t);
        wait (dut.drive_1.cur_track_r == 6'd0);
        if (served1 != 1) begin errs++; $display("FAIL first load: served1=%0d", served1); end
        // real writes, as DOS's write loop does them: write mode, then per nibble
        // STA $C0DD,X (load the latch; the 6502 reads $C0DD first) and ORA $C0DC,X
        // (shift it out). The head stores one nibble per $C0DC access, and the
        // save path (SPACE 6) must return them over the loaded track.
        begin : write_test
            integer w0, adv, kk;
            reg [7:0] wv [0:7];
            reg [7:0] rb;
            lda_absx(16'hC538, 16'hC0DF, v);           // Q7H: write mode
            w0 = dut.drive_1.track_byte_addr_r;
            for (kk = 0; kk < 8; kk++) begin
                wv[kk] = 8'h96 + kk * 8;
                bus_cycle(16'hC540, 1, 0, t); bus_cycle(16'hC541, 1, 0, t); bus_cycle(16'hC542, 1, 0, t);
                bus_cycle(16'hC0DD, 1, 0, t); bus_cycle(16'hC0DD, 0, wv[kk], t);
                lda_absx(16'hC543, 16'hC0DC, v);
            end
            lda_absx(16'hC546, 16'hC0DE, v);           // Q7L: back to read mode
            adv = (dut.drive_1.track_byte_addr_r - w0 + 6656) % 6656;
            if (adv != 8) begin errs++; $display("FAIL write head moved %0d for 8 nibbles", adv); end
            if (!dut.drive_1.dirty_r) begin errs++; $display("FAIL written track not marked dirty"); end
            for (kk = 0; kk < 8; kk++) begin
                host_nib_rd(0, 13'((w0 + kk) % 6656), rb);
                if (rb !== wv[kk]) begin errs++; $display("FAIL read-back of written nibble %0d = %h, want %h", kk, rb, wv[kk]); end
            end
            host_nib_rd(0, 13'((w0 + 200) % 6656), rb);
            if (rb !== track[(w0 + 200) % 6656]) begin errs++; $display("FAIL read-back of loaded byte = %h, want %h", rb, track[(w0 + 200) % 6656]); end
            host_nib_rd(1, 13'(w0 % 6656), rb);
            if (rb !== 8'hFF) begin errs++; $display("FAIL drive 2 read-back = %h, want FF", rb); end
            bus_cycle(16'h0300, 1, 0, t);              // resync after the host reads ate PHI1 time
        end
        // the written track is flushed when the motor stops
        lda_absx(16'hC538, 16'hC0D8, v);   // motor off
        // skip the ~0.26 s spindown: the drive stops (drive_real_on_r falls)
        force dut.drive_real_on_r = 1'b0; @(posedge clk); release dut.drive_real_on_r;
        k = 0; while (saves == 0 && k < 20000) begin @(posedge clk); k++; end
        if (saves != 1) begin errs++; $display("FAIL flush on motor off: saves=%0d", saves); end
        repeat (100) @(posedge clk);
        if (!dut.drive_1.nib_valid_r || dut.drive_1.cur_track_r != 0) begin errs++; $display("FAIL track unreadable after flush"); end
        // unmount (a2hostd swapping images)
        mounted0 = 0; repeat (10) @(posedge clk);
        if (dut.drive_1.cur_track_r != 6'h3f) begin errs++; $display("FAIL unmount kept track %0d", dut.drive_1.cur_track_r); end
        mounted0 = 1;
        lda_absx(16'hC538, 16'hC0D9, v);   // motor on
        k = 0; while (served1 < 2 && k < 400000) begin @(posedge clk); k++; end
        if (served1 != 2) begin errs++; $display("FAIL reload after remount: served1=%0d", served1); end
        $display("RESULT_MENU errors=%0d drive1_loads=%0d saves=%0d", errs, served1, saves);
        $finish;
    end
endmodule
