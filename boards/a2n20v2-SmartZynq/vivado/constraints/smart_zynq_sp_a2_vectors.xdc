# Additional electrical policy for the Smart-Zynq A2 adapter.
# Physical package pins for clk_50/J5/J6/HDMI are supplied by the exact bundled
# Xillinux SmartZynq-SP xillydemo.xdc. Do not duplicate package assignments here.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property DRIVE 4 [get_ports {J5[*]}]
set_property SLEW SLOW [get_ports {J5[*]}]

# DIP switches SW1-SW4 on U13 pins 15-18 (J5[14]-J5[17]). Each switch pulls its
# pin to ground when ON; the card has no pull-up resistors, so the FPGA's own
# pull-ups hold an OFF (or unwired) switch high instead of letting it float.
set_property PULLUP true [get_ports {J5[14] J5[15] J5[16] J5[17]}]

set_property DRIVE 4 [get_ports {J6[*]}]
set_property SLEW SLOW [get_ports {J6[*]}]
# D0-D7 (J6[0..7]) feed U5, a TXB0108 on the Rev 3.0 red card. Its Apple side
# holds levels through ~4 kohm; noise there fires the TXB's edge accelerators,
# which push back on the Zynq side. Drive those pins at the LVCMOS33 maximum so
# a false edge cannot bounce them and come back out as a full swing.
set_property DRIVE 16 [get_ports {J6[0] J6[1] J6[2] J6[3] J6[4] J6[5] J6[6] J6[7]}]

# Differential negative pins are inferred from the positive package pins in the
# vendor XDC; declare the electrical standard on both logical halves.
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_clk_p hdmi_clk_n}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_d_p[*] hdmi_d_n[*]}]

# Apple II bus timing.
#
# J5/J6 carry the Apple II slot signals through the external SN74LVC245A
# transceivers. They are asynchronous to every clock in this design: the core
# recovers Apple bus timing by oversampling phi1/7M in the clk_logic domain
# (hdl/bus/a2bus_timing.sv), and rtl/a2_bus_phy.sv is a
# combinational pass-through with no capture clock of its own. So there is no
# real setup/hold relationship to declare, but these paths must still be
# constrained rather than left for report_timing_summary to flag as
# unconstrained. The bus runs at roughly 1 MHz, so the resulting slack is
# irrelevant either way.
#
# The clk_50-derived core clocks (27 MHz pixel, 54 MHz logic, 135 MHz TMDS) are
# already declared asynchronous to the PS FCLK domains by the vendor
# xillydemo.xdc, which groups them with -include_generated_clocks; do not
# duplicate that here.
set a2_bus_ports [get_ports -quiet {J5[*] J6[*]}]
if {[llength $a2_bus_ports]} {
    set_false_path -from $a2_bus_ports
    set_false_path -to $a2_bus_ports
}
