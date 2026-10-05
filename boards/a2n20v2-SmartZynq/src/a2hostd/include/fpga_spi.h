#ifndef A2HOST_FPGA_SPI_H
#define A2HOST_FPGA_SPI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define FPGA_SPACE_SDRAM 1u
#define FPGA_SPACE_BUS_FIFO 2u
#define FPGA_SPACE_W5100 3u
#define FPGA_REG_U2_CMD_PENDING 0x7Au
uint8_t fpga_spi_reg_read(uint8_t reg);
void fpga_spi_reg_write(uint8_t reg, uint8_t val);
void fpga_spi_xfer_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len);
void fpga_spi_xfer_read(uint8_t space, uint32_t addr, uint8_t *data, uint16_t len);
#ifdef __cplusplus
}
#endif
#endif
