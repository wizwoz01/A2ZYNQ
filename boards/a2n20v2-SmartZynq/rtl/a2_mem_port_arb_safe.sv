`timescale 1ns/1ps

// Smart-Zynq memory-port arbiter.
//
// A2FPGA clients pulse rd/wr and then wait for ready.  Each client gets one
// private pending slot; simultaneous requests are preserved and serviced with
// the same fixed priority used by the original SDRAM controller (lowest index
// wins).  Only the selected pending request is cleared on grant.
module a2_mem_port_arb_safe #(
    parameter integer NUM_CLIENTS = 2,
    parameter integer PORT_ADDR_WIDTH = 21,
    parameter integer DATA_WIDTH = 32,
    parameter integer DQM_WIDTH = 4,
    parameter integer PORT_OUTPUT_WIDTH = 32,
    parameter logic [PORT_ADDR_WIDTH-1:0] CLIENT_BASE_ADDR [NUM_CLIENTS] = '{NUM_CLIENTS{0}}
) (
    input  logic clk_i,
    input  logic rst_n_i,
    mem_port_if.controller clients[NUM_CLIENTS-1:0],
    mem_port_if.client controller
);
    localparam integer OWNER_W = (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS);

    logic                       pend_rd_r    [NUM_CLIENTS-1:0];
    logic                       pend_wr_r    [NUM_CLIENTS-1:0];
    logic                       pend_burst_r [NUM_CLIENTS-1:0];
    logic [PORT_ADDR_WIDTH-1:0] pend_addr_r  [NUM_CLIENTS-1:0];
    logic [DATA_WIDTH-1:0]      pend_data_r  [NUM_CLIENTS-1:0];
    logic [DQM_WIDTH-1:0]       pend_be_r    [NUM_CLIENTS-1:0];

    wire                        req_rd_w      [NUM_CLIENTS-1:0];
    wire                        req_wr_w      [NUM_CLIENTS-1:0];
    wire                        cl_burst_w    [NUM_CLIENTS-1:0];
    wire [PORT_ADDR_WIDTH-1:0] cl_addr_w     [NUM_CLIENTS-1:0];
    wire [DATA_WIDTH-1:0]      cl_data_w     [NUM_CLIENTS-1:0];
    wire [DQM_WIDTH-1:0]       cl_be_w       [NUM_CLIENTS-1:0];

    logic busy_r;
    logic req_r;
    logic req_is_wr_r;
    logic [OWNER_W-1:0] owner_r;
    logic [PORT_ADDR_WIDTH-1:0] addr_r;
    logic [DATA_WIDTH-1:0] data_r;
    logic [DQM_WIDTH-1:0] be_r;
    logic burst_r;

    logic grant_valid;
    logic [OWNER_W-1:0] grant_idx;
    integer gi;
    always_comb begin
        grant_valid = 1'b0;
        grant_idx   = '0;
        // Descend so the final assignment is the lowest numbered pending
        // client, matching the original fixed-priority memory policy.
        for (gi = NUM_CLIENTS-1; gi >= 0; gi = gi-1) begin
            if (pend_rd_r[gi] || pend_wr_r[gi]) begin
                grant_valid = 1'b1;
                grant_idx   = OWNER_W'(gi);
            end
        end
    end

    generate
        for (genvar g = 0; g < NUM_CLIENTS; g++) begin : g_client_io
            assign req_rd_w[g]   = clients[g].rd;
            assign req_wr_w[g]   = clients[g].wr;
            assign cl_burst_w[g] = clients[g].burst;
            assign cl_addr_w[g]  = clients[g].addr;
            assign cl_data_w[g]  = clients[g].data;
            assign cl_be_w[g]    = clients[g].byte_en;

            assign clients[g].available = controller.available && !busy_r;
            assign clients[g].ready = controller.ready && busy_r &&
                                      (owner_r == OWNER_W'(g));
        end
    endgenerate

    // q must be private per client.  Some clients consume q well after ready;
    // a shared q would let another client's completion overwrite the word.
    logic [PORT_OUTPUT_WIDTH-1:0] client_q_r [NUM_CLIENTS-1:0];
    generate
        for (genvar q = 0; q < NUM_CLIENTS; q++) begin : g_client_q
            wire own_read_done = controller.ready && busy_r && !req_is_wr_r &&
                                 (owner_r == OWNER_W'(q));
            always_ff @(posedge clk_i) begin
                if (!rst_n_i)
                    client_q_r[q] <= '0;
                else if (own_read_done)
                    client_q_r[q] <= controller.q;
            end
            assign clients[q].q = own_read_done ? controller.q : client_q_r[q];
        end
    endgenerate

    integer i;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (i = 0; i < NUM_CLIENTS; i = i+1) begin
                pend_rd_r[i]    <= 1'b0;
                pend_wr_r[i]    <= 1'b0;
                pend_burst_r[i] <= 1'b0;
                pend_addr_r[i]  <= '0;
                pend_data_r[i]  <= '0;
                pend_be_r[i]    <= '0;
            end
            busy_r      <= 1'b0;
            req_r       <= 1'b0;
            req_is_wr_r <= 1'b0;
            owner_r     <= '0;
            addr_r      <= '0;
            data_r      <= '0;
            be_r        <= '0;
            burst_r     <= 1'b0;
        end else begin
            // Capture request pulses independently.  Since available is low
            // while a transaction is active, a client cannot overflow its one
            // pending slot while waiting for completion.
            for (i = 0; i < NUM_CLIENTS; i = i+1) begin
                if (req_rd_w[i] || req_wr_w[i]) begin
                    pend_rd_r[i]    <= req_rd_w[i];
                    pend_wr_r[i]    <= req_wr_w[i];
                    pend_burst_r[i] <= cl_burst_w[i];
                    pend_addr_r[i]  <= cl_addr_w[i];
                    pend_data_r[i]  <= cl_data_w[i];
                    pend_be_r[i]    <= cl_be_w[i];
                end
            end

            if (busy_r) begin
                if (controller.ready) begin
                    busy_r <= 1'b0;
                    req_r  <= 1'b0; // one dead cycle gives downstream a clean request edge
                end
            end else if (!req_r && grant_valid) begin
                busy_r      <= 1'b1;
                req_r       <= 1'b1;
                req_is_wr_r <= pend_wr_r[grant_idx];
                owner_r     <= grant_idx;
                addr_r      <= CLIENT_BASE_ADDR[grant_idx] + pend_addr_r[grant_idx];
                data_r      <= pend_data_r[grant_idx];
                be_r        <= pend_be_r[grant_idx];
                burst_r     <= pend_burst_r[grant_idx];
                // Critical correctness property: clear ONLY the selected
                // request. Other simultaneous requests remain queued.
                pend_rd_r[grant_idx] <= 1'b0;
                pend_wr_r[grant_idx] <= 1'b0;
            end
        end
    end

    assign controller.rd      = req_r && !req_is_wr_r;
    assign controller.wr      = req_r && req_is_wr_r;
    assign controller.addr    = addr_r;
    assign controller.data    = data_r;
    assign controller.byte_en = be_r;
    assign controller.burst   = burst_r;
endmodule
