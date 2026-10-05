`timescale 1ns/1ps

module smart_zynq_a2_application(
    input wire clk_50,
    input wire fclk_100,
    input wire resetn_100,
    input wire ps_host_ready,
    inout wire [33:0] J5,
    inout wire [33:0] J6,
    input wire legacy_spi_sck,
    input wire legacy_spi_cs_n,
    input wire legacy_spi_mosi,
    output wire legacy_spi_miso,
    output wire legacy_mcu_irq,
    output wire hdmi_clk_p,
    output wire hdmi_clk_n,
    output wire [2:0] hdmi_data_p,
    output wire [2:0] hdmi_data_n,
    output wire [5:0] M_AXI_MEM_AWID,
    output wire [31:0] M_AXI_MEM_AWADDR,
    output wire [7:0] M_AXI_MEM_AWLEN,
    output wire [2:0] M_AXI_MEM_AWSIZE,
    output wire [1:0] M_AXI_MEM_AWBURST,
    output wire M_AXI_MEM_AWVALID,
    input wire M_AXI_MEM_AWREADY,
    output wire [31:0] M_AXI_MEM_WDATA,
    output wire [3:0] M_AXI_MEM_WSTRB,
    output wire M_AXI_MEM_WLAST,
    output wire M_AXI_MEM_WVALID,
    input wire M_AXI_MEM_WREADY,
    input wire [5:0] M_AXI_MEM_BID,
    input wire [1:0] M_AXI_MEM_BRESP,
    input wire M_AXI_MEM_BVALID,
    output wire M_AXI_MEM_BREADY,
    output wire [5:0] M_AXI_MEM_ARID,
    output wire [31:0] M_AXI_MEM_ARADDR,
    output wire [7:0] M_AXI_MEM_ARLEN,
    output wire [2:0] M_AXI_MEM_ARSIZE,
    output wire [1:0] M_AXI_MEM_ARBURST,
    output wire M_AXI_MEM_ARVALID,
    input wire M_AXI_MEM_ARREADY,
    input wire [5:0] M_AXI_MEM_RID,
    input wire [31:0] M_AXI_MEM_RDATA,
    input wire [1:0] M_AXI_MEM_RRESP,
    input wire M_AXI_MEM_RLAST,
    input wire M_AXI_MEM_RVALID,
    output wire M_AXI_MEM_RREADY
);
    wire clk27, unused_clk54, unused_clk108, unused_clk135, input_clock_locked;
    wire reset = ~resetn_100;
    a2_clocking_xilinx clocks(
        .clk_50(clk_50),.reset(reset),.clk_27(clk27),.clk_54(unused_clk54),
        .clk_108(unused_clk108),.clk_135(unused_clk135),.locked(input_clock_locked));

    wire [7:0] core_data_in, core_data_out;
    wire core_data_drive;
    wire [15:0] ba;
    wire brw,bp0,bp1,b7,bq3,bsync,biosel,biostrb,bdevsel,bm2sel,bm2b0;
    wire breset,brdy,bdma,bnmi,birq,binh;
    wire core_irq_assert,core_nmi_assert,core_rdy_assert,core_dma_assert,core_inh_assert,core_reset_assert;
    wire data_dir,data_oe_n,input_oe_n,irq_assert,nmi_assert,rdy_assert,dma_assert,inh_assert,reset_assert,ready;
    wire core_clk_logic, core_clocks_locked;
    wire [7:0] sz_drive_data, sz_drive_fine;
    wire [15:0] sz_drive_cfg;
    wire sz_drive_en;
    wire core_clk_4x;
    wire bridge_reset_n = resetn_100 & input_clock_locked & core_clocks_locked;

    // Five-LVC245 adapter control outputs.
    assign J6[8] = data_dir;
    assign J6[9] = data_oe_n;
    assign J5[12] = input_oe_n;
    assign J5[2] = irq_assert;
    assign J5[3] = nmi_assert;
    assign J5[4] = rdy_assert;
    assign J5[5] = dma_assert;
    assign J5[6] = inh_assert;
    assign J5[7] = reset_assert;
    assign J5[26] = ready;

    a2_bus_phy phy(
        .clk(core_clk_logic),.reset_n(resetn_100),
        .clocks_locked(input_clock_locked & core_clocks_locked),
        .host_ready(ps_host_ready),.a2_5v_present(J5[13]),
        .a2_data(J6[7:0]),
        .a2_addr({J6[29],J6[27],J6[26],J6[24],J6[23],J6[22],J6[21],J6[20],J6[19],J6[18],J6[17],J6[15],J6[14],J6[12],J6[11],J6[10]}),
        .a2_rw(J6[30]),.a2_phi0(J6[13]),.a2_phi1(J6[16]),.a2_7m(J6[25]),
        .a2_q3(J6[28]),.a2_sync(J5[18]),.a2_iosel_n(J6[31]),.a2_iostrb_n(J6[32]),
        .a2_devsel_n(J6[33]),.a2_m2sel(J5[0]),.a2_m2b0(J5[1]),
        .a2_reset_asserted_sense(J5[19]),.a2_rdy_n_sense(J5[8]),.a2_dma_n_sense(J5[9]),
        .a2_nmi_n_sense(J5[10]),.a2_irq_n_sense(J5[11]),.a2_inh_n_sense(J5[20]),
        .core_data_out(core_data_out),.core_data_drive(core_data_drive),
        .clk4x(core_clk_4x),.core_drive_fine(sz_drive_fine),.core_drive_cfg(sz_drive_cfg),
        .core_data_in(core_data_in),
        .core_irq_assert(core_irq_assert),.core_nmi_assert(core_nmi_assert),.core_rdy_assert(core_rdy_assert),
        .core_dma_assert(core_dma_assert),.core_inh_assert(core_inh_assert),.core_reset_assert(core_reset_assert),
        .a2_data_dir(data_dir),.a2_data_oe_n(data_oe_n),.a2_input_oe_n(input_oe_n),
        .a2_irq_assert(irq_assert),.a2_nmi_assert(nmi_assert),.a2_rdy_assert(rdy_assert),
        .a2_dma_assert(dma_assert),.a2_inh_assert(inh_assert),.a2_reset_assert(reset_assert),.pl_ready(ready),
        .bus_addr(ba),.bus_rw(brw),.bus_phi0(bp0),.bus_phi1(bp1),.bus_7m(b7),.bus_q3(bq3),
        .bus_sync(bsync),.bus_iosel_n(biosel),.bus_iostrb_n(biostrb),.bus_devsel_n(bdevsel),
        .bus_m2sel(bm2sel),.bus_m2b0(bm2b0),.bus_reset_n(breset),.bus_rdy_n(brdy),
        .bus_dma_n(bdma),.bus_nmi_n(bnmi),.bus_irq_n(birq),.bus_inh_n(binh));

    wire [2:0] bridge_sel;
    wire bridge_rd,bridge_wr,bridge_phi1,bridge_7m,bridge_q3,bridge_reset_n_from_phy;
    wire bridge_addr_oe_n,bridge_data_oe_n;
    wire [7:0] bridge_data_to_core, bridge_data_from_core;
    wire [7:0] bus_data_out;
    wire pull_inh, pull_irq, pull_rdy, pull_dma, pull_nmi, pull_reset;
    // D0-D7 come straight from apple_bus (sz_drive_*): the card's byte is on
    // the pins from the first clock of the drive. The bridge data latch
    // (bus_data_out) is no longer in the path.
    assign core_data_out = sz_drive_data;
    assign core_data_drive = sz_drive_en;

    // Fabric-side open-collector resolution using AND, not wired-net types.
    wire vrdy   = brdy   & ~pull_rdy;
    wire vdma   = bdma   & ~pull_dma;
    wire virq   = birq   & ~pull_irq;
    wire vnmi   = bnmi   & ~pull_nmi;
    wire vinh   = binh   & ~pull_inh;
    wire vreset = breset & ~pull_reset;

    a2bridge_pl_wrapper bridge(
        .clk(core_clk_logic),.reset_n(bridge_reset_n),.switch_n(J5[17:14]),
        .bus_addr(ba),.bus_data(core_data_in),.bus_data_out(bus_data_out),
        .bus_rw(brw),.bus_sync(bsync),.bus_7m(b7),.bus_q3(bq3),
        .bus_phi0(bp0),.bus_phi1(bp1),.bus_iosel_n(biosel),.bus_iostrb_n(biostrb),
        .bus_devsel_n(bdevsel),.bus_reset_n(vreset),.bus_m2sel(bm2sel),.bus_m2b0(bm2b0),
        .bus_rdy_n(vrdy),.bus_dma_n(vdma),.bus_irq_n(virq),.bus_nmi_n(vnmi),.bus_inh_n(vinh),
        .pull_inh(pull_inh),.pull_irq(pull_irq),.pull_rdy(pull_rdy),
        .pull_dma(pull_dma),.pull_nmi(pull_nmi),.pull_reset(pull_reset),
        .bus_dmain_n(1'b1),.bus_intin_n(1'b1),.bus_dmaout_n(),.bus_intout_n(),
        .bridge_data_i(bridge_data_from_core),.bridge_data_o(bridge_data_to_core),
        .bridge_sel(bridge_sel),.bridge_rd(bridge_rd),.bridge_wr(bridge_wr),
        .bridge_phi1(bridge_phi1),.bridge_7m(bridge_7m),.bridge_q3(bridge_q3),
        .bridge_reset_n(bridge_reset_n_from_phy),
        .bridge_addr_oe_n(bridge_addr_oe_n),.bridge_data_oe_n(bridge_data_oe_n));

    assign core_rdy_assert   = pull_rdy;
    assign core_dma_assert   = pull_dma;
    assign core_irq_assert   = pull_irq;
    assign core_nmi_assert   = pull_nmi;
    assign core_inh_assert   = pull_inh;
    assign core_reset_assert = pull_reset;

    mem_port_if #(.PORT_ADDR_WIDTH(21),.DATA_WIDTH(32),.DQM_WIDTH(4),.PORT_OUTPUT_WIDTH(32)) legacy_mem_port();

    legacy_a2fpga_binding core(
        .clk_27(clk27),.reset(reset),.reset_n(resetn_100),
        .bridge_data_i(bridge_data_to_core),.bridge_data_o(bridge_data_from_core),
        .bridge_sel(bridge_sel),.bridge_rd(bridge_rd),.bridge_wr(bridge_wr),
        .bridge_phi1(bridge_phi1),.bridge_7m(bridge_7m),.bridge_q3(bridge_q3),
        .bridge_reset_n(bridge_reset_n_from_phy),
        .a2_5v_present(J5[13]),
        .bridge_addr_oe_n(bridge_addr_oe_n),.bridge_data_oe_n(bridge_data_oe_n),.switch_n(J5[17:14]),
        .bridge_drive_data(sz_drive_data),.bridge_drive_en(sz_drive_en),.bridge_drive_fine(sz_drive_fine),.bridge_drive_cfg(sz_drive_cfg),
        .bridge_slot_sel_n({bdevsel,biosel}),
        .legacy_spi_sck(legacy_spi_sck),.legacy_spi_cs_n(legacy_spi_cs_n),.legacy_spi_mosi(legacy_spi_mosi),
        .legacy_spi_miso(legacy_spi_miso),.legacy_mcu_irq(legacy_mcu_irq),
        .hdmi_clk_p(hdmi_clk_p),.hdmi_clk_n(hdmi_clk_n),.hdmi_data_p(hdmi_data_p),.hdmi_data_n(hdmi_data_n),
        .core_clk_logic(core_clk_logic),.core_clk_4x(core_clk_4x),.core_clocks_locked(core_clocks_locked),.legacy_mem_port(legacy_mem_port));

    legacy_mem_port_axi #(.DDR_BASE(32'h1e000000)) mem_backend(
        .mem_clk(core_clk_logic),.axi_clk(fclk_100),.reset_n(bridge_reset_n),.mem(legacy_mem_port),
        .m_axi_awid(M_AXI_MEM_AWID),.m_axi_awaddr(M_AXI_MEM_AWADDR),.m_axi_awlen(M_AXI_MEM_AWLEN),
        .m_axi_awsize(M_AXI_MEM_AWSIZE),.m_axi_awburst(M_AXI_MEM_AWBURST),.m_axi_awvalid(M_AXI_MEM_AWVALID),.m_axi_awready(M_AXI_MEM_AWREADY),
        .m_axi_wdata(M_AXI_MEM_WDATA),.m_axi_wstrb(M_AXI_MEM_WSTRB),.m_axi_wlast(M_AXI_MEM_WLAST),.m_axi_wvalid(M_AXI_MEM_WVALID),.m_axi_wready(M_AXI_MEM_WREADY),
        .m_axi_bid(M_AXI_MEM_BID),.m_axi_bresp(M_AXI_MEM_BRESP),.m_axi_bvalid(M_AXI_MEM_BVALID),.m_axi_bready(M_AXI_MEM_BREADY),
        .m_axi_arid(M_AXI_MEM_ARID),.m_axi_araddr(M_AXI_MEM_ARADDR),.m_axi_arlen(M_AXI_MEM_ARLEN),
        .m_axi_arsize(M_AXI_MEM_ARSIZE),.m_axi_arburst(M_AXI_MEM_ARBURST),.m_axi_arvalid(M_AXI_MEM_ARVALID),.m_axi_arready(M_AXI_MEM_ARREADY),
        .m_axi_rid(M_AXI_MEM_RID),.m_axi_rdata(M_AXI_MEM_RDATA),.m_axi_rresp(M_AXI_MEM_RRESP),.m_axi_rlast(M_AXI_MEM_RLAST),.m_axi_rvalid(M_AXI_MEM_RVALID),.m_axi_rready(M_AXI_MEM_RREADY));
endmodule
