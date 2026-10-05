`timescale 1ns/1ps
// 7-series 10:1 TMDS serializer. clk_5x is five times clk_pixel and both must
// come from the same MMCM/PLL. OSERDESE2 DDR outputs ten bits per pixel.
module tmds_oserdes10(
    input wire clk_pixel,input wire clk_5x,input wire reset,
    input wire [9:0] data,input wire tmds_oe,
    output wire tmds_p,output wire tmds_n
);
`ifdef SYNTHESIS
    wire shift1,serial;
    OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_WIDTH(10),.SERDES_MODE("MASTER"),.TRISTATE_WIDTH(1)) master(
      .OQ(serial),.CLK(clk_5x),.CLKDIV(clk_pixel),.RST(reset),.OCE(1'b1),
      .D1(data[0]),.D2(data[1]),.D3(data[2]),.D4(data[3]),.D5(data[4]),.D6(data[5]),.D7(data[6]),.D8(data[7]),
      .SHIFTIN1(shift1),.SHIFTIN2(1'b0),.SHIFTOUT1(),.SHIFTOUT2(),
      .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0),.TBYTEOUT(),.TFB(),.TQ(),.OFB()
    );
    OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_WIDTH(10),.SERDES_MODE("SLAVE"),.TRISTATE_WIDTH(1)) slave(
      .OQ(),.CLK(clk_5x),.CLKDIV(clk_pixel),.RST(reset),.OCE(1'b1),
      .D1(1'b0),.D2(1'b0),.D3(data[8]),.D4(data[9]),.D5(1'b0),.D6(1'b0),.D7(1'b0),.D8(1'b0),
      .SHIFTIN1(1'b0),.SHIFTIN2(1'b0),.SHIFTOUT1(),.SHIFTOUT2(shift1),
      .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0),.TBYTEOUT(),.TFB(),.TQ(),.OFB()
    );
    // OSERDESE2 OQ cannot feed OBUFTDS.T (Place 30-608). HDMI always drives.
    OBUFDS #(.IOSTANDARD("TMDS_33")) obuf(.I(serial),.O(tmds_p),.OB(tmds_n));
    wire _unused_oe = tmds_oe;
`else
    reg [9:0] shadow,shift_reg; reg [3:0] count; reg serial_sim;
    always @(posedge clk_pixel) shadow <= data;
    always @(posedge clk_5x or negedge clk_5x) begin
      if(reset) begin shift_reg<=0;count<=0;serial_sim<=0; end
      else begin
        if(count==0) shift_reg<=shadow; else shift_reg<={1'b0,shift_reg[9:1]};
        serial_sim <= (count==0)?shadow[0]:shift_reg[1];
        count <= (count==9)?0:count+1'b1;
      end
    end
    assign tmds_p=tmds_oe?serial_sim:1'bz; assign tmds_n=tmds_oe?~serial_sim:1'bz;
`endif
endmodule
