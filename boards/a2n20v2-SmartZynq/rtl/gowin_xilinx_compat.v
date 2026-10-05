`timescale 1ns/1ps

// Compatibility implementation for the Gowin ELVDS_TBUF primitive used
// by the original A2N20v2 Enhanced HDMI output.
//
// 7-series OSERDESE2 OQ cannot feed an OBUFTDS unless the buffer T pin is the
// serializer TQ pin (Place 30-608). HDMI TMDS is always driven on this port
// (HDMI_SLEEP_ENABLE defaults to 0), so use a non-tristate OBUFDS.
module ELVDS_TBUF (
    input  wire I,
    input  wire OEN,
    output wire O,
    output wire OB
);

    OBUFDS #(
        .IOSTANDARD("TMDS_33")
    ) tmds_obuf (
        .I (I),
        .O (O),
        .OB(OB)
    );

    wire _unused_oen = OEN;

endmodule
