`timescale 1ns/1ps

// Electrical-policy layer between the Zynq PL and the external SN74LVC245A
// transceivers/NPN stages on the Apple II proto-card.
//
// Five-LVC245 hardware allocation:
//   U1/U2  address A0..A15
//   U3     R/W, selects, PHI0/PHI1/7M/Q3
//   U4     SYNC, M2SEL, M2B0 and shared-line senses except /RES
//   U5     bidirectional D0..D7
// /RES sense is translated by Q7, an NPN inverter. Its Zynq-side signal is
// active high (1 means Apple /RES is asserted low).
// Apple daisy-chain pins 23/24/27/28 are intentionally not connected, matching
// the original A2N20v2 schematic.
module a2_bus_phy (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        clocks_locked,
    input  logic        host_ready,
    input  logic        a2_5v_present,

    inout  wire  [7:0]  a2_data,
    input  logic [15:0] a2_addr,
    input  logic        a2_rw,
    input  logic        a2_phi0,
    input  logic        a2_phi1,
    input  logic        a2_7m,
    input  logic        a2_q3,
    input  logic        a2_sync,
    input  logic        a2_iosel_n,
    input  logic        a2_iostrb_n,
    input  logic        a2_devsel_n,
    input  logic        a2_m2sel,
    input  logic        a2_m2b0,
    input  logic        a2_reset_asserted_sense,
    input  logic        a2_rdy_n_sense,
    input  logic        a2_dma_n_sense,
    input  logic        a2_nmi_n_sense,
    input  logic        a2_irq_n_sense,
    input  logic        a2_inh_n_sense,

    input  logic [7:0]  core_data_out,
    input  logic        core_data_drive,
    input  logic        clk4x,             // 216 MHz, phase-aligned with clk
    input  logic [7:0]  core_drive_fine,   // [7] start when requested, else [6:0] clk4x periods after PHI0 rises
    input  logic [15:0] core_drive_cfg,    // [3:0] step, [4] soft, [5] LSB first, [6] fall first / high first, [8] early release, [13:9] its delay, [14] open drain, [15] weak lines first
    output logic [7:0]  core_data_in,

    input  logic        core_irq_assert,
    input  logic        core_nmi_assert,
    input  logic        core_rdy_assert,
    input  logic        core_dma_assert,
    input  logic        core_inh_assert,
    input  logic        core_reset_assert,

    output logic        a2_data_dir,
    output logic        a2_data_oe_n,
    output logic        a2_input_oe_n,
    output logic        a2_irq_assert,
    output logic        a2_nmi_assert,
    output logic        a2_rdy_assert,
    output logic        a2_dma_assert,
    output logic        a2_inh_assert,
    output logic        a2_reset_assert,
    output logic        pl_ready,

    output logic [15:0] bus_addr,
    output logic        bus_rw,
    output logic        bus_phi0,
    output logic        bus_phi1,
    output logic        bus_7m,
    output logic        bus_q3,
    output logic        bus_sync,
    output logic        bus_iosel_n,
    output logic        bus_iostrb_n,
    output logic        bus_devsel_n,
    output logic        bus_m2sel,
    output logic        bus_m2b0,
    output logic        bus_reset_n,
    output logic        bus_rdy_n,
    output logic        bus_dma_n,
    output logic        bus_nmi_n,
    output logic        bus_irq_n,
    output logic        bus_inh_n
);
    logic [7:0] data_out_q;
    logic       drive_q;
    logic [7:0] ready_count;
    logic       enabled;

    // Apple +5 V sense: synchronize, and only call +5 V gone after it has read
    // low for ~150 us. Used raw, a one-clock glitch reset pl_ready and cut every
    // bus driver and receiver for 256 clocks (~5 us); the IIe then saw a
    // floating data bus (D7, which it pulls up, read back 1: $03 -> $83).
    (* ASYNC_REG = "TRUE" *) logic five_s1, five_s2;
    logic [12:0] five_lo_count;
    logic        five_ok;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            five_s1 <= 1'b0;
            five_s2 <= 1'b0;
            five_lo_count <= '0;
            five_ok <= 1'b0;
        end else begin
            five_s1 <= a2_5v_present;
            five_s2 <= five_s1;
            if (five_s2) begin
                five_lo_count <= '0;
                five_ok <= 1'b1;
            end else if (&five_lo_count) begin
                five_ok <= 1'b0;
            end else begin
                five_lo_count <= five_lo_count + 1'b1;
            end
        end
    end

    // Require stable clocks, PS service readiness and verified Apple +5-V
    // presence before any transceiver or open-collector output can be enabled.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ready_count <= '0;
            pl_ready    <= 1'b0;
        end else if (!clocks_locked || !host_ready || !five_ok) begin
            ready_count <= '0;
            pl_ready    <= 1'b0;
        end else if (!pl_ready) begin
            ready_count <= ready_count + 1'b1;
            if (&ready_count)
                pl_ready <= 1'b1;
        end
    end
    assign enabled = pl_ready && clocks_locked && host_ready && five_ok;

    // Register data and enable together. The external OE remains disabled until
    // after direction has reached its safe state.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            data_out_q <= 8'h00;
            drive_q    <= 1'b0;
        end else begin
            data_out_q <= core_data_out;
            drive_q    <= core_data_drive && enabled;
        end
    end

    // D0-D7 drive timing at 216 MHz. The request and byte come from the 54 MHz
    // registers above. By default the pins switch core_drive_fine[6:0] 4.6 ns
    // steps after this block sees PHI0 rise and the drive ends when the request
    // drops. The pins launch from IOB flops (one tristate flop per pin, no
    // fabric skew) at 4.6 ns resolution.
    //
    // Measured on the IIe through U5 (a TXB0108, Rev 3.0 red card): the slot bus
    // needs a long time to settle after the card starts driving (the TXB's edge
    // one-shots do not finish a transition on the loaded Apple bus; its ~4 kohm
    // hold finishes it), and several lines switching together corrupt the
    // weakly held lows ($BD, $7E, $F8... failed 40-85% in back-to-back ROM
    // reads). Hence the options:
    //   core_drive_fine[7]  early start: drive as soon as the request is up (with
    //                       the select opened at the early address commit, that
    //                       is late PHI1), instead of waiting for PHI0
    //   core_drive_cfg[8]   early release: end the drive core_drive_cfg[15:9]
    //                       clk4x periods after PHI1 rises instead of when the
    //                       request drops (~190 ns into PHI1); driving into PHI1
    //                       measured worse
    //   core_drive_cfg[4]   soft landing, one bit per core_drive_cfg[3:0]+1
    //                       periods (at least 2); core_drive_cfg[6] then walks the
    //                       falling bits first (a low needs the most settling
    //                       time; rising first measured worse), core_drive_cfg[15]
    //                       in the order D1 D6 D0 D7 D5 D2 D3 D4 (the lines that
    //                       failed most) instead of MSB/LSB first
    //   core_drive_cfg[14]  open drain: drive only the 0 bits and release the 1s
    //                       (for a TXS0108E U5, whose pull-ups and edge boosters
    //                       make the highs; its pass FET passes the lows)
    (* ASYNC_REG = "TRUE" *) logic p1_s1, p1_s2;
    logic [3:0] p1_sh;                       // 4 agreeing samples (18.5 ns) = a PHI1 level
    logic       p1_f, p1_fd;
    logic [7:0] c4;                          // clk4x periods since PHI0 rose
    logic [7:0] c1_4;                        // clk4x periods since PHI1 rose
    logic       armed4, open4, close4, p0_seen4, req4, drive_now4;
    logic [7:0] dat4;
    (* IOB = "TRUE" *) logic [7:0] pin_d;
    (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) logic [7:0] pin_t;   // 1 = Zynq side of U5 released
    (* IOB = "TRUE" *) logic pin_dir;                            // U5 DIR: 1 = Apple -> Zynq
    logic [7:0] pd_r;                                        // next pin_d
    (* DONT_TOUCH = "TRUE" *) logic [7:0] pt_r;             // next pin_t, one flop per pin
    logic [7:0] pd2_r;                                       // pd_r / pt_r with open drain applied
    (* DONT_TOUCH = "TRUE" *) logic [7:0] pt2_r;
    logic       pdir_r;
    wire drive4 = req4 && open4 && !close4;
    wire        early_start4 = core_drive_fine[7];
    wire [7:0]  fine4        = {1'b0, core_drive_fine[6:0]};
    wire        early_rel4   = core_drive_cfg[8];
    wire [7:0]  rel_dly4     = {3'b000, core_drive_cfg[13:9]};
    wire        od4          = core_drive_cfg[14];
    wire        weak1st4     = core_drive_cfg[15];

    // Soft landing (core_drive_cfg[4]): the byte is walked onto the bus one bit
    // at a time. Start: the Zynq drives the value the bus already holds (as U5
    // passes it back while the pins are released), then flips one differing
    // bit per step toward the card's byte. End: release the Zynq pins; U5 keeps
    // the last levels on the Apple side through its weak hold.
    localparam [1:0] S_IDLE = 2'd0, S_DIR = 2'd1, S_DRIVE = 2'd2, S_REL = 2'd3;
    logic [1:0] st4;
    logic [7:0] bus_s1, bus_s2;
    logic [3:0] stp_cnt;
    wire        soft4  = core_drive_cfg[4];
    wire        lsb4   = core_drive_cfg[5];
    wire [3:0]  stp_n4 = core_drive_cfg[3:0];
    // The next walk step is worked out a clock ahead from a fabric copy of the
    // pins (cur_pd), so the IOB flops load a register, not the step logic
    // (216 MHz timing); a step therefore takes at least 2 clk4x periods.
    wire [3:0]  stp_eff4 = (stp_n4 == 4'd0) ? 4'd1 : stp_n4;
    logic [7:0] cur_pd, nxt_pd;
    logic       need_step;
    // core_drive_cfg[6]: soft mode - rising bits first; immediate mode - high
    // first: each drive starts with $FF for [3:0] clk4x periods (0 = 6, ~28 ns),
    // then the byte (measured worse than a direct drive on the IIe; kept as an
    // option).
    wire        opt6_4 = core_drive_cfg[6];
    wire [4:0]  ff_len4 = (stp_n4 == 4'd0) ? 5'd6 : {1'b0, stp_n4};
    logic [4:0] hf_cnt;
    function automatic [2:0] weak_bit(input integer k);
        case (k)
            0: weak_bit = 3'd1;  1: weak_bit = 3'd6;  2: weak_bit = 3'd0;  3: weak_bit = 3'd7;
            4: weak_bit = 3'd5;  5: weak_bit = 3'd2;  6: weak_bit = 3'd3;  default: weak_bit = 3'd4;
        endcase
    endfunction
    function automatic [7:0] step1(input [7:0] cur, input [7:0] tgt, input lsb, input fall_first, input wk);
        reg [7:0] d;
        reg hit;
        integer i, b;
        begin
            d = cur ^ tgt;
            if (fall_first && ((d & ~tgt) != 8'h00)) d = d & ~tgt;
            step1 = cur;
            hit = 1'b0;
            for (i = 0; i < 8; i++) begin
                b = wk ? weak_bit(i) : (lsb ? i : 7 - i);
                if (!hit && d[b]) begin step1[b] = tgt[b]; hit = 1'b1; end
            end
        end
    endfunction
    always_ff @(posedge clk4x or negedge reset_n) begin
        if (!reset_n) begin
            p1_s1 <= 1'b1; p1_s2 <= 1'b1; p1_sh <= 4'hF; p1_f <= 1'b1; p1_fd <= 1'b1;
            c4 <= 8'hFF; c1_4 <= 8'hFF; armed4 <= 1'b0; open4 <= 1'b0; close4 <= 1'b0;
            p0_seen4 <= 1'b0; req4 <= 1'b0; drive_now4 <= 1'b0;
            dat4 <= 8'h00; st4 <= S_IDLE; bus_s1 <= 8'h00; bus_s2 <= 8'h00; stp_cnt <= 4'd0;
            hf_cnt <= 5'd0;
            cur_pd <= 8'h00; nxt_pd <= 8'h00; need_step <= 1'b0;
            pd_r <= 8'h00; pt_r <= 8'hFF; pdir_r <= 1'b1;
            pin_d <= 8'h00; pin_t <= 8'hFF; pin_dir <= 1'b1;
            pd2_r <= 8'h00; pt2_r <= 8'hFF;
        end else begin
            // The IOB flops copy fabric registers every clock: no logic or enable
            // in front of them (216 MHz timing across the I/O bank), two clk4x
            // periods of added latency on every pin change.
            pd2_r   <= od4 ? 8'h00 : pd_r;
            pt2_r   <= od4 ? (pt_r | pd_r) : pt_r;
            pin_d   <= pd2_r;
            pin_t   <= pt2_r;
            pin_dir <= pdir_r;
            p1_s1 <= a2_phi1;
            p1_s2 <= p1_s1;
            p1_sh <= {p1_sh[2:0], p1_s2};
            if (p1_sh == 4'hF) p1_f <= 1'b1;
            else if (p1_sh == 4'h0) p1_f <= 1'b0;
            p1_fd <= p1_f;
            if (p1_fd && !p1_f) begin               // PHI1 fell: PHI0 rose
                c4 <= 8'd0;
                armed4 <= 1'b1;
            end else begin
                if (c4 != 8'hFF) c4 <= c4 + 8'd1;
                if (!p1_fd && p1_f) armed4 <= 1'b0; // PHI1 rose
            end
            if (!p1_fd && p1_f) c1_4 <= 8'd0;
            else if (c1_4 != 8'hFF) c1_4 <= c1_4 + 8'd1;
            req4 <= drive_q;
            dat4 <= data_out_q;
            if (!req4) begin
                open4 <= 1'b0;
                close4 <= 1'b0;
                p0_seen4 <= 1'b0;
            end else begin
                if (p1_fd && !p1_f) p0_seen4 <= 1'b1;
                if (early_start4 || (armed4 && (c4 >= fine4))) open4 <= 1'b1;
                // A drive that has been through a PHI0 ends early in the next PHI1.
                if (early_rel4 && p0_seen4 && !armed4 && (c1_4 >= rel_dly4)) close4 <= 1'b1;
            end
            bus_s1 <= core_data_in;   // the bus as U5 receives it (while released)
            bus_s2 <= bus_s1;
            nxt_pd    <= step1(cur_pd, dat4, lsb4, opt6_4, weak1st4);
            need_step <= (cur_pd != dat4);
            if (!soft4) begin
                drive_now4 <= drive4;
                if (!drive4) hf_cnt <= opt6_4 ? ff_len4 : 5'd0;
                else if (hf_cnt != 5'd0) hf_cnt <= hf_cnt - 5'd1;
                pd_r    <= (drive4 && (hf_cnt != 5'd0)) ? 8'hFF : dat4;
                pt_r    <= {8{~drive4}};
                pdir_r <= ~drive4;
                st4     <= drive4 ? S_DRIVE : S_IDLE;
            end else begin
                case (st4)
                    S_IDLE: if (drive4) begin
                        pdir_r <= 1'b0;
                        pd_r <= bus_s2;
                        cur_pd <= bus_s2;
                        drive_now4 <= 1'b1;
                        st4 <= S_DIR;
                    end
                    S_DIR: if (!drive4) begin
                        pdir_r <= 1'b1;
                        drive_now4 <= 1'b0;
                        st4 <= S_IDLE;
                    end else begin
                        pt_r <= 8'h00;
                        stp_cnt <= 4'd0;
                        st4 <= S_DRIVE;
                    end
                    S_DRIVE: if (!drive4) begin
                        pt_r <= 8'hFF;
                        st4 <= S_REL;
                    end else if (stp_cnt != 4'd0) begin
                        stp_cnt <= stp_cnt - 4'd1;
                    end else if (need_step) begin
                        pd_r <= nxt_pd;
                        cur_pd <= nxt_pd;
                        stp_cnt <= stp_eff4;
                    end
                    default: begin              // S_REL
                        pt_r <= 8'hFF;
                        pdir_r <= 1'b1;
                        drive_now4 <= 1'b0;
                        st4 <= S_IDLE;
                    end
                endcase
            end
        end
    end

    // B-side of U5 is the Zynq side. DIR=1 means Apple A-side -> Zynq B-side.
    genvar gi;
    for (gi = 0; gi < 8; gi++) begin : g_dpin
        assign a2_data[gi] = pin_t[gi] ? 1'bz : pin_d[gi];
    end

    always_comb begin
        core_data_in  = a2_data;
        a2_data_dir   = pin_dir;
        a2_data_oe_n  = drive_now4 ? 1'b0 : (enabled ? 1'b0 : 1'b1);
        a2_input_oe_n = enabled ? 1'b0 : 1'b1;

        // These outputs drive NPN bases; high means assert the Apple line low.
        a2_irq_assert   = enabled && core_irq_assert;
        a2_nmi_assert   = enabled && core_nmi_assert;
        a2_rdy_assert   = enabled && core_rdy_assert;
        a2_dma_assert   = enabled && core_dma_assert;
        a2_inh_assert   = enabled && core_inh_assert;
        // /RES is the one line that must be controllable before Linux declares
        // host_ready.  This holds the Apple in reset while userspace mounts
        // media and programs the slot map; all other bus drivers remain gated.
        a2_reset_assert = reset_n && clocks_locked && five_ok && core_reset_assert;
    end

    // Present the complete set of signals connected by the original A2N20v2
    // card to the logic core. Q7 inverts /RES, so invert it once here to recover
    // the original active-low Apple bus reset sense.
    always_comb begin
        bus_addr      = a2_addr;
        bus_rw        = a2_rw;
        bus_phi0      = a2_phi0;
        bus_phi1      = a2_phi1;
        bus_7m        = a2_7m;
        bus_q3        = a2_q3;
        bus_sync      = a2_sync;
        bus_iosel_n   = a2_iosel_n;
        bus_iostrb_n  = a2_iostrb_n;
        bus_devsel_n  = a2_devsel_n;
        bus_m2sel     = a2_m2sel;
        bus_m2b0      = a2_m2b0;
        bus_reset_n   = ~a2_reset_asserted_sense;
        bus_rdy_n     = a2_rdy_n_sense;
        bus_dma_n     = a2_dma_n_sense;
        bus_nmi_n     = a2_nmi_n_sense;
        bus_irq_n     = a2_irq_n_sense;
        bus_inh_n     = a2_inh_n_sense;
    end
endmodule
