# Internal SPI SCLK is generated from PS FCLK (100 MHz) by axi_spi_master.
# The Enhanced companion proto (bl616_spi_proto_proc) is a genuine SPI slave
# that clocks on posedge/negedge spi_sclk, so this net must be a defined clock.
#
# axi_spi_master toggles phase / spi_sclk every clock_div AXI cycles, so the
# SPI period is 2*clock_div AXI cycles.  Default clock_div=4 -> 12.5 MHz.
# Time against divide-by-4 (clock_div=2, 25 MHz) so a faster userspace setting
# still meets timing.  Treat the SPI clock as asynchronous to the Apple/core
# clocks, matching the original external-MCU relationship.
set phase_q [get_pins -quiet -hier -filter {NAME =~ */u_spi/phase_reg/Q}]
set phase_c [get_pins -quiet -hier -filter {NAME =~ */u_spi/phase_reg/C}]
if {![llength $phase_q]} {
    set phase_q [get_pins -quiet -hier -filter {NAME =~ */u_spi/spi_sclk_reg/Q}]
    set phase_c [get_pins -quiet -hier -filter {NAME =~ */u_spi/spi_sclk_reg/C}]
}
if {[llength $phase_q] && [llength $phase_c]} {
    if {[llength [get_clocks -quiet a2_spi_sclk]] == 0} {
        create_generated_clock -name a2_spi_sclk -source [lindex $phase_c 0] -divide_by 4 [lindex $phase_q 0]
    }
    set_clock_groups -asynchronous -group [get_clocks -quiet a2_spi_sclk]
}
