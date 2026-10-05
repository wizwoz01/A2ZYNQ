// A2N20 Version 2 - Apple II Bus Interface (a2bridge CPLD boards)
//
// (c) 2023,2024,2025,2026 Ed Anuff <ed@a2fpga.com>
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// Interface with the Apple II Bus and sample the address and data lines
// at specific timings per the Apple II bus timing diagram in
// The Apple II Circuit Description.
// Hold the address, data, and control lines until the next sample.
// Provide control strobes that indicate when these values have been
// sampled.
//
// Shared by the a2n20v2-family boards (a2n20v2, a2n20v2-GS, a2n20v2-Enhanced)
// that use the 100-pin a2bridge CPLD.
//
// a2bus_control_if lets an onboard MCU gate startup (ready) and hold the
// Apple II reset line at power-on (reset_hold) until initialization is done.
// Boards without an MCU stub the interface: assign ready = 1'b1 and
// reset_hold = 1'b0, tie inh_n_i high, and set INH_OUT_ENABLE = 0.
//

module apple_bus #(
    parameter bit IRQ_OUT_ENABLE = 1,
    parameter bit INH_OUT_ENABLE = 1,
    parameter bit BUS_DATA_OUT_ENABLE = 1,
    parameter bit ENABLE_DENOISE = 1,
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int APPLE_HZ = 14_318_181,
    parameter int CPU_HZ = APPLE_HZ / 14,                   // 1_022_727
    parameter int CYCLE_COUNT = CLOCK_SPEED_HZ * 14 / APPLE_HZ,     // 52
    parameter int APPLE_14M_CYCLE_COUNT = CLOCK_SPEED_HZ / APPLE_HZ, // 3
    parameter int PHASE_COUNT = CYCLE_COUNT / 2,            // 26
    parameter int READ_COUNT = CYCLE_COUNT / 3,             // 17
    parameter int WRITE_COUNT = CYCLE_COUNT / 5,            // 10
    // Optional late-sample points (Smart-Zynq level-shifter / ribbon skew).
    // Defaults preserve the original READ_COUNT behaviour.
    parameter int ADDR_SAMPLE_COUNT = READ_COUNT,
    parameter int DATA_SAMPLE_COUNT = READ_COUNT,
    // Smart-Zynq early mode (sz_early_i): address pass count in PHI1 for the
    // fast output decode, count in PHI0 for the definitive late pass, and
    // whether early mode is on while the SPI override bit is 0.
    parameter int ADDR_EARLY_COUNT = 15,
    parameter int ADDR_LATE_COUNT = 1,
    parameter bit EARLY_DEFAULT = 1'b0,
    // DIP switch 4 = Apple IIgs mode (M2SEL/M2B0 capture, IIgs soft switches).
    // A board that gives switch 4 another job sets this to 0, which keeps
    // IIgs mode off whatever the switch says.
    parameter bit GS_SWITCH_ENABLE = 1'b1
) (
    input clk_logic_i,
    input clk_pixel_i,
    input system_reset_n_i,
    input device_reset_n_i,
    input a2_phi1_i,
    input a2_q3_i,
    input a2_7M_i,

    a2bus_if.master a2bus_if,
    a2bus_control_if.a2bus a2bus_control_if,

    output reg [2:0] a2_bridge_sel_o,
    output reg a2_bridge_bus_a_oe_n_o,
    output wire a2_bridge_bus_d_oe_n_o,
    output reg a2_bridge_rd_n_o,
    output reg a2_bridge_wr_n_o,
    input [7:0] a2_bridge_d_i,
    output reg [7:0] a2_bridge_d_o,
    output reg a2_bridge_d_oe_o,

    input data_out_en_i,
    input [7:0] data_out_i,

    input irq_n_i,

    input inh_n_i,

    output reg [3:0] dip_switches_n_o,

    output sleep_o,
    output phi_dead_o   // 1 = no PHI edges (~1ms); Smart-Zynq text wipe
`ifdef SMART_ZYNQ
    // Live bus-timing tuning (0 = parameter default) and error counters, so
    // the sample points can be swept on real hardware without a rebuild.
    ,input  [23:0] sz_tune_i        // {write, data, addr} phase counts
    ,input  [3:0]  sz_hold_i        // extra clocks the card keeps driving after PHI0
    ,input         sz_early_i       // flips EARLY_DEFAULT: early = fast-PHI card drive + late address pass
    ,input  [7:0]  sz_release_i     // unused here (reg 0x07 now sets the PHY's fine drive start)
    ,input  [2:0]  sz_probe_sel_i
    ,output reg [31:0] sz_probe_o
    // Direct D0-D7 drive for the PHY (replaces the bridge write/latch path):
    // the byte is the card's data straight from its decode, so the pins carry
    // the right byte from the first clock of the drive, with no stale latch.
    ,output [7:0]  sz_drive_data_o
    ,output        sz_drive_en_o
`endif
);

    // Vivado-friendly explicit interface assignments.
    // Avoid SystemVerilog LHS assignment-pattern synthesis.
    assign a2bus_if.clk_logic      = clk_logic_i;
    assign a2bus_if.clk_pixel      = clk_pixel_i;
    assign a2bus_if.system_reset_n = system_reset_n_i;
    assign a2bus_if.device_reset_n = device_reset_n_i;

    // Cards gate their selects with a2bus_if.phi0. On Smart-Zynq that level is
    // additionally held low until this cycle's address has been committed, so
    // no card can ever decode (and drive the bus for) the previous address.
    wire phi0_raw_w;
`ifdef SMART_ZYNQ
    reg  addr_valid_r = 1'b0;
    // Fast PHI1 view: 2-FF sync plus one agreeing sample, ~3 clocks behind the
    // pin versus ~8 for cdc_denoise. Measured on a IIe, slot data must be on
    // the bus long before PHI0 ends, so early mode opens the card-select window
    // (and updates the output byte) off this edge, the way a real card's ROM
    // answers /IOSEL right after PHI0 rises.
    (* ASYNC_REG = "TRUE" *) reg phi1_s1_r, phi1_s2_r;
    reg phi1_fast_r = 1'b0, phi1_fast_d_r = 1'b0;
    always @(posedge clk_logic_i) begin
        phi1_s1_r <= a2_phi1_i;
        phi1_s2_r <= phi1_s1_r;
        if (phi1_s1_r == phi1_s2_r) phi1_fast_r <= phi1_s2_r;
        phi1_fast_d_r <= phi1_fast_r;
    end
    wire fast_phi0_rise_w = phi1_fast_d_r & ~phi1_fast_r;   // PHI1 pin fell: PHI0 began
    wire fast_edge_w      = phi1_fast_d_r ^ phi1_fast_r;
    reg  early_open_r = 1'b0;
    reg  [7:0] fast_cnt_r;   // clocks since the fast PHI0 edge (early-mode window timing)
    reg  [7:0] fast1_cnt_r;  // clocks since the fast PHI1 edge (early address pass timing)
    wire       fast_phi1_rise_w = ~phi1_fast_d_r & phi1_fast_r;   // PHI1 pin rose
    wire early_en_w = EARLY_DEFAULT ^ sz_early_i;
    // Early mode opens the select window (and so the drive) only off the fast
    // edge + start delay, so the delay knob alone sets when D0-D7 switch; the
    // synced PHI0 takes over only if the fast edge was missed this cycle.
    assign a2bus_if.phi0 = (early_en_w ? (early_open_r | (phi0_raw_w & (fast_cnt_r >= 8'd20)))
                                       : phi0_raw_w) & addr_valid_r;
`else
    assign a2bus_if.phi0 = phi0_raw_w;
`endif

    a2bus_timing #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE_DENOISE(ENABLE_DENOISE)
    ) a2bus_timing_inst(
        .clk_logic_i(clk_logic_i),
        .a2_phi1_i(a2_phi1_i),
        .a2_q3_i(a2_q3_i),
        .a2_7M_i(a2_7M_i),

        .phi0_o(phi0_raw_w),
        .phi0_posedge_o(a2bus_if.phi0_posedge),
        .phi0_negedge_o(a2bus_if.phi0_negedge),
        
        .phi1_o(a2bus_if.phi1),
        .phi1_posedge_o(a2bus_if.phi1_posedge),
        .phi1_negedge_o(a2bus_if.phi1_negedge),
        
        .q3_o(a2bus_if.clk_q3),
        .q3_posedge_o(a2bus_if.clk_q3_posedge),
        .q3_negedge_o(a2bus_if.clk_q3_negedge),
        
        .clk_7M_o(a2bus_if.clk_7M),
        .clk_7M_posedge_o(a2bus_if.clk_7M_posedge),
        .clk_7M_negedge_o(a2bus_if.clk_7M_negedge),
        
        .clk_14M_posedge_o(a2bus_if.clk_14M_posedge)
    );

    // data and address latches on input
    reg [15:0] addr_r;
    reg [7:0] data_r;
    reg rw_n_r;
    reg m2sel_n_r;
    reg m2b0_r;

    reg [7:0] control_in_r;
    reg [7:0] control_out_r;
    reg [7:0] prev_control_out_r;

    always @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.device_reset_n) begin
            control_out_r <= 8'hFF;
        end else begin
            control_out_r[1] <=  inh_n_i || !INH_OUT_ENABLE;
            control_out_r[2] <=  irq_n_i || !IRQ_OUT_ENABLE;
            // Hold the Apple II in RESET (open-collector, active low) while
            // the connector asks for it (power-on storage bring-up); see
            // a2bus_control_if.reset_hold. Pushed to the bridge on change.
            control_out_r[6] <= !a2bus_control_if.reset_hold;
        end
    end

    assign a2bus_if.control_inh_n = control_in_r[1];
    assign a2bus_if.control_irq_n = control_in_r[2];
    assign a2bus_if.control_rdy_n = control_in_r[3];
    assign a2bus_if.control_dma_n = control_in_r[4];
    assign a2bus_if.control_nmi_n = control_in_r[5];
    assign a2bus_if.control_reset_n = control_in_r[6];

    wire sw_gs_w = GS_SWITCH_ENABLE && !dip_switches_n_o[3];
    assign a2bus_if.sw_gs = sw_gs_w;

    assign a2bus_if.addr = addr_r;
    assign a2bus_if.m2sel_n = sw_gs_w ? m2sel_n_r : 0; 
    assign a2bus_if.m2b0 = sw_gs_w ? m2b0_r : 0; 
    //assign a2bus_if.m2b0 = 0; 
    assign a2bus_if.data = data_r;
    assign a2bus_if.rw_n = rw_n_r;

    reg [5:0] phase_cycles_r = 0;
    assign sleep_o = phase_cycles_r == 6'b111111;

`ifdef SMART_ZYNQ
    // If PHI1 stops (Apple power-cycle), the mux FSM can freeze mid-beat and
    // never capture again. ~1 ms with no PHI edge → park IDLE; resumes when
    // PHI returns. Independent of slot-5V sense.
    localparam int PHI_DEAD_CYCLES = CLOCK_SPEED_HZ / 1000;
    reg [16:0] phi_dead_cnt_r;
    wire phi_dead_w = (phi_dead_cnt_r >= 17'(PHI_DEAD_CYCLES));
    assign phi_dead_o = phi_dead_w;
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.device_reset_n)
            phi_dead_cnt_r <= 17'd0;
        else if (a2bus_if.phi1_posedge || a2bus_if.phi1_negedge)
            phi_dead_cnt_r <= 17'd0;
        else if (!phi_dead_w)
            phi_dead_cnt_r <= phi_dead_cnt_r + 17'd1;
    end
`else
    assign phi_dead_o = 1'b0;
`endif

    always @(posedge a2bus_if.clk_logic) begin

        // capture phase transtitions and count cycles
        if (a2bus_if.phi1_posedge || a2bus_if.phi1_negedge) begin
            phase_cycles_r <= 6'b0;
        end else if (phase_cycles_r != 6'b111111) begin
            phase_cycles_r <= phase_cycles_r + 1'b1;
        end

    end

    reg [6:0] cycle_timer_r = 0;
    reg extended_cycle_r = 0;
    assign a2bus_if.extended_cycle = extended_cycle_r;
    always @(posedge a2bus_if.clk_logic) begin
        extended_cycle_r <= 0;
        cycle_timer_r <= cycle_timer_r + 1'b1;
        // capture cycle transitions and count cycles
        if (a2bus_if.phi1_posedge) begin
            cycle_timer_r <= 7'b0;
            // check if last cycle was extended duration
            if (cycle_timer_r >= (CYCLE_COUNT + APPLE_14M_CYCLE_COUNT)) begin
                extended_cycle_r <= 1'b1;
            end
        end

    end

    reg data_in_strobe_r;

    localparam [2:0] IO_INIT = 3'd0;
    localparam [2:0] IO_IDLE = 3'd1;
    localparam [2:0] IO_READ_ADDR = 3'd2;
    localparam [2:0] IO_WRITE_ADDR = 3'd3;
    localparam [2:0] IO_READ_DATA = 3'd4;
    localparam [2:0] IO_WRITE_DATA = 3'd5;
    localparam [2:0] IO_READ_GPIO = 3'd6;
    localparam [2:0] IO_WRITE_GPIO = 3'd7;

    reg [2:0] io_state = IO_INIT;
    reg [2:0] next_io_state = IO_IDLE;
    wire io_state_pending = (next_io_state != IO_IDLE);
`ifdef SMART_ZYNQ
    reg [3:0] io_cycle = 0;  // longer mux-settle sequence needs >7 steps
`else
    reg [2:0] io_cycle = 0;
`endif

    reg [15:0] next_addr_r;
`ifdef SMART_ZYNQ
    reg [7:0] samp_byte_r;
    reg       addr_stable_r;
    reg [7:0] samp_al_r, samp_ah_r, samp_ct_r;
    // One request of each kind per phase, raised at "count >= N" rather than
    // "== N" so a busy state machine delays a sample instead of dropping it.
    reg       addr_req_done_r, write_done_r, read_done_r;
    reg       late_done_r, late_pass_r, late_rw_r;
    reg       retry_done_r;   // early pass already re-sampled once this cycle
    // 0x0C = {PHY bit order, address count[6:0]}
    wire [7:0] addr_n_w  = (sz_tune_i[6:0]   != 7'd0) ? {1'b0, sz_tune_i[6:0]} :
                           (early_en_w ? 8'(ADDR_EARLY_COUNT) : 8'(ADDR_SAMPLE_COUNT));
    // 0x0D = {late-pass disable, PHY soft landing, PHY high first, data count[4:0]};
    // 0x0E = {select-window delay[3:0], open window at the early commit, late-pass count[2:0]}
    wire [7:0] data_n_w  = (sz_tune_i[12:8]  != 5'd0) ? {3'b000, sz_tune_i[12:8]} : 8'(DATA_SAMPLE_COUNT);
    wire       late_dis_w = sz_tune_i[15];
    wire [7:0] late_n_w  = (sz_tune_i[18:16] != 3'd0) ? {5'b00000, sz_tune_i[18:16]} : 8'(ADDR_LATE_COUNT);
    wire       at_commit_w = sz_tune_i[19];
    wire [7:0] start_dly_w = {4'b0000, sz_tune_i[23:20]};
    wire [7:0] write_n_w = 8'(WRITE_COUNT);
    wire [7:0] phase_n_w = {2'b00, phase_cycles_r};
    reg [31:0] cnt_cycles_r, cnt_addr_bad_r, cnt_data_bad_r, cnt_strobe_r;
    reg [31:0] cnt_fast_edges_r, cnt_lag_long_r, cnt_addr_fix_r;
    reg [7:0]  lag_cnt_r, lag_max_r, lag_min_r;
    reg        lag_run_r;
    always @(posedge a2bus_if.clk_logic) begin
        case (sz_probe_sel_i)
            3'd0: sz_probe_o <= cnt_cycles_r;
            3'd1: sz_probe_o <= cnt_addr_bad_r;
            3'd2: sz_probe_o <= cnt_data_bad_r;
            3'd3: sz_probe_o <= cnt_strobe_r;
            3'd4: sz_probe_o <= {start_dly_w[3:0], at_commit_w, late_n_w[2:0], data_n_w, addr_n_w, sz_hold_i, early_en_w, 3'b110};
            3'd5: sz_probe_o <= cnt_fast_edges_r;
            3'd6: sz_probe_o <= cnt_addr_fix_r;   // late pass disagreed with the early address
            default: sz_probe_o <= {8'd0, lag_max_r, lag_min_r, 8'h5A};
        endcase
    end

    // How late does the cdc_denoise edge land after the fast edge? A clean PHI
    // gives a constant ~5 clocks; ringing makes the 3-sample filter lock late,
    // which shifts every sample/drive point of that phase.
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.device_reset_n) begin
            cnt_fast_edges_r <= 32'd0; cnt_lag_long_r <= 32'd0;
            lag_cnt_r <= 8'd0; lag_max_r <= 8'd0; lag_min_r <= 8'hFF; lag_run_r <= 1'b0;
            fast_cnt_r <= 8'hFF;
            fast1_cnt_r <= 8'hFF;
        end else begin
            if (fast_phi0_rise_w) fast_cnt_r <= 8'd0;
            else if (fast_cnt_r != 8'hFF) fast_cnt_r <= fast_cnt_r + 8'd1;
            if (fast_phi1_rise_w) fast1_cnt_r <= 8'd0;
            else if (fast1_cnt_r != 8'hFF) fast1_cnt_r <= fast1_cnt_r + 8'd1;
            if (fast_edge_w) begin
                cnt_fast_edges_r <= cnt_fast_edges_r + 32'd1;
                lag_run_r <= 1'b1;
                lag_cnt_r <= 8'd0;
            end else if (lag_run_r) begin
                if (a2bus_if.phi1_posedge | a2bus_if.phi1_negedge) begin
                    lag_run_r <= 1'b0;
                    if (lag_cnt_r > 8'd6) cnt_lag_long_r <= cnt_lag_long_r + 32'd1;
                    if (lag_cnt_r > lag_max_r) lag_max_r <= lag_cnt_r;
                    if (lag_cnt_r < lag_min_r) lag_min_r <= lag_cnt_r;
                end else if (lag_cnt_r != 8'hFF) begin
                    lag_cnt_r <= lag_cnt_r + 8'd1;
                end
            end
        end
    end
`endif

    always @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.device_reset_n) begin
            data_in_strobe_r <= 1'b0;

            a2_bridge_sel_o <= 3'b00;
            a2_bridge_bus_a_oe_n_o <= 1'b1;
            a2_bridge_rd_n_o <= 1'b1;
            a2_bridge_wr_n_o <= 1'b1;
            a2_bridge_d_o <= 8'b0;
            a2_bridge_d_oe_o <= 1'b0;

            control_in_r <= 8'hFF;
            prev_control_out_r <= 8'hFF;

            io_cycle <= 0;
`ifdef SMART_ZYNQ
            samp_byte_r <= 8'h00;
            addr_stable_r <= 1'b0;
            addr_valid_r <= 1'b0;
            early_open_r <= 1'b0;
            addr_req_done_r <= 1'b0;
            late_done_r <= 1'b0;
            late_pass_r <= 1'b0;
            retry_done_r <= 1'b0;
            cnt_addr_fix_r <= 32'd0;
            write_done_r <= 1'b0;
            read_done_r <= 1'b0;
            cnt_cycles_r <= 32'd0;
            cnt_addr_bad_r <= 32'd0;
            cnt_data_bad_r <= 32'd0;
            cnt_strobe_r <= 32'd0;
`endif

            io_state = IO_INIT;
            next_io_state = IO_IDLE;
`ifdef SMART_ZYNQ
        end else if (phi_dead_w && (io_state != IO_INIT)) begin
            // PHI stopped mid-transaction (Apple power loss). Re-arm for the
            // next power-on without depending on slot-5V sense polarity.
            data_in_strobe_r <= 1'b0;
            a2_bridge_sel_o <= 3'd0;
            a2_bridge_rd_n_o <= 1'b0;
            a2_bridge_wr_n_o <= 1'b1;
            a2_bridge_d_oe_o <= 1'b0;
            io_cycle <= 0;
            addr_stable_r <= 1'b0;
            addr_valid_r <= 1'b0;
            early_open_r <= 1'b0;
            io_state <= IO_IDLE;
            next_io_state <= IO_IDLE;
`endif
        end else begin
            data_in_strobe_r <= 1'b0;

`ifdef SMART_ZYNQ
            // New phase: re-arm its requests. The synced PHI1 rise also ends
            // this cycle's card-select window (phi0 falls with it).
            if (a2bus_if.phi1_posedge) begin
                addr_req_done_r <= 1'b0;
                addr_valid_r <= 1'b0;
                early_open_r <= 1'b0;
            end
            if (fast_phi1_rise_w) begin
                addr_req_done_r <= 1'b0;
                retry_done_r <= 1'b0;
            end
            // With at_commit_w the cards see their select from the early commit
            // (late PHI1), so the byte is ready before PHI0; the PHY still
            // holds the pins off until its fine delay after the PHI0 rise.
            if (early_en_w && (at_commit_w || ((fast_cnt_r >= start_dly_w) && (fast_cnt_r < 8'd20))))
                early_open_r <= 1'b1;
            if (early_en_w ? fast_phi0_rise_w : a2bus_if.phi0_posedge) write_done_r <= 1'b0;
            if (a2bus_if.phi0_posedge) begin
                read_done_r <= 1'b0;
                late_done_r <= 1'b0;
            end

            if ((io_state != IO_INIT) && !io_state_pending) begin
                // No IO_WRITE_DATA here: D0-D7 are driven straight from the
                // card data (sz_drive_data_o), not through the bridge latch.
                // Early mode times its address pass from the fast PHI1 edge (the
                // cdc_denoise edge wanders 1-8 clocks, which put the sample
                // anywhere from ~324 to ~454 ns after PHI1 - early enough to
                // catch this IIe's address still settling).
                if (!addr_req_done_r &&
                    (early_en_w ? ((fast1_cnt_r >= addr_n_w) && (fast1_cnt_r < 8'd44))
                                : (a2bus_if.phi1 && (phase_n_w >= addr_n_w)))) begin
                    next_io_state <= IO_READ_ADDR;
                    addr_req_done_r <= 1'b1;
                    late_pass_r <= 1'b0;
                end else if (early_en_w && !late_dis_w && phi0_raw_w && addr_valid_r && !late_done_r &&
                             (phase_n_w >= late_n_w)) begin
                    // Late pass: re-read the address inside PHI0, where it is
                    // settled. It becomes addr_r / addr_stable_r for the data
                    // strobe (soft switches, video), and corrects the card's
                    // byte if the early PHI1 sample was wrong.
                    next_io_state <= IO_READ_ADDR;
                    late_done_r <= 1'b1;
                    late_pass_r <= 1'b1;
                end else if (phi0_raw_w && !read_done_r && (phase_n_w >= data_n_w)) begin
                    next_io_state <= IO_READ_DATA;
                    read_done_r <= 1'b1;
                end else if (control_out_r != prev_control_out_r) begin
                    next_io_state <= IO_WRITE_GPIO;
                    prev_control_out_r <= control_out_r;
                end
            end
`else
            if (io_state != IO_INIT) begin
                if (a2bus_if.phi1 && (phase_cycles_r == ADDR_SAMPLE_COUNT)) begin
                    next_io_state <= IO_READ_ADDR;
                end else if (a2bus_if.phi0 && (phase_cycles_r == WRITE_COUNT) && data_out_en_i) begin
                    next_io_state <= IO_WRITE_DATA;
                end else if (a2bus_if.phi0 && (phase_cycles_r == DATA_SAMPLE_COUNT)) begin
                    next_io_state <= IO_READ_DATA;
                end else if (!io_state_pending && (control_out_r != prev_control_out_r)) begin
                    next_io_state <= IO_WRITE_GPIO;
                    prev_control_out_r <= control_out_r;
                end
            end
`endif

            case (io_state) 
                IO_INIT : begin
                    if (a2bus_control_if.ready) begin
                        io_cycle <= io_cycle + 1'b1;
                        if (io_cycle == 3'd0) begin
                            a2_bridge_sel_o <= 3'd0;
                            a2_bridge_rd_n_o <= 1'b1;
                            a2_bridge_wr_n_o <= 1'b1;
                            a2_bridge_d_o <= 8'b11111111;
                            a2_bridge_d_oe_o <= 1'b1;
                        end else if (io_cycle == 3'd1) begin
                            a2_bridge_sel_o <= 3'd0;
                            a2_bridge_rd_n_o <= 1'b1;
                            a2_bridge_wr_n_o <= 1'b0;
                            a2_bridge_d_oe_o <= 1'b1;
                        end else if (io_cycle == 3'd2) begin
                            a2_bridge_sel_o <= 3'd5;
                            a2_bridge_rd_n_o <= 1'b0;
                            a2_bridge_wr_n_o <= 1'b1;
                            a2_bridge_d_oe_o <= 1'b0;
                        end else if (io_cycle == 3'd3) begin
                            dip_switches_n_o <= a2_bridge_d_i[3:0];
                            a2_bridge_sel_o <= 3'd0;
                            a2_bridge_rd_n_o <= 1'b1;
                            a2_bridge_wr_n_o <= 1'b1;
                            a2_bridge_d_oe_o <= 1'b0;
                            io_state <= IO_IDLE;
                            next_io_state <= IO_IDLE;
                        end  
                    end
                end
                IO_IDLE : begin
                    io_cycle <= 0;

                    // Sample control lines on idle
                    if ((a2_bridge_sel_o == 3'b00) && a2_bridge_rd_n_o) control_in_r <= a2_bridge_d_i;
                    a2_bridge_sel_o <= 3'd0;
                    a2_bridge_rd_n_o <= 1'b0;
                    a2_bridge_wr_n_o <= 1'b1;

                    // Move to next state if requested
                    if (io_state_pending) begin
                        io_state <= next_io_state;
                        next_io_state <= IO_IDLE;
                    end
                end
                IO_READ_ADDR : begin
                    io_cycle <= io_cycle + 1'b1;
`ifdef SMART_ZYNQ
                    // The bridge mux is fabric logic over directly wired pins,
                    // so a byte is valid the clock after its select. Sample
                    // AL, AH and R/W, then all three again; any mismatch clears
                    // addr_stable_r so IO_READ_DATA will not strobe. The later
                    // sample is the one committed (the NMOS 6502 on a loaded
                    // slot bus is still settling ~430 ns after PHI1). With the
                    // 8-clock cdc_denoise lag, io_cycle k runs at PHI1 pin edge
                    // + (11 + ADDR_SAMPLE_COUNT + k) clocks. addr_valid_r keeps
                    // card selects closed until the commit, whatever the count.
                    case (io_cycle)
                        4'd0: begin
                            a2_bridge_sel_o <= 3'd2;
                            a2_bridge_rd_n_o <= 1'b0;
                            addr_stable_r <= 1'b1;
                        end
                        4'd1: begin samp_al_r <= a2_bridge_d_i; a2_bridge_sel_o <= 3'd3; end
                        4'd2: begin samp_ah_r <= a2_bridge_d_i; a2_bridge_sel_o <= 3'd0; end
                        4'd3: begin samp_ct_r <= a2_bridge_d_i; a2_bridge_sel_o <= 3'd2; end
                        4'd4: begin
                            if (a2_bridge_d_i != samp_al_r) addr_stable_r <= 1'b0;
                            next_addr_r[7:0] <= a2_bridge_d_i;
                            a2_bridge_sel_o <= 3'd3;
                        end
                        4'd5: begin
                            if (a2_bridge_d_i != samp_ah_r) addr_stable_r <= 1'b0;
                            next_addr_r[15:8] <= a2_bridge_d_i;
                            a2_bridge_sel_o <= 3'd0;
                        end
                        4'd6: begin
                            if (a2_bridge_d_i[0] != samp_ct_r[0]) addr_stable_r <= 1'b0;
                            if (late_pass_r) late_rw_r <= a2_bridge_d_i[0];
                            else             rw_n_r    <= a2_bridge_d_i[0];
                            a2_bridge_sel_o <= 3'd4;
                        end
                        default: begin
                            if (late_pass_r) begin
                                // Late pass validates only. It samples while the
                                // card is driving D0-D7, which disturbs the input
                                // lines on this card, so it never changes what
                                // the cards decode mid-cycle (a flipped R/W here
                                // dropped the drive and read back as $83). A
                                // disagreement just withholds the data strobe.
                                if ((next_addr_r != addr_r) || (late_rw_r != rw_n_r)) begin
                                    addr_stable_r <= 1'b0;
                                    cnt_addr_fix_r <= cnt_addr_fix_r + 32'd1;
                                end
                                if (!addr_stable_r) cnt_addr_bad_r <= cnt_addr_bad_r + 32'd1;
                            end else if (early_en_w && !addr_stable_r && !retry_done_r) begin
                                // The two samples disagreed: the address was still
                                // moving. Sample once more instead of committing it.
                                retry_done_r <= 1'b1;
                                addr_req_done_r <= 1'b0;
                                cnt_addr_bad_r <= cnt_addr_bad_r + 32'd1;
                            end else begin
                                // Always commit: a skipped update would leave the
                                // previous cycle's address decoded for this one.
                                addr_r <= next_addr_r;
                                m2b0_r <= a2_bridge_d_i[0];
                                m2sel_n_r <= a2_bridge_d_i[1];
                                addr_valid_r <= 1'b1;
                                cnt_cycles_r <= cnt_cycles_r + 32'd1;
                                if (!addr_stable_r && !early_en_w) cnt_addr_bad_r <= cnt_addr_bad_r + 32'd1;
                            end
                            a2_bridge_rd_n_o <= 1'b1;
                            io_state <= IO_IDLE;
                        end
                    endcase
`else
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd2;
                        a2_bridge_rd_n_o <= 1'b0;
                    end else if (io_cycle == 3'd1) begin
                        next_addr_r[7:0] <= a2_bridge_d_i;
                        a2_bridge_sel_o <= 3'd3;
                    end else if (io_cycle == 3'd2) begin
                        next_addr_r[15:8] <= a2_bridge_d_i;
                        a2_bridge_sel_o <= 3'd0;
                    end else if (io_cycle == 3'd3) begin
                        rw_n_r <= a2_bridge_d_i[0];
                        a2_bridge_sel_o <= 3'd4;
                    end else if (io_cycle == 3'd4) begin
                        // update all address-related lines on the same cycle
                        addr_r <= next_addr_r;
                        m2b0_r <= a2_bridge_d_i[0];
                        m2sel_n_r <= a2_bridge_d_i[1];
                        a2_bridge_rd_n_o <= 1'b1;
                        io_state <= IO_IDLE;
                    end
`endif
                end
                IO_READ_DATA : begin
                    io_cycle <= io_cycle + 1'b1;
`ifdef SMART_ZYNQ
                    // Dual-sample data; only strobe if address was stable and
                    // both data samples match. Samples land at PHI0 pin edge +
                    // (13/14 + DATA_SAMPLE_COUNT) clocks; they must stay inside
                    // the CPU's write-data window (its clock lags slot PHI0).
                    if (io_cycle == 4'd0) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b0;
                    end else if (io_cycle == 4'd2) begin
                        samp_byte_r <= a2_bridge_d_i;
                    end else if (io_cycle == 4'd3) begin
                        if (a2_bridge_d_i != samp_byte_r)
                            cnt_data_bad_r <= cnt_data_bad_r + 32'd1;
                        if (addr_stable_r && (a2_bridge_d_i == samp_byte_r) &&
                            !a2bus_if.m2sel_n) begin
                            data_r <= samp_byte_r;
                            data_in_strobe_r <= 1'b1;
                            cnt_strobe_r <= cnt_strobe_r + 32'd1;
                        end
                        a2_bridge_sel_o <= 2'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        io_state <= IO_IDLE;
                    end
`else
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b0;
                    end else if (io_cycle == 3'd1) begin
                        data_r <= a2_bridge_d_i;
                        data_in_strobe_r <= !a2bus_if.m2sel_n;
                        a2_bridge_sel_o <= 2'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        io_state <= IO_IDLE;
                    end
`endif
                end
                IO_WRITE_DATA : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_o <= data_out_i;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd1) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b0;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd2) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                        io_state <= IO_IDLE;
                    end  
                end
                IO_WRITE_GPIO : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_o <= control_out_r;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd1) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b0;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd2) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                        io_state <= IO_IDLE;
                    end  
                end
            endcase
        end

    end

`ifdef SMART_ZYNQ
    // Keep driving the latched byte sz_hold_i clocks past the end of the
    // select window, so the 6502 (whose latch edge trails slot PHI0) still
    // sees it held. 15 clocks is ~280 ns, well short of the next PHI0.
    reg [3:0] drive_hold_r;
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.device_reset_n)  drive_hold_r <= 4'd0;
        else if (data_out_en_i)        drive_hold_r <= sz_hold_i;
        else if (drive_hold_r != 4'd0) drive_hold_r <= drive_hold_r - 4'd1;
    end
    assign a2_bridge_bus_d_oe_n_o = ~((data_out_en_i | (drive_hold_r != 4'd0)) & BUS_DATA_OUT_ENABLE);

    // The byte follows the card's data while it is selected (a Disk II nibble
    // that lands mid-cycle goes straight out) and holds through drive_hold_r.
    reg [7:0] drive_byte_r;
    always @(posedge a2bus_if.clk_logic) if (data_out_en_i) drive_byte_r <= data_out_i;
    assign sz_drive_data_o = data_out_en_i ? data_out_i : drive_byte_r;
    assign sz_drive_en_o   = ~a2_bridge_bus_d_oe_n_o;
`else
    assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE);
`endif

    assign a2bus_if.data_in_strobe = data_in_strobe_r;


endmodule
