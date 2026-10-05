# Rebuild the A2 overlay on the pristine Smart-Zynq Xillinux block design.
# build.tcl restores the kit's original vivado_system.bd (the .pristine copy)
# before this script runs, so no stale A2 graph objects can accumulate between builds.
set bd_file [lindex [get_files -quiet */vivado_system.bd] 0]
if {$bd_file eq ""} { error "vivado_system.bd was not found" }
open_bd_design $bd_file
set ps [lindex [get_bd_cells -quiet -filter {VLNV =~ "xilinx.com:ip:processing_system7:*"}] 0]
if {$ps eq ""} { error "processing_system7 cell not found" }

# Remove application-exclusive nets BEFORE deleting their cells/ports. Vivado
# otherwise leaves no-source nets behind when module references disappear. Keep
# the shared FCLK/reset/Ethernet/I2C/UART nets intact.
foreach n [get_bd_nets -quiet] {
    set nm [get_property NAME $n]
    if {[regexp -nocase {^(xilly|dvi_|user_|xlconcat_0_dout$)|^user_(irq|rd_data)_} $nm]} {
        catch {delete_bd_objs $n}
    }
}
foreach n [get_bd_intf_nets -quiet] {
    set nm [get_property NAME $n]
    if {[regexp -nocase {xilly|xillyvga|processing_system7_0_axi_periph_M0[0-2]_AXI|processing_system7_0_M_AXI_GP0} $nm]} {
        catch {delete_bd_objs $n}
    }
}

# Remove stock application cells but preserve PS7, reset, Ethernet, GPIO, I2C,
# UART and board SPI. HP2 is intentionally retained and repurposed for A2 DDR.
foreach cname {
    xillybus_ip_0 xillybus_lite_0 xillyvga_0 xlconcat_0
    processing_system7_0_axi_periph
    a2_irq_concat a2_irq_zero a2_hp2_ic a2_gp0_ic a2_spi a2_app
} {
    set c [get_bd_cells -quiet $cname]
    if {[llength $c]} { catch {delete_bd_objs $c} }
}

# Remove obsolete stock application external ports/interfaces.
foreach pname {
    xillybus_host_interrupt xillybus_bus_rst_n xillybus_bus_clk
    user_wstrb user_addr user_wren user_clk user_rden user_wr_data user_rd_data user_irq
    dvi_clk_p dvi_clk_n dvi_d_p dvi_d_n
    xillybus_M_AXI xillybus_S_AXI
} {
    set p [get_bd_ports -quiet $pname]
    if {[llength $p]} { catch {delete_bd_objs $p} }
    set ip [get_bd_intf_ports -quiet $pname]
    if {[llength $ip]} { catch {delete_bd_objs $ip} }
}

# HP2 may still carry the old Xilly interface net; remove only that interface
# net, leaving FCLK1 -> S_AXI_HP2_ACLK intact.
foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $ps/S_AXI_HP2]] {
    catch {delete_bd_objs $n}
}
# ACP is not used by this port. Remove its stock external-interface net so it
# cannot leave an incomplete address path or USER-width warning behind.
foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $ps/S_AXI_ACP]] {
    catch {delete_bd_objs $n}
}
# GP0 was connected to the deleted stock interconnect. Clear that interface net.
foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $ps/M_AXI_GP0]] {
    catch {delete_bd_objs $n}
}
# Clear the old IRQ concatenation net before replacing it.
foreach n [get_bd_nets -quiet -of_objects [get_bd_pins $ps/IRQ_F2P]] {
    catch {delete_bd_objs $n}
}

# Functional A2 application + native companion SPI transport.
create_bd_cell -type module -reference smart_zynq_a2_application_bd a2_app
create_bd_cell -type module -reference axi_spi_master_bd a2_spi

set fclk [get_bd_pins $ps/FCLK_CLK1]
set rst_cell [get_bd_cells rst_processing_system7_0_100M]
if {[llength $rst_cell] == 0} { error "proc_sys_reset cell missing" }
set per_rst [get_bd_pins rst_processing_system7_0_100M/peripheral_aresetn]
set ic_rst  [get_bd_pins rst_processing_system7_0_100M/interconnect_aresetn]

connect_bd_net $fclk [get_bd_pins a2_app/fclk_100] [get_bd_pins a2_spi/s_axi_aclk]
connect_bd_net $per_rst [get_bd_pins a2_app/resetn_100] [get_bd_pins a2_spi/s_axi_aresetn]

# GP0 -> one AXI-Lite SPI transport register aperture.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 a2_gp0_ic
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells a2_gp0_ic]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP0] [get_bd_intf_pins a2_gp0_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins a2_gp0_ic/M00_AXI] [get_bd_intf_pins a2_spi/S_AXI]
foreach pin [get_bd_pins -quiet a2_gp0_ic/*ACLK] { connect_bd_net $fclk $pin }
connect_bd_net $ic_rst  [get_bd_pins a2_gp0_ic/ARESETN]
connect_bd_net $per_rst [get_bd_pins a2_gp0_ic/S00_ARESETN] [get_bd_pins a2_gp0_ic/M00_ARESETN]

# The Enhanced core exports AXI4 while Zynq-7000 HP ports are AXI3.  A 1x1
# AXI interconnect gives Vivado a supported protocol/ID conversion point rather
# than directly joining mismatched interfaces.  The pristine baseline already
# enables HP2 and clocks S_AXI_HP2_ACLK from FCLK1.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 a2_hp2_ic
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells a2_hp2_ic]
connect_bd_intf_net [get_bd_intf_pins a2_app/M_AXI_MEM] [get_bd_intf_pins a2_hp2_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins a2_hp2_ic/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP2]
foreach pin [get_bd_pins -quiet a2_hp2_ic/*ACLK] { connect_bd_net $fclk $pin }
connect_bd_net $ic_rst  [get_bd_pins a2_hp2_ic/ARESETN]
connect_bd_net $per_rst [get_bd_pins a2_hp2_ic/S00_ARESETN] [get_bd_pins a2_hp2_ic/M00_ARESETN]

# Native companion link and explicit daemon-controlled Apple-bus readiness.
connect_bd_net [get_bd_pins a2_spi/spi_sclk] [get_bd_pins a2_app/legacy_spi_sck]
connect_bd_net [get_bd_pins a2_spi/spi_cs_n] [get_bd_pins a2_app/legacy_spi_cs_n]
connect_bd_net [get_bd_pins a2_spi/spi_mosi] [get_bd_pins a2_app/legacy_spi_mosi]
connect_bd_net [get_bd_pins a2_spi/spi_miso] [get_bd_pins a2_app/legacy_spi_miso]
connect_bd_net [get_bd_pins a2_spi/host_ready] [get_bd_pins a2_app/ps_host_ready]

# Preserve SPI IRQ capability as IRQ_F2P[0]; all unused fabric IRQ bits are 0.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 a2_irq_concat
set_property -dict [list CONFIG.NUM_PORTS {16}] [get_bd_cells a2_irq_concat]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 a2_irq_zero
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells a2_irq_zero]
connect_bd_net [get_bd_pins a2_spi/irq] [get_bd_pins a2_irq_concat/In0]
for {set i 1} {$i < 16} {incr i} {
    connect_bd_net [get_bd_pins a2_irq_zero/dout] [get_bd_pins a2_irq_concat/In${i}]
}
connect_bd_net [get_bd_pins a2_irq_concat/dout] [get_bd_pins $ps/IRQ_F2P]

# Export only the A2 application pins; the original PS board interfaces remain.
foreach spec {
    {a2_app/J5 J5}
    {a2_app/J6 J6}
    {a2_app/clk_50 clk_50}
    {a2_app/hdmi_clk_p hdmi_clk_p}
    {a2_app/hdmi_clk_n hdmi_clk_n}
    {a2_app/hdmi_data_p hdmi_data_p}
    {a2_app/hdmi_data_n hdmi_data_n}
} {
    lassign $spec pin pname
    set p [get_bd_pins -quiet $pin]
    if {[llength $p] == 0} { error "A2 external pin not found: $pin" }
    make_bd_pins_external $p
    set net [lindex [get_bd_nets -quiet -of_objects $p] 0]
    set port [lindex [get_bd_ports -quiet -of_objects $net] 0]
    if {$port eq ""} { error "Could not externalize $pin" }
    set_property name $pname $port
}

proc a2_find_slave_segment {cell} {
    set segs [get_bd_addr_segs -quiet ${cell}/*/*]
    if {[llength $segs] == 0} { set segs [get_bd_addr_segs -quiet /${cell}/*/*] }
    if {[llength $segs] == 0} { error "No AXI slave segment found for $cell" }
    return [lindex $segs 0]
}
set spi_seg [a2_find_slave_segment a2_spi]
assign_bd_address -offset 0x43C40000 -range 256K $spi_seg
# Assign the HP2 DDR map into a2_app's master address space.
assign_bd_address

validate_bd_design
save_bd_design
puts "INFO: Smart-Zynq A2 BD overlay rebuilt: HP2 DDR + native SPI @ 0x43C40000"
