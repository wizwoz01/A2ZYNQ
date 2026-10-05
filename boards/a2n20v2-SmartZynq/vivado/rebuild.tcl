# A2ZYNQ: rebuild the bitstream in the project build.tcl created (Vivado 2024.2).
#
#   vivado -mode batch -source boards/a2n20v2-SmartZynq/vivado/rebuild.tcl
#
# Quicker than build.tcl (about 20-25 minutes): it reopens the existing project
# and re-runs synthesis and implementation on the current sources. Use build.tcl
# after adding or removing a source file (listed in vivado/sources.tcl).

set a2_board [file normalize [file join [file dirname [info script]] ..]]
set a2_root  [file normalize [file join $a2_board .. ..]]
set xbase    [file normalize [file join $a2_root third_party xillinux-eval-SmartZynq-SP-1.0b]]
if {[info exists ::env(A2ZYNQ_XILLINUX)] && $::env(A2ZYNQ_XILLINUX) ne ""} {
    set xbase [file normalize $::env(A2ZYNQ_XILLINUX)]
}
set xpr [file join $xbase verilog vivado xillydemo.xpr]
if {![file exists $xpr]} { error "No project at $xpr: run build.tcl first." }
set outdir [file join $a2_board build]
file mkdir $outdir

open_project $xpr
# The SPI transport is a module reference in the block design: refresh it so
# changes to rtl/axi_spi_master.sv are picked up.
if {[llength [get_ips -quiet vivado_system_a2_spi_0]] > 0} {
    open_bd_design [get_files vivado_system.bd]
    catch {update_module_reference [get_bd_cells -quiet a2_spi]}
    catch {validate_bd_design -force}
    save_bd_design
    catch {generate_target all [get_ips vivado_system_a2_spi_0]}
}
set threads 2
if {[info exists ::env(A2_VIVADO_THREADS)] && $::env(A2_VIVADO_THREADS) ne ""} { set threads $::env(A2_VIVADO_THREADS) }
set_param general.maxThreads $threads
update_compile_order -fileset sources_1
# Same post-route optimization as build.tcl (older projects may not have it).
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
# The Xillinux kit's timing check (showstopper.tcl) is hooked onto route_design,
# which would stop the run before the post-route optimization gets its chance.
# Run it after that step instead, so it still guards the bitstream.
set a2_showstopper [get_property STEPS.ROUTE_DESIGN.TCL.POST [get_runs impl_1]]
if {$a2_showstopper ne ""} {
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.POST $a2_showstopper [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.TCL.POST "" [get_runs impl_1]
}
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_timing_summary -delay_type min_max -file [file join $outdir timing_summary.rpt]
set bit [lindex [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]] 0]
file copy -force $bit [file join $outdir xillydemo.bit]
puts "A2ZYNQ_BUILD_OK: [file join $outdir xillydemo.bit]"
close_project
exit 0
