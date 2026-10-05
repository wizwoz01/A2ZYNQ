`timescale 1ns/1ps

// Physical Smart Zynq SP board shell.
//
// Keep the original Xillinux top-level pin names so the vendor-supplied
// xillydemo.xdc remains valid, but replace the old Xillybus/VGA application
// with the patched vivado_system block design. J5/J6 are dedicated to the
// Apple II interface and are NOT also connected to PS GPIO.
module smart_zynq_board_top (
    input  wire        clk_50,

    inout  wire [33:0] J5,
    inout  wire [33:0] J6,

    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n,
    output wire [2:0]  hdmi_d_p,
    output wire [2:0]  hdmi_d_n,

    input  wire        uart_rxd,
    output wire        uart_txd,

    output wire        MDIO_PHY_mdc,
    inout  wire        MDIO_PHY_mdio_io,
    input  wire [3:0]  RGMII_rd,
    input  wire        RGMII_rx_ctl,
    input  wire        RGMII_rxc,
    output wire [3:0]  RGMII_td,
    output wire        RGMII_tx_ctl,
    output wire        RGMII_txc,

    inout  wire        EEPROM_SCL,
    inout  wire        EEPROM_SDA,

    inout  wire        LCD_SCL,
    inout  wire        LCD_SDA,
    inout  wire        LCD_CS,
    output wire        LCD_DC,
    output wire        LCD_RES,
    output wire        LCD_BLK,

    output wire        LED1,
    output wire        LED2,
    input  wire        KEY1,
    input  wire        KEY2
);
    wire [63:0] gpio_tri_i;
    wire [63:0] gpio_tri_o;
    wire [63:0] gpio_tri_t;

    // J5 used to be wired to GPIO[33:0] in the stock Xillinux demo. Those
    // pins now carry the Apple bus, so leave the corresponding PS GPIO inputs
    // at zero. Preserve the on-board key/LCD/LED GPIO assignments.
    assign gpio_tri_i[60:0] = 61'b0;
    assign gpio_tri_i[61]   = KEY1;
    assign gpio_tri_i[62]   = KEY2;
    assign gpio_tri_i[63]   = 1'b0;

    assign LED1    = gpio_tri_t[0]  ? 1'b0 : gpio_tri_o[0];
    assign LED2    = gpio_tri_t[63] ? 1'b0 : gpio_tri_o[63];
    assign LCD_RES = gpio_tri_t[60] ? 1'b0 : gpio_tri_o[60];
    assign LCD_DC  = gpio_tri_t[59] ? 1'b0 : gpio_tri_o[59];
    assign LCD_BLK = gpio_tri_t[58] ? 1'b0 : gpio_tri_o[58];

    wire mdio_i, mdio_o, mdio_t;
    IOBUF mdio_iobuf (
        .I(mdio_o), .IO(MDIO_PHY_mdio_io), .O(mdio_i), .T(mdio_t)
    );

    wire eeprom_scl_i, eeprom_scl_o, eeprom_scl_t;
    wire eeprom_sda_i, eeprom_sda_o, eeprom_sda_t;
    IOBUF eeprom_scl_iobuf (
        .I(eeprom_scl_o), .IO(EEPROM_SCL), .O(eeprom_scl_i), .T(eeprom_scl_t)
    );
    IOBUF eeprom_sda_iobuf (
        .I(eeprom_sda_o), .IO(EEPROM_SDA), .O(eeprom_sda_i), .T(eeprom_sda_t)
    );

    // Stock PS SPI0 EMIO drives the on-board LCD. SSIN is tied high as
    // required for master mode; it must not be looped back from the driven CS.
    wire lcd_sck_i, lcd_sck_o, lcd_sck_t;
    wire lcd_io0_i, lcd_io0_o, lcd_io0_t;
    wire lcd_ss_i_unused, lcd_ss_o, lcd_ss_t;
    IOBUF lcd_sck_iobuf (
        .I(lcd_sck_o), .IO(LCD_SCL), .O(lcd_sck_i), .T(lcd_sck_t)
    );
    IOBUF lcd_io0_iobuf (
        .I(lcd_io0_o), .IO(LCD_SDA), .O(lcd_io0_i), .T(lcd_io0_t)
    );
    IOBUF lcd_ss_iobuf (
        .I(lcd_ss_o), .IO(LCD_CS), .O(lcd_ss_i_unused), .T(lcd_ss_t)
    );

    vivado_system vivado_system_i (
        .GPIO_0_tri_i(gpio_tri_i),
        .GPIO_0_tri_o(gpio_tri_o),
        .GPIO_0_tri_t(gpio_tri_t),

        .IIC_0_0_scl_i(eeprom_scl_i),
        .IIC_0_0_scl_o(eeprom_scl_o),
        .IIC_0_0_scl_t(eeprom_scl_t),
        .IIC_0_0_sda_i(eeprom_sda_i),
        .IIC_0_0_sda_o(eeprom_sda_o),
        .IIC_0_0_sda_t(eeprom_sda_t),

        // IIC1 is not used by this board shell. Keep the bus idle.
        .IIC_1_0_scl_i(1'b1),
        .IIC_1_0_scl_o(),
        .IIC_1_0_scl_t(),
        .IIC_1_0_sda_i(1'b1),
        .IIC_1_0_sda_o(),
        .IIC_1_0_sda_t(),

        .J5(J5),
        .J6(J6),

        .MDIO_PHY_0_mdc(MDIO_PHY_mdc),
        .MDIO_PHY_0_mdio_i(mdio_i),
        .MDIO_PHY_0_mdio_o(mdio_o),
        .MDIO_PHY_0_mdio_t(mdio_t),
        .RGMII_0_rd(RGMII_rd),
        .RGMII_0_rx_ctl(RGMII_rx_ctl),
        .RGMII_0_rxc(RGMII_rxc),
        .RGMII_0_td(RGMII_td),
        .RGMII_0_tx_ctl(RGMII_tx_ctl),
        .RGMII_0_txc(RGMII_txc),

        .SPI_0_0_io0_i(lcd_io0_i),
        .SPI_0_0_io0_o(lcd_io0_o),
        .SPI_0_0_io0_t(lcd_io0_t),
        .SPI_0_0_io1_i(1'b0),
        .SPI_0_0_io1_o(),
        .SPI_0_0_io1_t(),
        .SPI_0_0_sck_i(lcd_sck_i),
        .SPI_0_0_sck_o(lcd_sck_o),
        .SPI_0_0_sck_t(lcd_sck_t),
        .SPI_0_0_ss1_o(),
        .SPI_0_0_ss2_o(),
        .SPI_0_0_ss_i(1'b1),
        .SPI_0_0_ss_o(lcd_ss_o),
        .SPI_0_0_ss_t(lcd_ss_t),

        .UART_0_0_rxd(uart_rxd),
        .UART_0_0_txd(uart_txd),

        .clk_50(clk_50),
        .hdmi_clk_p(hdmi_clk_p),
        .hdmi_clk_n(hdmi_clk_n),
        .hdmi_data_p(hdmi_d_p),
        .hdmi_data_n(hdmi_d_n)
    );

    wire _unused_lcd_ss_i = lcd_ss_i_unused;
endmodule
