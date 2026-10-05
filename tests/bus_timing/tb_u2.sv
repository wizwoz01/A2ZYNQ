`timescale 1ns/1ps
// Disk II boot menu: Apple bus model -> PHY -> bridge -> apple_bus -> slotmaker
// -> DiskII. Checks the $C800-$CFFF ownership protocol, Apple reads of the menu
// RAM, mailbox-only Apple writes, the host (SPI space 4) port, and the drive's
// track invalidation / flush when a2hostd unmounts to swap disks.
module tb_u2;
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

    // Uthernet II (card 5, slot 3 in slots.hex) instead of the Disk II
    reg        u2_hwr = 0;
    reg [15:0] u2_haddr = 0;
    reg [7:0]  u2_hwdata = 0;
    wire [7:0] u2_hrdata;
    wire [3:0] u2_pending;
    reg  [3:0] u2_clr = 0;
    wire u2_irq_n;
    Uthernet2 #(.ID(5)) dut (
        .a2bus_if(a2bus), .slot_if(slot), .data_o(diskii_d), .rd_en_o(diskii_rd), .irq_n_o(u2_irq_n),
        .w5100_host_wr(u2_hwr), .w5100_host_addr(u2_haddr), .w5100_host_wdata(u2_hwdata), .w5100_host_rdata(u2_hrdata),
        .cmd_pending_o(u2_pending), .cmd_pending_clr(u2_clr),
        .dbg_portb_wr_count(), .dbg_portb_last_addr(), .dbg_portb_last_wdata());

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
        else if (a[15:4] != 12'hC0B) begin
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

    integer errs = 0, k, shift_hits = 0;
    reg [7:0] v, t;
    reg [7:0] pat [0:255];
    task automatic host_w(input [15:0] a, input [7:0] d);
        @(posedge clk); u2_hwr <= 1; u2_haddr <= a; u2_hwdata <= d; @(posedge clk); u2_hwr <= 0;
    endtask
    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        for (k = 0; k < 400; k++) bus_cycle(16'h0300 + k, 1, 0, t);      // settle, slot config
        for (k = 0; k < 256; k++) begin pat[k] = 8'((k * 37) ^ 8'h5A); host_w(16'h6000 + k, pat[k]); end
        host_w(16'h0017, 8'h07); host_w(16'h0018, 8'hD0); host_w(16'h0019, 8'h08);
        host_w(16'h0426, 8'h01); host_w(16'h0427, 8'h58); host_w(16'h0428, 8'h00); host_w(16'h0429, 8'h00);
        bus_cycle(16'h0300, 1, 0, t);                                     // resync the bus model after the host writes
        bus_cycle(16'hC0B4, 0, 8'h03, t);                                 // MR = indirect + auto-increment
        // IP65 detection: RTR at $0017/$0018 must read $07, $D0
        bus_cycle(16'hC0B5, 0, 8'h00, t); bus_cycle(16'hC0B6, 0, 8'h17, t);
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'h07) begin errs++; $display("RTR hi read %h want 07", v); end
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'hD0) begin errs++; $display("RTR lo read %h want D0", v); end
        // IP65 poll: RSR ($0426) then straight on into RX_RD ($0428)
        bus_cycle(16'hC0B5, 0, 8'h04, t); bus_cycle(16'hC0B6, 0, 8'h26, t);
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'h01) begin errs++; $display("RSR hi %h want 01", v); end
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'h58) begin errs++; $display("RSR lo %h want 58", v); end
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'h00) begin errs++; $display("RX_RD hi %h want 00", v); end
        bus_cycle(16'hC0B7, 1, 0, v); if (v !== 8'h00) begin errs++; $display("RX_RD lo %h want 00", v); end
        // frame read from the RX ring, back to back (like mov_data)
        bus_cycle(16'hC0B5, 0, 8'h60, t); bus_cycle(16'hC0B6, 0, 8'h00, t);
        for (k = 0; k < 64; k++) begin
            bus_cycle(16'hC0B7, 1, 0, v);
            if (v !== pat[k]) begin
                errs++;
                if (k < 63 && v === pat[k+1]) shift_hits++;
                if (errs <= 6) $display("ring byte %0d: read %h want %h (next %h)", k, v, pat[k], pat[k+1]);
            end
        end
        $display("RESULT_U2 errors=%0d (reads that returned the NEXT byte: %0d)", errs, shift_hits);
        $finish;
    end
endmodule
