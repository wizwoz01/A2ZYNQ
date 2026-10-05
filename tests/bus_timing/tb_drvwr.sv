// tb_drvwr.sv -- the drive_ii write head on its own: one nibble on the track per
// $C0nC access, however early in the cycle the select is seen.
//
// On the red card the select is already decoded when PHI0 rises, so it is high on
// both Q3 ticks of the cycle (phi0 rising and phi1 rising, where the core's phi0 is
// still high). The head used to store on every Q3 tick, so every nibble was written
// twice (d5 d5 aa aa ad ad ...), no written sector decoded, and saves kept the old
// data. tb_menu's full bus model shows the select only late in PHI0 and missed it.
//
// Clocking follows the core: phi0_posedge on the first PHI0 clock, phi1_posedge on
// the last one. Write data is valid only partway into PHI0, as from a 6502.
`timescale 1ns/1ps
module tb_drvwr;
    reg clk = 0;
    always #2.315 clk = ~clk;                  // ~216 MHz clk_logic

    a2bus_if a2bus ();
    drive_volume_if vol ();
    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) ram ();

    reg rst_n = 0, phi0 = 0, phi0_pe = 0, phi1_pe = 0;
    reg [7:0] bus_data = 8'hFF;
    assign a2bus.clk_logic = clk;
    assign a2bus.system_reset_n = rst_n;
    assign a2bus.device_reset_n = rst_n;
    assign a2bus.phi0 = phi0;
    assign a2bus.phi0_posedge = phi0_pe;
    assign a2bus.phi1_posedge = phi1_pe;
    assign a2bus.phi1 = !phi0;
    assign a2bus.phi0_negedge = 1'b0;
    assign a2bus.phi1_negedge = 1'b0;
    assign a2bus.clk_14M_posedge = 1'b0;
    assign a2bus.data = bus_data;

    reg write_mode = 0, read_disk = 0, write_reg = 0;
    reg        nib_we = 0;
    reg [12:0] nib_addr = 0, nib_raddr = 0;
    reg [7:0]  nib_data = 0;
    wire [7:0] nib_rdata;
    wire [7:0] data_out;

    assign vol.ready = 1'b1;
    assign vol.mounted = 1'b1;
    assign vol.readonly = 1'b0;
    assign vol.size = 32'd143360;
    reg ack = 0;
    assign vol.ack = ack;

    drive_ii dut (
        .a2bus_if(a2bus), .data_o(data_out), .volume_if(vol),
        .drive_id_i(1'b0), .drive_active(1'b1),
        .host_nib_we_i(nib_we), .host_nib_drive_i(1'b0), .host_nib_addr_i(nib_addr), .host_nib_data_i(nib_data),
        .host_nib_raddr_i(nib_raddr), .host_nib_rdata_o(nib_rdata),
        .motor_phase_i(4'b0000), .write_mode_i(write_mode), .read_disk_i(read_disk), .write_reg_i(write_reg),
        .ram_disk_if(ram));

    // a2hostd: answer the track load with a known pattern, ack saves
    function automatic [7:0] loaded(input integer j); loaded = 8'(j * 3 + 1); endfunction
    always begin
        @(posedge clk);
        if (rst_n && vol.rd) begin
            integer j;
            for (j = 0; j < 6656; j++) begin
                @(posedge clk); nib_we <= 1; nib_addr <= 13'(j); nib_data <= loaded(j);
            end
            @(posedge clk); nib_we <= 0;
            repeat (20) @(posedge clk);
            ack <= 1; @(posedge clk); ack <= 0;
        end else if (rst_n && vol.wr) begin
            repeat (20) @(posedge clk); ack <= 1; @(posedge clk); ack <= 0;
        end
    end

    // one CPU cycle: 105 clocks of PHI1, then 105 of PHI0; signals change on falling clk
    task automatic cpu_cycle(input bit rd_disk, input bit wr_reg, input [7:0] wdata);
        integer i;
        for (i = 0; i < 105; i++) begin
            @(negedge clk); phi0 = 0; phi0_pe = 0; phi1_pe = 0; read_disk = 0; write_reg = 0; bus_data = 8'hFF;
        end
        for (i = 0; i < 105; i++) begin
            @(negedge clk);
            phi0 = 1; phi0_pe = (i == 0); phi1_pe = (i == 104);
            read_disk = rd_disk;                         // seen from the first PHI0 clock
            write_reg = wr_reg;
            bus_data = (wr_reg && i >= 30) ? wdata : 8'hEE;  // write data valid ~140 ns in
        end
    endtask

    task automatic host_rd(input [12:0] a, output [7:0] d);
        @(posedge clk); nib_raddr <= a;
        @(posedge clk); @(posedge clk); d = nib_rdata;
    endtask

    integer errs = 0, k, w0, adv;
    reg [7:0] v, wv [0:7];
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        for (k = 0; k < 400 && !(dut.nib_valid_r && dut.cur_track_r == 0); k++) cpu_cycle(0, 0, 0);
        if (!(dut.nib_valid_r && dut.cur_track_r == 0)) begin errs++; $display("FAIL track 0 never resident"); end
        for (k = 0; k < 40; k++) cpu_cycle(0, 0, 0);
        write_mode = 1;
        cpu_cycle(0, 0, 0);
        w0 = dut.track_byte_addr_r;
        for (k = 0; k < 8; k++) begin
            wv[k] = 8'hD5 + 8'(k * 9);
            cpu_cycle(0, 1, wv[k]);                     // STA $C0nD: load the latch
            cpu_cycle(0, 0, 0);
            cpu_cycle(1, 0, 0);                         // ORA $C0nC: shift it onto the track
            cpu_cycle(0, 0, 0);
        end
        write_mode = 0;
        adv = (dut.track_byte_addr_r - w0 + 6656) % 6656;
        if (adv != 8) begin errs++; $display("FAIL head moved %0d for 8 written nibbles", adv); end
        for (k = 0; k < 8; k++) begin
            host_rd(13'((w0 + k) % 6656), v);
            if (v !== wv[k]) begin errs++; $display("FAIL track byte %0d = %h, want %h", k, v, wv[k]); end
        end
        host_rd(13'((w0 + 8) % 6656), v);
        if (v !== loaded((w0 + 8) % 6656)) begin errs++; $display("FAIL byte after the write = %h, want %h (loaded)", v, loaded((w0 + 8) % 6656)); end
        if (!dut.dirty_r && !dut.save_req_r) begin errs++; $display("FAIL written track not dirty"); end
        $display("RESULT_DRVWR errors=%0d head_moved=%0d", errs, adv);
        $finish;
    end
endmodule
