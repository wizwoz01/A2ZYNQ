// Which slot is the card physically plugged into?
//
// The virtual cards are placed by the slot map and answer by address, so the
// card's own slot does not matter to them. The Apple does drive the card's own
// /IOSEL ($Cn00-$CnFF) and /DEVSEL ($C0n0-$C0nF, n = slot + 8) lines, though,
// and only for that slot: any access that asserts one of them names the slot.
// a2hostd reads the result (reg 0x2E [6:4]) to put the Disk II where the card
// is (the boot menu reads $Cn00/$Cn01 of slots 4-7 and $C0n0 twice of slots
// 1-3 so a slot the boot scan skipped is still seen).
//
// A slot is reported after two detections in a row agree; it is kept across
// Apple resets (the card cannot move while powered) and updated if a later
// pair of detections names another slot. The address is taken inside PHI0,
// when the select is seen: that is the address every card decodes for the
// cycle (the late pass never changes it mid-cycle), whatever the PHI1 timing.
module phys_slot_detect (
    a2bus_if.slave a2bus_if,
    input  wire       iosel_n_i,    // straight from the slot connector (async)
    input  wire       devsel_n_i,
    output reg  [2:0] slot_o        // 0 = not seen yet
);
    reg [1:0] iosel_s, devsel_s;
    always @(posedge a2bus_if.clk_logic) begin
        iosel_s  <= {iosel_s[0], iosel_n_i};
        devsel_s <= {devsel_s[0], devsel_n_i};
    end

    // A select counts when it stays low for 4 clocks (~75 ns) inside PHI0.
    reg [2:0] io_run, dev_run;
    reg       io_hit, dev_hit;
    reg [2:0] hit_slot;
    reg [2:0] cand_r;
    reg       cand_valid_r;

    wire io_page  = (a2bus_if.addr[15:11] == 5'b11000) && (a2bus_if.addr[10:8] != 3'd0);   // $C100-$C7FF
    wire dev_page = (a2bus_if.addr[15:7] == 9'b1100_0000_1) && (a2bus_if.addr[6:4] != 3'd0); // $C090-$C0FF
    wire det      = io_hit || dev_hit;
    wire [2:0] det_slot = hit_slot;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.device_reset_n) begin
            io_run       <= 3'd0;
            dev_run      <= 3'd0;
            io_hit       <= 1'b0;
            dev_hit      <= 1'b0;
            hit_slot     <= 3'd0;
            cand_r       <= 3'd0;
            cand_valid_r <= 1'b0;
            slot_o       <= 3'd0;
        end else if (a2bus_if.phi1_posedge) begin
            // end of the cycle: count its detection (address taken in PHI0)
            if (det) begin
                if (cand_valid_r && (cand_r == det_slot)) slot_o <= det_slot;
                cand_r       <= det_slot;
                cand_valid_r <= 1'b1;
            end
            io_run  <= 3'd0;
            dev_run <= 3'd0;
            io_hit  <= 1'b0;
            dev_hit <= 1'b0;
        end else if (a2bus_if.phi0) begin
            io_run  <= !iosel_s[1]  ? ((io_run  == 3'd7) ? 3'd7 : io_run  + 3'd1) : 3'd0;
            dev_run <= !devsel_s[1] ? ((dev_run == 3'd7) ? 3'd7 : dev_run + 3'd1) : 3'd0;
            if (io_run  >= 3'd4 && !io_hit && !dev_hit && io_page) begin
                io_hit   <= 1'b1;
                hit_slot <= a2bus_if.addr[10:8];
            end
            if (dev_run >= 3'd4 && !io_hit && !dev_hit && dev_page) begin
                dev_hit  <= 1'b1;
                hit_slot <= a2bus_if.addr[6:4];
            end
        end
    end
endmodule
