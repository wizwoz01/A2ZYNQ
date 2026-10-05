`timescale 1ns/1ps
// a2_bus_phy D0-D7 drive options, checked against an idealised bus cycle:
// PHI1 489 ns / PHI0 489 ns, the core raises its request REQ_AT ns into PHI1
// (or into PHI0 if negative) and drops it REL_AT ns into the next PHI1, with
// the byte changing from B0 to B1 in consecutive cycles. Reports when the pins
// start and stop driving relative to the PHI edges, and the order in which the
// bits reach the new byte in soft-landing mode.
module tb_phy;
    parameter int  FINE   = 0;          // core_drive_fine
    parameter int  DCFG   = 0;          // core_drive_cfg
    parameter real REQ_AT = 400.0;      // request rise, ns after PHI1 rose (at-commit style)
    parameter real REL_AT = 190.0;      // request drop, ns after the next PHI1 rose
    parameter int  B0     = 8'h00;
    parameter int  B1     = 8'hBD;

    reg clk = 0, clk4x = 0;
    always #9.259 clk = ~clk;
    always #2.31475 clk4x = ~clk4x;
    reg rst_n = 0;
    reg phi0 = 0, phi1 = 1;
    reg [7:0] cdat = 8'h00;
    reg creq = 0;
    // U5 keeps the last level on a released line: a weak keeper per bit.
    wire [7:0] dbus;
    reg  [7:0] keep = 8'h00;
    genvar kb;
    for (kb = 0; kb < 8; kb++) begin : g_keep
        assign (weak1, weak0) dbus[kb] = keep[kb];
        always @(posedge clk4x) if (dbus[kb] === 1'b0 || dbus[kb] === 1'b1) keep[kb] <= dbus[kb];
    end
    wire [7:0] din;

    a2_bus_phy phy(
        .clk(clk), .reset_n(rst_n), .clocks_locked(1'b1), .host_ready(1'b1), .a2_5v_present(1'b1),
        .a2_data(dbus), .a2_addr(16'h0000), .a2_rw(1'b1), .a2_phi0(phi0), .a2_phi1(phi1),
        .a2_7m(1'b0), .a2_q3(1'b0), .a2_sync(1'b0), .a2_iosel_n(1'b1), .a2_iostrb_n(1'b1),
        .a2_devsel_n(1'b1), .a2_m2sel(1'b0), .a2_m2b0(1'b0),
        .a2_reset_asserted_sense(1'b0), .a2_rdy_n_sense(1'b1), .a2_dma_n_sense(1'b1),
        .a2_nmi_n_sense(1'b1), .a2_irq_n_sense(1'b1), .a2_inh_n_sense(1'b1),
        .core_data_out(cdat), .core_data_drive(creq), .clk4x(clk4x), .core_drive_fine(FINE[7:0]),
        .core_drive_cfg(DCFG[15:0]), .core_data_in(din),
        .core_irq_assert(1'b0), .core_nmi_assert(1'b0), .core_rdy_assert(1'b0),
        .core_dma_assert(1'b0), .core_inh_assert(1'b0), .core_reset_assert(1'b0),
        .a2_data_dir(), .a2_data_oe_n(), .a2_input_oe_n(),
        .a2_irq_assert(), .a2_nmi_assert(), .a2_rdy_assert(),
        .a2_dma_assert(), .a2_inh_assert(), .a2_reset_assert(), .pl_ready(),
        .bus_addr(), .bus_rw(), .bus_phi0(), .bus_phi1(), .bus_7m(), .bus_q3(),
        .bus_sync(), .bus_iosel_n(), .bus_iostrb_n(), .bus_devsel_n(),
        .bus_m2sel(), .bus_m2b0(), .bus_reset_n(), .bus_rdy_n(),
        .bus_dma_n(), .bus_nmi_n(), .bus_irq_n(), .bus_inh_n());

    real t_p1, t_p0;
    wire drv = ~phy.pin_t[0];
    reg drv_d = 0;
    reg [7:0] seen = 8'h00;
    integer nstep = 0;
    always @(posedge clk4x) begin
        drv_d <= drv;
        if (drv && !drv_d)
            $display("RESULT   cycle byte %h: drive ON  at %s+%0.1f ns", cdat, (phi1 ? "PHI1" : "PHI0"), $realtime - (phi1 ? t_p1 : t_p0));
        if (!drv && drv_d)
            $display("RESULT   cycle byte %h: drive OFF at %s+%0.1f ns", cdat, (phi1 ? "PHI1" : "PHI0"), $realtime - (phi1 ? t_p1 : t_p0));
        if (drv && (phy.pin_d != seen)) begin
            if (drv_d) $display("RESULT     pins %h -> %h at %s+%0.1f", seen, phy.pin_d, (phi1 ? "PHI1" : "PHI0"), $realtime - (phi1 ? t_p1 : t_p0));
            seen <= phy.pin_d;
        end
        if (!drv) seen <= phy.pin_d;
    end

    task automatic cyc(input [7:0] b, input do_req);
        // PHI1
        phi1 = 1; phi0 = 0; t_p1 = $realtime;
        fork
            begin #(REL_AT) creq = 0; end
            begin if (do_req && REQ_AT >= 0) begin #(REQ_AT) cdat = b; creq = 1; end end
        join_none
        #489.0;
        phi1 = 0; phi0 = 1; t_p0 = $realtime;
        if (do_req && REQ_AT < 0) begin #(-REQ_AT) cdat = b; creq = 1; #(489.0 + REQ_AT); end
        else #489.0;
    endtask

    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        repeat (400) @(posedge clk);
        cyc(8'h00, 0); cyc(8'h00, 0);
        cyc(B0[7:0], 1);
        cyc(B1[7:0], 1);
        cyc(8'h00, 0);
        cyc(8'h00, 0);
        $display("RESULT done FINE=%h DCFG=%h REQ_AT=%0.0f", FINE, DCFG, REQ_AT);
        $finish;
    end
endmodule
