// WORK IN PROGRESS
//
// Apple II Disk II controller
//
// Adapted from:
// https://github.com/alanswx/Apple-II-Verilog_MiSTer/blob/master/rtl/disk_ii.v
// https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/disk_ii.vhd
//
// Adapted for use with A2FPGA multicard bus interface
//
// Uses A2FPGA SDRAM controller for disk storage and requires the use
// of the PicoSoC core to provide the FAT32 file system interface
//
// Current status: Functional with hardcoded disk images
//

module DiskII #(
    parameter bit [7:0] ID = 4,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,

    mem_port_if.client ram_disk_if,

    drive_volume_if.drive volumes[2],

    input host_nib_we_i,
    input host_nib_drive_i,
    input [12:0] host_nib_addr_i,
    input [7:0] host_nib_data_i,

    // Track read-back for saves (SPI memory SPACE 6): drive, byte; data one clock later
    input host_nib_rdrive_i,
    input [12:0] host_nib_raddr_i,
    output [7:0] host_nib_rdata_o,

    // Boot menu RAM, host side (SPI memory SPACE 4, see diskmenu.a65)
    input menu_host_wr_i,
    input [10:0] menu_host_addr_i,
    input [7:0] menu_host_wdata_i,
    output [7:0] menu_host_rdata_o

);

    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0) begin  // disable all cards when slot 0 is selected for configuration
                card_enable <= 1'b0;
            end else if (slot_if.card_id == ID) begin // enable this card
                card_enable <= slot_if.card_enable && ENABLE;
            end
        end
    end

    wire card_sel = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel = card_sel && !slot_if.dev_select_n;
    wire card_io_sel = card_sel && !slot_if.io_select_n;

    reg [3:0] motor_phase_r;
    reg drive_on_r;
    reg drive_real_on_r;
    reg drive2_select_r;
    reg q6_r;
    reg q7_r;

    wire [7:0] rom_dout_w;
    wire [7:0] d_out1_w;
    wire [7:0] d_out2_w;

    wire read_disk_w;
    wire write_reg_w;
    wire [7:0] data_reg_w;
    wire write_mode_w;


    always @(posedge a2bus_if.clk_logic) begin : interpret_io
        begin
            if (!a2bus_if.system_reset_n) begin
                motor_phase_r <= {4{1'b0}};
                drive_on_r <= 1'b0;
                drive2_select_r <= 1'b0;
                q6_r <= 1'b0;
                q7_r <= 1'b0;
            end else if (card_dev_sel) begin
                if (a2bus_if.addr[3] == 1'b0)
                    motor_phase_r[(a2bus_if.addr[2:1])] <= a2bus_if.addr[0];
                else
                    case (a2bus_if.addr[2:1])
                        2'b00:   drive_on_r <= a2bus_if.addr[0];
                        // A0 is trustworthy again now that apple_bus commits the
                        // address before PHI0 selects open (it was read from the
                        // previous cycle, which is why drive 2 / Q6H looked set).
                        2'b01:   drive2_select_r <= a2bus_if.addr[0];
                        2'b10:   q6_r <= a2bus_if.addr[0];
                        2'b11:   q7_r <= a2bus_if.addr[0];
                        default: ;
                    endcase
            end
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : drive_on_delay
        static reg [23:0] spindown_delay_r;
        static reg drive_on_old_r;
        if (!a2bus_if.system_reset_n) begin
            spindown_delay_r = {24{1'b0}};
            drive_real_on_r <= 1'b0;
        end else begin
            if (spindown_delay_r != 0) begin
                spindown_delay_r = 24'(spindown_delay_r - 1'b1);
                if (spindown_delay_r == 0) drive_real_on_r <= 1'b0;
            end

            if (drive_on_r == 1'b1) begin
                spindown_delay_r = {24{1'b0}};
                drive_real_on_r <= 1'b1;
            end else if (drive_on_old_r == 1'b1) spindown_delay_r = 14000000;

            drive_on_old_r = drive_on_r;
        end
    end

    wire drive_1_active = drive_real_on_r & (~drive2_select_r);
    wire drive_2_active = drive_real_on_r & drive2_select_r;
    assign write_mode_w = q7_r;

    assign read_disk_w = (card_dev_sel & a2bus_if.addr[3:0] == 4'hc) ? 1'b1 : 1'b0;
    assign write_reg_w = (card_dev_sel & a2bus_if.addr[3:2] == 2'b11 & a2bus_if.addr[0] == 1'b1) ? 1'b1 : 1'b0;

    // Boot menu ($C800-$CFFF). The boot ROM hands over to diskmenu.a65 there;
    // a2hostd fills in the screen image and answers through the mailbox page.
    // Standard expansion-ROM protocol: any access to this card's $Cn00 page
    // claims $C800-$CFFF, any access to $CFFF releases it. Decided at the end
    // of the cycle (PHI1 rising, like INTC8ROM in apple_memory), when the
    // address is the settled one, not an early PHI1 sample.
    reg c8_own_r;
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n)
            c8_own_r <= 1'b0;
        else if (a2bus_if.phi1_posedge && (a2bus_if.addr == 16'hCFFF) && !a2bus_if.m2sel_n)
            c8_own_r <= 1'b0;
        else if (a2bus_if.phi1_posedge && card_enable && (slot_if.card_id == ID) && !slot_if.io_select_n)
            c8_own_r <= 1'b1;
    end
    wire card_c8_sel = card_enable && c8_own_r && !slot_if.io_strobe_n && a2bus_if.phi0 &&
                       (a2bus_if.addr[10:0] != 11'h7FF);

    // 2 KB: $C800-$C9FF menu code, $CA00-$CDFF screen image, $CE00-$CEFF
    // mailbox. The Apple may only write the mailbox, so a stray store into
    // $C800 space cannot corrupt the code. Port A = Apple, port B = host.
    (* ram_style = "block" *) reg [7:0] menu_mem [0:2047];
    initial $readmemh("diskmenu.hex", menu_mem);
    wire menu_a_we = card_c8_sel && !a2bus_if.rw_n && a2bus_if.data_in_strobe &&
                     (a2bus_if.addr[10:8] == 3'b110);
    reg [7:0] menu_a_q;
    always @(posedge a2bus_if.clk_logic) begin
        if (menu_a_we) menu_mem[a2bus_if.addr[10:0]] <= a2bus_if.data; else menu_a_q <= menu_mem[a2bus_if.addr[10:0]];
    end
    reg [7:0] menu_b_q;
    always @(posedge a2bus_if.clk_logic) begin
        if (menu_host_wr_i) menu_mem[menu_host_addr_i] <= menu_host_wdata_i; else menu_b_q <= menu_mem[menu_host_addr_i];
    end
    assign menu_host_rdata_o = menu_b_q;

    assign data_reg_w = (drive2_select_r == 1'b0) ? d_out1_w : d_out2_w;
    assign data_o = card_c8_sel ? menu_a_q : card_io_sel ? rom_dout_w : (q6_r == 1'b0) ? data_reg_w : 8'h00;
    assign rd_en_o = (card_io_sel | card_dev_sel | card_c8_sel) & a2bus_if.rw_n;

    localparam PORT_ADDR_WIDTH = 21;
    localparam DATA_WIDTH = 32;
    localparam DQM_WIDTH = 4;
    localparam PORT_OUTPUT_WIDTH = 32;

    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) ram_disk1_if ();

    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) ram_disk2_if ();

    mem_if_mux ram_disk_mux (
        .switch(drive2_select_r),
        //.switch(drive2_select_r),
        .controller(ram_disk_if),
        .client_0(ram_disk1_if),
        .client_1(ram_disk2_if)
    );

    wire [7:0] nib_rd1_w, nib_rd2_w;
    reg        nib_rdrive_q;
    always @(posedge a2bus_if.clk_logic) nib_rdrive_q <= host_nib_rdrive_i;
    assign host_nib_rdata_o = nib_rdrive_q ? nib_rd2_w : nib_rd1_w;

    drive_ii drive_1 (
        .a2bus_if(a2bus_if),
        .data_o  (d_out1_w),

        .volume_if(volumes[0]),

        .drive_id_i(1'b0),
        .drive_active(drive_1_active),
        .host_nib_we_i(host_nib_we_i),
        .host_nib_drive_i(host_nib_drive_i),
        .host_nib_addr_i(host_nib_addr_i),
        .host_nib_data_i(host_nib_data_i),
        .host_nib_raddr_i(host_nib_raddr_i),
        .host_nib_rdata_o(nib_rd1_w),
        .motor_phase_i(motor_phase_r),
        .write_mode_i(write_mode_w),
        .read_disk_i(read_disk_w),
        .write_reg_i(write_reg_w),

        .ram_disk_if(ram_disk1_if)
    );

    drive_ii drive_2 (
        .a2bus_if(a2bus_if),
        .data_o  (d_out2_w),

        .volume_if(volumes[1]),

        .drive_id_i(1'b1),
        .drive_active(drive_2_active),
        .host_nib_we_i(host_nib_we_i),
        .host_nib_drive_i(host_nib_drive_i),
        .host_nib_addr_i(host_nib_addr_i),
        .host_nib_data_i(host_nib_data_i),
        .host_nib_raddr_i(host_nib_raddr_i),
        .host_nib_rdata_o(nib_rd2_w),
        .motor_phase_i(motor_phase_r),
        .write_mode_i(write_mode_w),
        .read_disk_i(read_disk_w),
        .write_reg_i(write_reg_w),

        .ram_disk_if(ram_disk2_if)
    );

    rom #(8, 8, "diskii.hex") diskrom (
        .clock(a2bus_if.clk_logic),
        .ce(1'b1),
        .a(a2bus_if.addr[7:0]),
        .data_out(rom_dout_w)
    );

endmodule
