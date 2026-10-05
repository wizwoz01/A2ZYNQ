# AXI readback of the SPI master data regs shares a long path through the TX
# distributed RAM. It missed by 7 ps once; phys_opt that "fixed" it also broke
# MOSI so volume writes read back as 0. Give that readback two PS clocks.
# The SPI shift itself is a separate generated clock and is not relaxed.
set_multicycle_path -setup 2 -to [get_pins -quiet -hier -filter {NAME =~ */u_spi/s_axi_rdata_reg[*]/D}]
set_multicycle_path -hold 1 -to [get_pins -quiet -hier -filter {NAME =~ */u_spi/s_axi_rdata_reg[*]/D}]
