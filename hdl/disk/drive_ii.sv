
// WORK IN PROGRESS
//
// Drive II
//
// Adapted from:
// https://github.com/alanswx/Apple-II-Verilog_MiSTer/blob/master/rtl/drive_ii.v
// https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/drive_ii.vhd
//
// Adapted for use with A2FPGA multicard bus interface
//
// Uses A2FPGA SDRAM controller for disk storage and requires the use
// of the PicoSoC core to provide the FAT32 file system interface
//
// Current status: Functional with hardcoded disk images
//

module drive_ii (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,

    drive_volume_if.drive volume_if,

    input drive_id_i,
    input drive_active,
    input host_nib_we_i,
    input host_nib_drive_i,
    input [12:0] host_nib_addr_i,
    input [7:0] host_nib_data_i,
    input [12:0] host_nib_raddr_i,      // host read-back of nib_mem (the track a save sends)
    output reg [7:0] host_nib_rdata_o,  // nib_mem[host_nib_raddr_i], one clock later
    input [3:0] motor_phase_i,
    input write_mode_i,
    input read_disk_i,
    input write_reg_i,

    mem_port_if.client ram_disk_if
);

    // --- Track-on-demand loader (NanoApple2 floppy_track model) --------------
    // Instead of the whole nibblized disk living in SDRAM, only the track the
    // head is currently over is resident, in a small per-drive 8KB SDRAM window.
    // On a seek we ask the MCU (drive_volume_if block protocol) to stream the
    // new track in: lba = track*13 (13 * 512 = 0x1A00 bytes/track). Read-only
    // for now; dirty-track writeback is a later phase.
    localparam [5:0] TRACK_NONE = 6'h3f;
    reg  [5:0] cur_track_r;   // track resident in the SDRAM window
    reg  [5:0] req_track_r;   // track being fetched (latched at request time)
    reg        load_req_r;    // waiting for the MCU to stream the track in
    reg        save_req_r;    // waiting for the MCU to flush a dirty track back
    reg        dirty_r;       // resident track has writes not yet flushed

    assign volume_if.active  = drive_active;
    assign volume_if.blk_cnt = 6'd12;                 // 13 sectors = 0x1A00 bytes
    // A save flushes the resident (old) track; a load fetches the new track.
    assign volume_if.lba     = 32'd13 * (save_req_r ? cur_track_r : req_track_r);
    assign volume_if.rd      = load_req_r;
    assign volume_if.wr      = save_req_r;


    logic [5:0] track_w;  // output to ramdisk
    reg track_we_r;  // output to ramdisk
    logic track_busy_w;  // input from ramdisk

    assign track_busy_w = 1'b0;

    reg [7:0] phase_r;

    reg [12:0] track_byte_addr_r;
    reg [7:0] data_r;
    reg reset_data_r;
    reg [5:0] byte_delay_r;

    // Local copy of the 6656-byte GCR track. Bytes are captured from the SPI
    // XFER as a2hostd sends them. Reading the same bytes back out of DDR
    // returned zeros, so the boot ROM's $D5 $AA $96 hunt never finished.
    (* ram_style = "distributed" *) reg [7:0] nib_mem [0:8191];
    reg        nib_valid_r;
    reg        nib_valid_d_r;
    reg        load_req_d_r;
    reg        head_we_r;
    reg [12:0] head_addr_r;
    reg [7:0]  head_data_r;
    reg        q6l_seen_r;    // write mode: this cycle is a $C0nC access (store at its end)
    wire       host_nib_hit_w = host_nib_we_i && (host_nib_drive_i == drive_id_i);
    wire [7:0] nib_byte_w = nib_mem[track_byte_addr_r];

    // Stepper cadence: classic boards tick on 14M (7M rise|fall). Smart-Zynq
    // always steps on phi0 — 7M is often missing/noisy on the proto, and a
    // false "7M alive" from glitches left the head parked at the old power-on
    // track-17 default (a2hostd: lba stuck at 0xdd with motor active).
`ifdef SMART_ZYNQ
    wire step_tick_w = a2bus_if.phi0_posedge;
`else
    reg [15:0] seven_m_watch_r;
    reg        seven_m_alive_r;
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            seven_m_watch_r <= 16'd0;
            seven_m_alive_r <= 1'b0;
        end else if (a2bus_if.clk_14M_posedge) begin
            seven_m_watch_r <= 16'd0;
            seven_m_alive_r <= 1'b1;
        end else if (seven_m_watch_r != 16'hffff) begin
            seven_m_watch_r <= seven_m_watch_r + 16'd1;
            if (seven_m_watch_r == 16'd54000)
                seven_m_alive_r <= 1'b0;
        end
    end
    wire step_tick_w = seven_m_alive_r ? a2bus_if.clk_14M_posedge
                                       : a2bus_if.phi0_posedge;
`endif

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : update_phase
        automatic integer phase_change_temp;
        automatic integer new_phase_temp;
        automatic logic [3:0] rel_phase_temp;
        // Track-on-demand: start over track 0 so a cold boot can read the
        // boot sector even if the stepper soft-switches are still flaky.
        if (!a2bus_if.system_reset_n) phase_r <= 0;
        else begin
            if (step_tick_w) begin
                if (drive_active) begin
                    phase_change_temp = 0;
                    new_phase_temp = phase_r;
                    rel_phase_temp = motor_phase_i;
                    case (phase_r[2:1])
                        2'b00:   rel_phase_temp = {rel_phase_temp[1:0], rel_phase_temp[3:2]};
                        2'b01:   rel_phase_temp = {rel_phase_temp[2:0], rel_phase_temp[3]};
                        2'b10:   ;
                        2'b11:   rel_phase_temp = {rel_phase_temp[0], rel_phase_temp[3:1]};
                        default: ;
                    endcase

                    if (phase_r[0] == 1'b1)
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -3;
                            4'b0010: phase_change_temp = -1;
                            4'b0011: phase_change_temp = -2;
                            4'b0100: phase_change_temp = 1;
                            4'b0101: phase_change_temp = -1;
                            4'b0110: phase_change_temp = 0;
                            4'b0111: phase_change_temp = -1;
                            4'b1000: phase_change_temp = 3;
                            4'b1001: phase_change_temp = 0;
                            4'b1010: phase_change_temp = 1;
                            4'b1011: phase_change_temp = -3;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase
                    else
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -2;
                            4'b0010: phase_change_temp = 0;
                            4'b0011: phase_change_temp = -1;
                            4'b0100: phase_change_temp = 2;
                            4'b0101: phase_change_temp = 0;
                            4'b0110: phase_change_temp = 1;
                            4'b0111: phase_change_temp = 0;
                            4'b1000: phase_change_temp = 0;
                            4'b1001: phase_change_temp = 1;
                            4'b1010: phase_change_temp = 2;
                            4'b1011: phase_change_temp = -2;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase

                    if (new_phase_temp + phase_change_temp <= 0) new_phase_temp = 0;
                    else if (new_phase_temp + phase_change_temp > 139) new_phase_temp = 139;
                    else new_phase_temp = new_phase_temp + phase_change_temp;
                    phase_r <= 8'(new_phase_temp);
                end
            end
        end
    end

    assign track_w = phase_r[7:2];

    // The head may only read once the track the MCU streamed has been copied
    // into the local nibble RAM. Until that copy finishes, reads are $FF.
    wire track_resident_w = (cur_track_r == track_w) & ~load_req_r & ~save_req_r & nib_valid_r;

    // Track loader: on a seek, flush the old track if it was written, then fetch
    // the new track from the MCU (drive_volume_if block protocol). Save then load
    // are two separate request/ack handshakes.
    // A written track is also flushed as soon as the drive stops (motor off or
    // the other drive selected), so a reset or a disk swap right after a save
    // cannot lose it, and before the image is unmounted: a2hostd clears
    // `mounted` to swap disks, serves that last save from the old image, and the
    // cached track is then dropped so the next read comes from the new image.
    wire flush_w = dirty_r & (cur_track_r != TRACK_NONE) & ~volume_if.readonly &
                   ((cur_track_r != track_w) | ~drive_active | ~volume_if.mounted);
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : track_loader
        if (!a2bus_if.system_reset_n) begin
            cur_track_r <= TRACK_NONE;
            req_track_r <= 6'd0;
            load_req_r  <= 1'b0;
            save_req_r  <= 1'b0;
            dirty_r     <= 1'b0;
        end else begin
            if (track_we_r) dirty_r <= 1'b1;  // a write landed in the resident track

            if (save_req_r) begin
                if (volume_if.ack) begin      // MCU flushed the dirty track to the image
                    save_req_r <= 1'b0;
                    dirty_r    <= 1'b0;
                end
            end else if (load_req_r) begin
                if (volume_if.ack) begin      // MCU streamed the new track in
                    load_req_r  <= 1'b0;
                    cur_track_r <= req_track_r;
                end
            end else if (volume_if.ready & flush_w) begin
                save_req_r <= 1'b1;           // lba = cur_track*13
            end else if (~volume_if.mounted) begin
                cur_track_r <= TRACK_NONE;    // image gone or being swapped
                dirty_r     <= 1'b0;
            end else if (volume_if.ready & (cur_track_r != track_w)) begin
                req_track_r <= track_w;       // latch target, hold rd until ack
                load_req_r  <= 1'b1;
            end
        end
    end

    // Q3 is not wired on this board (top.sv ties a2_q3_i to 0, so
    // clk_q3_posedge never pulses). The WRITE head still uses a synthesized Q3
    // cadence from the CPU phase clocks (phi0_posedge | phi1_posedge, twice per
    // CPU cycle). The READ head no longer uses this — see below.
    wire q3_tick_w = a2bus_if.phi0_posedge | a2bus_if.phi1_posedge;

    // The SPI image write finishes before a2hostd pulses ACK, which drops
    // load_req. Until that edge the head emits $FF so a half-written track
    // is never parsed as an address field.
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : nib_valid
        if (!a2bus_if.system_reset_n) begin
            nib_valid_r  <= 1'b0;
            load_req_d_r <= 1'b0;
        end else begin
            load_req_d_r <= load_req_r;
            // A save only reads the window out; the local copy stays valid (a
            // flush with the head parked must not leave the track unreadable).
            if (load_req_r)
                nib_valid_r <= 1'b0;
            else if (load_req_d_r)
                nib_valid_r <= 1'b1;
        end
    end

    always @(posedge a2bus_if.clk_logic) begin : nib_ram
        if (host_nib_hit_w)
            nib_mem[host_nib_addr_i] <= host_nib_data_i;
        else if (head_we_r)
            nib_mem[head_addr_r] <= head_data_r;
    end

    // A save reads the written track from here (SPI memory SPACE 6). The SDRAM
    // window was the old source, but it did not hold the loaded track when read
    // back, so no sector decoded and every write-back was dropped.
    always @(posedge a2bus_if.clk_logic) host_nib_rdata_o <= nib_mem[host_nib_raddr_i];

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : read_head
        if (!a2bus_if.system_reset_n) begin
            track_byte_addr_r <= 13'b0;
            byte_delay_r      <= 6'b0;
            reset_data_r      <= 1'b0;
            nib_valid_d_r     <= 1'b0;
            head_we_r         <= 1'b0;
            head_addr_r       <= 13'b0;
            head_data_r       <= 8'b0;
            data_r            <= 8'hFF;
            q6l_seen_r        <= 1'b0;
        end else begin
            track_we_r    <= 1'b0;
            head_we_r     <= 1'b0;
            nib_valid_d_r <= nib_valid_r;
            if (!write_mode_i) q6l_seen_r <= 1'b0;   // only write mode uses it

            // Data-latch clear, decoupled from the nibble advance: the CPU reads
            // $C0EC during phi0; clear the latch only AFTER phi0 has fallen
            // (during phi1) so the clear can never race the CPU's end-of-phi0
            // bus sample. Placed before the nibble load below so a coincident
            // load still wins the data_r assignment (present the nibble, not 0).
            if (!write_mode_i) begin
                if (read_disk_i & a2bus_if.phi0)
                    reset_data_r <= 1'b1;
                else if (reset_data_r & ~a2bus_if.phi0) begin
                    data_r       <= 8'b0;
                    reset_data_r <= 1'b0;
                end
            end

            // A freshly copied track starts at byte 0 (gap of $FF, then the
            // address prologue). Hold the head for one nibble time so the
            // block-RAM read of byte 0 is valid before it is presented.
            if (nib_valid_r & ~nib_valid_d_r) begin
                track_byte_addr_r <= 13'b0;
                byte_delay_r      <= 6'd31;
            end else if (!write_mode_i) begin
                // One nibble per 32 CPU cycles, on phi1 rising only: the byte
                // changes early in PHI1, before any card drive of the cycle
                // starts, and holds through the whole $C0EC read up to the
                // phi0 falling edge where the 6502 latches it. (On the Smart-
                // Zynq red card the slot data lines settle slowly through U5,
                // so a byte that changed mid-drive read back corrupted.)
                if (a2bus_if.phi1_posedge & volume_if.ready & drive_active) begin
                    if (byte_delay_r == 0) begin
                        byte_delay_r <= 6'd31;
                        // A new nibble replaces the one the last read took: drop
                        // that read's pending clear, which would otherwise land a
                        // clock later (when phi0 falls) and wipe this nibble.
                        reset_data_r <= 1'b0;
                        if (track_resident_w) begin
                            data_r <= nib_byte_w;
                            if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                            else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                        end else begin
                            data_r <= 8'hFF;
                        end
                    end else begin
                        byte_delay_r <= 6'(byte_delay_r - 1'b1);
                    end
                end
            end else begin
                // Write mode: $C0nD/$C0nF writes load the latch; each $C0nC access
                // puts one nibble on the track. The access is noted while PHI0 is
                // high and stored once, at the end of the cycle. Storing on each Q3
                // tick wrote every nibble twice on the red card, whose select is
                // already seen when PHI0 rises (tests/bus_timing tb_drvwr.sv).
                if (q3_tick_w & volume_if.ready & drive_active & track_resident_w & write_reg_i)
                    data_r <= a2bus_if.data;
                if (read_disk_i & a2bus_if.phi0) q6l_seen_r <= 1'b1;
                if (a2bus_if.phi1_posedge) begin
                    q6l_seen_r <= 1'b0;
                    if (q6l_seen_r & volume_if.ready & drive_active & track_resident_w) begin
                        track_we_r  <= (~track_busy_w);
                        head_we_r   <= 1'b1;
                        head_addr_r <= track_byte_addr_r;
                        head_data_r <= data_r;
                        if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                        else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                    end
                end
            end
        end
    end

    assign data_o = data_r;

    // Reads come from nib_mem, and so do saves (host_nib_rdata_o). The head's
    // writes still go to the SDRAM window as well; nothing reads them there.
    assign ram_disk_if.addr = {9'b0, drive_id_i, track_byte_addr_r[12:2]};
    assign ram_disk_if.rd = 1'b0;
    assign ram_disk_if.wr = track_we_r;
    assign ram_disk_if.data = {4{data_r}};
    assign ram_disk_if.byte_en = track_we_r ? (4'b0001 << track_byte_addr_r[1:0]) : 4'b1111;
    assign ram_disk_if.burst = 1'b0;

endmodule
