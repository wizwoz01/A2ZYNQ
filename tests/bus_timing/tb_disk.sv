`timescale 1ns/1ps
// Disk II end-to-end: Apple bus model -> PHY -> bridge -> apple_bus -> slotmaker
// -> DiskII (apple_disk + drive_ii + diskii.hex). Replays the P5 boot ROM's
// read loop and checks the CPU gets every nibble the drive shifts out, once.
module tb_disk;
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
    assign volumes[0].ready = 1'b1; assign volumes[0].mounted = 1'b1; assign volumes[0].readonly = 1'b0;
    assign volumes[0].size = 32'd280; assign volumes[0].ack = ack0;
    assign volumes[1].ready = 1'b1; assign volumes[1].mounted = 1'b1; assign volumes[1].readonly = 1'b0;
    assign volumes[1].size = 32'd280; assign volumes[1].ack = ack1;

    reg        nib_we = 0, nib_drive = 0;
    reg [12:0] nib_addr = 0;
    reg [7:0]  nib_data = 0;

    DiskII #(.ID(4)) dut (
        .a2bus_if(a2bus), .slot_if(slot),
        .data_o(diskii_d), .rd_en_o(diskii_rd),
        .ram_disk_if(ram_disk), .volumes(volumes),
        .host_nib_we_i(nib_we), .host_nib_drive_i(nib_drive),
        .host_nib_addr_i(nib_addr), .host_nib_data_i(nib_data),
        .host_nib_rdrive_i(1'b0), .host_nib_raddr_i(13'd0), .host_nib_rdata_o(),
        .menu_host_wr_i(1'b0), .menu_host_addr_i(11'd0), .menu_host_wdata_i(8'd0), .menu_host_rdata_o());

    // ---------------- a2hostd model: serve track loads ----------------
    reg [7:0] track [0:6655];
    initial $readmemh("track0.hex", track);  // made by mktrack.c
    integer served = 0;
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
        if (rst_n && volumes[0].rd) begin
            $display("t=%0t serve drive1 lba %0d", $time, volumes[0].lba);
            serve(0);
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
        else if (a[15:8] != 8'hC5 && a[15:4] != 12'hC0D) begin
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

    integer got = 0, bad = 0, polls = 0, xcount = 0;
    reg [7:0] v, t, want;
    integer i, extra;
    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < 400; i++) bus_cycle(16'h0300 + i, 1, 0, t);   // settle, slot config
        lda_absx(16'hC52F, 16'hC0DE, v);   // Q7L
        lda_absx(16'hC532, 16'hC0DC, v);   // Q6L
        lda_absx(16'hC535, 16'hC0DA, v);   // drive 1
        lda_absx(16'hC538, 16'hC0D9, v);   // motor on
        for (i = 0; i < 300; i++) bus_cycle(16'hC540 + (i % 16), 1, 0, t);
        ref_q.delete();
        while (got < NNIB) begin
            lda_absx(16'hC55E, 16'hC0DC, v);
            bus_cycle(16'hC561, 1, 0, t); bus_cycle(16'hC562, 1, 0, t);  // BPL
            polls++;
            if (^v === 1'bx) xcount++;
            if (v[7] === 1'b1) begin
                if (got == 0) begin ref_q.delete(); end else if (ref_q.size() == 0) begin
                    bad++; if (bad <= 8) $display("DUPLICATE: read %h but no new nibble shifted in (got=%0d)", v, got);
                end else begin
                    if (ref_q.size() > 1) begin
                        bad += ref_q.size() - 1;
                        if (bad <= 8) $display("DROPPED %0d nibble(s) before %0d", ref_q.size() - 1, got);
                    end
                    want = ref_q[ref_q.size() - 1];
                    if (v !== want) begin bad++; if (bad <= 8) $display("MISMATCH got %h want %h at %0d", v, want, got); end
                    ref_q.delete();
                end
                got++;
                extra = $urandom_range(2, 6);
                repeat (extra) bus_cycle(16'hC563, 1, 0, t);
            end else begin
                bus_cycle(16'hC563, 1, 0, t);   // branch taken
            end
        end
        $display("RESULT_DISK ADDR_N=%0d DATA_N=%0d WRITE_N=%0d T_ADS=%0.0f: nibbles=%0d errors=%0d polls=%0d x_reads=%0d served=%0d",
                 ADDR_N, DATA_N, WRITE_N, T_ADS, got, bad, polls, xcount, served);
        $finish;
    end
endmodule
