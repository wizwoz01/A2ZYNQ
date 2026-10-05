`timescale 1ns/1ps

// Plain-Verilog BD wrapper.
// Vivado IP Integrator Module Reference does not allow a SystemVerilog
// module as the reference top, so all implementation remains underneath.
module smart_zynq_a2_application_bd(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_50 CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_50, FREQ_HZ 50000000" *)
    input  wire        clk_50,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 fclk_100 CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME fclk_100, FREQ_HZ 100000000, ASSOCIATED_BUSIF M_AXI_MEM, ASSOCIATED_RESET resetn_100" *)
    input  wire        fclk_100,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn_100 RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn_100, POLARITY ACTIVE_LOW" *)
    input  wire        resetn_100,
    input  wire        ps_host_ready,

    inout  wire [33:0] J5,
    inout  wire [33:0] J6,

    input  wire        legacy_spi_sck,
    input  wire        legacy_spi_cs_n,
    input  wire        legacy_spi_mosi,
    output wire        legacy_spi_miso,
    output wire        legacy_mcu_irq,

    (* X_INTERFACE_IGNORE = "true" *) output wire hdmi_clk_p,
    (* X_INTERFACE_IGNORE = "true" *) output wire hdmi_clk_n,
    output wire [2:0]  hdmi_data_p,
    output wire [2:0]  hdmi_data_n,

    output wire [5:0]  M_AXI_MEM_AWID,
    output wire [31:0] M_AXI_MEM_AWADDR,
    output wire [7:0]  M_AXI_MEM_AWLEN,
    output wire [2:0]  M_AXI_MEM_AWSIZE,
    output wire [1:0]  M_AXI_MEM_AWBURST,
    output wire        M_AXI_MEM_AWVALID,
    input  wire        M_AXI_MEM_AWREADY,

    output wire [31:0] M_AXI_MEM_WDATA,
    output wire [3:0]  M_AXI_MEM_WSTRB,
    output wire        M_AXI_MEM_WLAST,
    output wire        M_AXI_MEM_WVALID,
    input  wire        M_AXI_MEM_WREADY,

    input  wire [5:0]  M_AXI_MEM_BID,
    input  wire [1:0]  M_AXI_MEM_BRESP,
    input  wire        M_AXI_MEM_BVALID,
    output wire        M_AXI_MEM_BREADY,

    output wire [5:0]  M_AXI_MEM_ARID,
    output wire [31:0] M_AXI_MEM_ARADDR,
    output wire [7:0]  M_AXI_MEM_ARLEN,
    output wire [2:0]  M_AXI_MEM_ARSIZE,
    output wire [1:0]  M_AXI_MEM_ARBURST,
    output wire        M_AXI_MEM_ARVALID,
    input  wire        M_AXI_MEM_ARREADY,

    input  wire [5:0]  M_AXI_MEM_RID,
    input  wire [31:0] M_AXI_MEM_RDATA,
    input  wire [1:0]  M_AXI_MEM_RRESP,
    input  wire        M_AXI_MEM_RLAST,
    input  wire        M_AXI_MEM_RVALID,
    output wire        M_AXI_MEM_RREADY
);

smart_zynq_a2_application u_application (
    .clk_50(clk_50),
    .fclk_100(fclk_100),
    .resetn_100(resetn_100),
    .ps_host_ready(ps_host_ready),

    .J5(J5),
    .J6(J6),

    .legacy_spi_sck(legacy_spi_sck),
    .legacy_spi_cs_n(legacy_spi_cs_n),
    .legacy_spi_mosi(legacy_spi_mosi),
    .legacy_spi_miso(legacy_spi_miso),
    .legacy_mcu_irq(legacy_mcu_irq),

    .hdmi_clk_p(hdmi_clk_p),
    .hdmi_clk_n(hdmi_clk_n),
    .hdmi_data_p(hdmi_data_p),
    .hdmi_data_n(hdmi_data_n),

    .M_AXI_MEM_AWID(M_AXI_MEM_AWID),
    .M_AXI_MEM_AWADDR(M_AXI_MEM_AWADDR),
    .M_AXI_MEM_AWLEN(M_AXI_MEM_AWLEN),
    .M_AXI_MEM_AWSIZE(M_AXI_MEM_AWSIZE),
    .M_AXI_MEM_AWBURST(M_AXI_MEM_AWBURST),
    .M_AXI_MEM_AWVALID(M_AXI_MEM_AWVALID),
    .M_AXI_MEM_AWREADY(M_AXI_MEM_AWREADY),

    .M_AXI_MEM_WDATA(M_AXI_MEM_WDATA),
    .M_AXI_MEM_WSTRB(M_AXI_MEM_WSTRB),
    .M_AXI_MEM_WLAST(M_AXI_MEM_WLAST),
    .M_AXI_MEM_WVALID(M_AXI_MEM_WVALID),
    .M_AXI_MEM_WREADY(M_AXI_MEM_WREADY),

    .M_AXI_MEM_BID(M_AXI_MEM_BID),
    .M_AXI_MEM_BRESP(M_AXI_MEM_BRESP),
    .M_AXI_MEM_BVALID(M_AXI_MEM_BVALID),
    .M_AXI_MEM_BREADY(M_AXI_MEM_BREADY),

    .M_AXI_MEM_ARID(M_AXI_MEM_ARID),
    .M_AXI_MEM_ARADDR(M_AXI_MEM_ARADDR),
    .M_AXI_MEM_ARLEN(M_AXI_MEM_ARLEN),
    .M_AXI_MEM_ARSIZE(M_AXI_MEM_ARSIZE),
    .M_AXI_MEM_ARBURST(M_AXI_MEM_ARBURST),
    .M_AXI_MEM_ARVALID(M_AXI_MEM_ARVALID),
    .M_AXI_MEM_ARREADY(M_AXI_MEM_ARREADY),

    .M_AXI_MEM_RID(M_AXI_MEM_RID),
    .M_AXI_MEM_RDATA(M_AXI_MEM_RDATA),
    .M_AXI_MEM_RRESP(M_AXI_MEM_RRESP),
    .M_AXI_MEM_RLAST(M_AXI_MEM_RLAST),
    .M_AXI_MEM_RVALID(M_AXI_MEM_RVALID),
    .M_AXI_MEM_RREADY(M_AXI_MEM_RREADY)
);

endmodule
