// tb_hdd.sv -- the ProDOS hard disk card (hdd.sv) with HOST_BUF: blocks move
// straight between a2hostd and the 512-byte sector buffer (SPI memory SPACE 7).
//
// Plays the driver ROM's register sequence on the bus (slot 5: $C0D0-$C0DF) and
// a2hostd on the host port: a READ must stream the host's block out of NEXTBYTE
// byte for byte, a WRITE must hand the host exactly the bytes the Apple stored.
// (Through the old SDRAM window the card could copy a half-written block.)
//
// Clocking follows the core as in tb_drvwr.sv; the select is seen from the first
// PHI0 clock and write data only partway in.
`timescale 1ns/1ps
module tb_hdd;
    reg clk = 0;
    always #2.315 clk = ~clk;

    a2bus_if a2bus ();
    slot_if slot ();
    drive_volume_if vols [2] ();
    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) ram ();

    reg rst_n = 0, phi0 = 0, phi0_pe = 0, phi1_pe = 0, rw = 1;
    reg [15:0] addr = 16'h0000;
    reg [7:0] bus_data = 8'hFF;
    assign a2bus.clk_logic = clk;
    assign a2bus.system_reset_n = rst_n;
    assign a2bus.device_reset_n = rst_n;
    assign a2bus.phi0 = phi0;
    assign a2bus.phi0_posedge = phi0_pe;
    assign a2bus.phi1_posedge = phi1_pe;
    assign a2bus.phi1 = !phi0;
    assign a2bus.rw_n = rw;
    assign a2bus.addr = addr;
    assign a2bus.data = bus_data;
    assign a2bus.data_in_strobe = 1'b0;

    reg devsel_n = 1, cfg_n = 1;
    assign slot.slot = 3'd5;
    assign slot.card_id = 8'd6;
    assign slot.card_enable = 1'b1;
    assign slot.card_config = 32'd0;
    assign slot.config_select_n = cfg_n;
    assign slot.dev_select_n = devsel_n;
    assign slot.io_select_n = 1'b1;
    assign slot.io_strobe_n = 1'b1;

    reg ack0 = 0;
    assign vols[0].ready = 1'b1; assign vols[0].mounted = 1'b1; assign vols[0].readonly = 1'b0;
    assign vols[0].size = 32'd4096; assign vols[0].ack = ack0;
    assign vols[1].ready = 1'b1; assign vols[1].mounted = 1'b0; assign vols[1].readonly = 1'b0;
    assign vols[1].size = 32'd0; assign vols[1].ack = 1'b0;
    assign ram.ready = 1'b0;

    reg        hb_we = 0;
    reg [8:0]  hb_addr = 0;
    reg [7:0]  hb_wdata = 0;
    wire [7:0] hb_rdata;
    wire [7:0] dout;
    wire       rd_en;

    HDD #(.ID(6), .HOST_BUF(1'b1)) dut (
        .a2bus_if(a2bus), .slot_if(slot), .data_o(dout), .rd_en_o(rd_en),
        .ram_hdd_if(ram), .volumes(vols),
        .host_buf_we_i(hb_we), .host_buf_addr_i(hb_addr), .host_buf_wdata_i(hb_wdata), .host_buf_rdata_o(hb_rdata));

    function automatic [7:0] rblk(input integer i); rblk = 8'(i * 7 + 3); endfunction   // block a2hostd serves
    function automatic [7:0] wblk(input integer i); wblk = 8'(i ^ 8'hA5); endfunction   // block the Apple writes

    // a2hostd on SPACE 7
    integer errs = 0, host_bad = 0;
    always begin
        @(posedge clk);
        if (rst_n && vols[0].rd) begin
            integer j;
            for (j = 0; j < 512; j++) begin
                @(posedge clk); hb_we <= 1; hb_addr <= 9'(j); hb_wdata <= rblk(j);
            end
            @(posedge clk); hb_we <= 0;
            repeat (10) @(posedge clk);
            ack0 <= 1; @(posedge clk); ack0 <= 0;
            wait (!vols[0].rd);
        end else if (rst_n && vols[0].wr) begin
            integer j;
            for (j = 0; j < 512; j++) begin
                @(posedge clk); hb_addr <= 9'(j);
                @(posedge clk); @(posedge clk);
                if (hb_rdata !== wblk(j)) begin
                    host_bad++;
                    if (host_bad < 4) $display("FAIL host read of written byte %0d = %h, want %h", j, hb_rdata, wblk(j));
                end
            end
            ack0 <= 1; @(posedge clk); ack0 <= 0;
            wait (!vols[0].wr);
        end
    end

    // one CPU cycle; returns the card's byte as the 6502 latches it (end of PHI0)
    task automatic cpu_cycle(input [15:0] a, input bit r, input [7:0] wd, output [7:0] rd);
        integer i;
        for (i = 0; i < 105; i++) begin
            @(negedge clk); phi0 = 0; phi0_pe = 0; phi1_pe = 0; devsel_n = 1; bus_data = 8'hFF;
            if (i == 60) begin addr = a; rw = r; end      // address settles in PHI1
        end
        for (i = 0; i < 105; i++) begin
            @(negedge clk);
            phi0 = 1; phi0_pe = (i == 0); phi1_pe = (i == 104);
            devsel_n = !(a[15:4] == 12'hC0D);
            bus_data = (!r && i >= 30) ? wd : 8'hEE;
            if (i == 103) rd = dout;
        end
    endtask

    reg [7:0] v;
    integer k, bad;
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk); cfg_n = 0; repeat (5) @(posedge clk); cfg_n = 1;   // slot config
        cpu_cycle(16'h0300, 1, 0, v);
        // ---- READ block 5 of unit 1 ----
        cpu_cycle(16'hC0D3, 0, 8'h00, v);
        cpu_cycle(16'hC0D6, 0, 8'h05, v);
        cpu_cycle(16'hC0D7, 0, 8'h00, v);
        cpu_cycle(16'hC0D2, 0, 8'h01, v);
        cpu_cycle(16'hC0D0, 1, 0, v);                  // EXECUTE
        for (k = 0; k < 20000; k++) begin cpu_cycle(16'hC0D1, 1, 0, v); if (!v[7]) break; end
        if (v[7] || v[0]) begin errs++; $display("FAIL read status %h", v); end
        cpu_cycle(16'hC0DB, 1, 0, v);
        if (v !== 8'h00) begin errs++; $display("FAIL read result %h", v); end
        bad = 0;
        for (k = 0; k < 512; k++) begin
            cpu_cycle(16'hC0D8, 1, 0, v);
            if (v !== rblk(k)) begin bad++; if (bad < 4) $display("FAIL NEXTBYTE %0d = %h, want %h", k, v, rblk(k)); end
        end
        if (bad) begin errs++; $display("FAIL %0d of 512 read bytes wrong", bad); end
        // ---- WRITE: fill the buffer through NEXTBYTE, then EXECUTE ----
        cpu_cycle(16'hC0D2, 0, 8'h02, v);              // command write resets the pointer
        for (k = 0; k < 512; k++) cpu_cycle(16'hC0D8, 0, wblk(k), v);
        cpu_cycle(16'hC0D0, 1, 0, v);
        for (k = 0; k < 40000; k++) begin cpu_cycle(16'hC0D1, 1, 0, v); if (!v[7]) break; end
        if (v[7] || v[0]) begin errs++; $display("FAIL write status %h", v); end
        if (host_bad) begin errs++; $display("FAIL %0d of 512 written bytes wrong at the host", host_bad); end
        // ---- STATUS ----
        cpu_cycle(16'hC0D2, 0, 8'h00, v);
        cpu_cycle(16'hC0D0, 1, 0, v);
        cpu_cycle(16'hC0D0 + 16'h9, 1, 0, v);
        if (v !== 8'h00) begin errs++; $display("FAIL size low %h, want 00 (4096 blocks)", v); end
        cpu_cycle(16'hC0DA, 1, 0, v);
        if (v !== 8'h10) begin errs++; $display("FAIL size high %h, want 10", v); end
        $display("RESULT_HDD errors=%0d", errs);
        $finish;
    end
endmodule
