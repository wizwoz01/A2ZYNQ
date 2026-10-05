# A2ZYNQ: build the Smart Zynq SP bitstream from scratch (Vivado 2024.2).
#
#   vivado -mode batch -source boards/a2n20v2-SmartZynq/vivado/build.tcl
#
# It needs the Xillinux evaluation kit for the Smart Zynq SP, which is not part
# of this repository (see third_party/README.md). By default the kit is expected
# in third_party/xillinux-eval-SmartZynq-SP-1.0b; set A2ZYNQ_XILLINUX to point
# at another copy. The Vivado project is created inside the kit (verilog/vivado,
# replaced on every run); the bitstream and reports go to
# boards/a2n20v2-SmartZynq/build/. A full build takes about 30-40 minutes.
#
# The sources are used exactly as they are in this repository: nothing is
# regenerated or patched on the way in.

set a2_board [file normalize [file join [file dirname [info script]] ..]]
set a2_root  [file normalize [file join $a2_board .. ..]]
set xbase    [file normalize [file join $a2_root third_party xillinux-eval-SmartZynq-SP-1.0b]]
if {[info exists ::env(A2ZYNQ_XILLINUX)] && $::env(A2ZYNQ_XILLINUX) ne ""} {
    set xbase [file normalize $::env(A2ZYNQ_XILLINUX)]
}
set xscript    [file join $xbase verilog xillydemo-vivado.tcl]
set working_bd [file join $xbase vivado-essentials vivado_system vivado_system.bd]
set pristine_bd "$working_bd.pristine"
foreach f [list $xscript $working_bd] {
    if {![file exists $f]} { error "Xillinux kit not found ($f). See third_party/README.md." }
}
set outdir [file join $a2_board build]
file mkdir $outdir
puts "INFO: A2ZYNQ repository: $a2_root"
puts "INFO: Xillinux kit:      $xbase"

# Every build rewrites the kit's block design. Keep the kit's original beside it
# the first time, and start from that copy every time after.
if {![file exists $pristine_bd]} { file copy $working_bd $pristine_bd }
file copy -force $pristine_bd $working_bd
file delete -force [file join $xbase verilog vivado]

# The kit's own script creates the stock Xillinux project.
cd [file dirname $xscript]
source $xscript
if {[current_project -quiet] eq ""} {
    open_project [file join [file dirname $xscript] vivado xillydemo.xpr]
}
set_property source_mgmt_mode All [current_project]

# Smart Zynq wrapper RTL (board top, application, bus PHY, SPI transport).
set rtl_files [lsort -unique [concat \
    [glob -nocomplain [file join $a2_board rtl *.v]] \
    [glob -nocomplain [file join $a2_board rtl *.sv]] \
    [glob -nocomplain [file join $a2_board rtl generated *.v]] \
    [glob -nocomplain [file join $a2_board rtl generated *.sv]]]]
if {[llength $rtl_files] == 0} { error "No Smart Zynq RTL found in $a2_board/rtl" }
add_files -norecurse $rtl_files

# The A2FPGA core (hdl/) and the board's top level (boards/.../hdl).
source [file join $a2_board vivado sources.tcl]
set enhanced_top [file join $a2_board hdl top.sv]
if {[llength [get_files -quiet $enhanced_top]] == 0} { add_files -norecurse $enhanced_top }
set_property file_type SystemVerilog [get_files $enhanced_top]
foreach unused {top_fb.sv top_dualrate.sv} {
    set f [get_files -quiet [file join $a2_board hdl $unused]]
    if {[llength $f]} { set_property is_enabled false $f }
}

# SystemVerilog headers, and upstream .v files that are really SystemVerilog.
set svh_files {}
foreach base [list [file join $a2_root hdl] [file join $a2_board hdl] [file join $a2_board rtl]] {
    set raw [string trim [exec find $base -type f -name "*.svh"]]
    if {$raw ne ""} { foreach h [split $raw "\n"] { lappend svh_files [file normalize $h] } }
}
foreach h [lsort -unique $svh_files] {
    if {[llength [get_files -quiet $h]] == 0} { add_files -norecurse $h }
    set_property file_type {SystemVerilog Header} [get_files $h]
}
foreach base [list [file join $a2_root hdl] [file join $a2_board hdl]] {
    set raw_v [string trim [exec find $base -type f -name "*.v"]]
    if {$raw_v ne ""} {
        foreach vf [split $raw_v "\n"] {
            set obj [get_files -quiet [file normalize $vf]]
            if {[llength $obj]} { set_property file_type SystemVerilog $obj }
        }
    }
}

# Select the Smart Zynq branch of the core.
set defs [get_property verilog_define [current_fileset]]
if {[lsearch -exact $defs SMART_ZYNQ] < 0} { lappend defs SMART_ZYNQ }
set_property verilog_define $defs [current_fileset]

# Board pins and Apple-bus electrical rules, SPI clocking, synthesis stability.
set cdir [file join $a2_board vivado constraints]
add_files -fileset constrs_1 -norecurse [file join $cdir smart_zynq_sp_a2_vectors.xdc]
add_files -fileset constrs_1 -norecurse [file join $cdir smart_zynq_spi_axi_relax.xdc]
set spi_clk_tcl [file join $cdir smart_zynq_spi_clock.tcl]
add_files -fileset constrs_1 -norecurse $spi_clk_tcl
set_property used_in_synthesis false [get_files $spi_clk_tcl]
set synth_xdc [file join $cdir smart_zynq_synth_stability.xdc]
add_files -fileset constrs_1 -norecurse $synth_xdc
set_property USED_IN_IMPLEMENTATION false [get_files $synth_xdc]
update_compile_order -fileset sources_1

# Put the A2 application into the Xillinux block design in place of its demo.
source [file join $a2_board vivado scripts patch_exact_xillinux_bd.tcl]
set bd [lindex [get_files -quiet */vivado_system.bd] 0]
if {$bd eq ""} { error "vivado_system.bd disappeared after the patch" }
# Global synthesis mode: the Apple-bus tri-states only merge into pad IOBUFs
# when the application is synthesized in the same netlist as the top ports.
set_property -quiet synth_checkpoint_mode None $bd
generate_target all $bd

set board_top [file join $a2_board rtl smart_zynq_board_top.v]
if {[llength [get_files -quiet $board_top]] == 0} { add_files -norecurse $board_top }
set_property top smart_zynq_board_top [current_fileset]
update_compile_order -fileset sources_1

# Vivado 2024.2 settings this design needs (see docs/BUILDING.md): the mux
# restructuring workaround in synth_pre.tcl, more than one thread (one thread
# deadlocks), FSM extraction off.
set threads 2
if {[info exists ::env(A2_VIVADO_THREADS)] && $::env(A2_VIVADO_THREADS) ne ""} { set threads $::env(A2_VIVADO_THREADS) }
set_param general.maxThreads $threads
set synth_run [get_runs synth_1]
set_property strategy {Vivado Synthesis Defaults} $synth_run
set_property STEPS.SYNTH_DESIGN.TCL.PRE [file join $a2_board vivado scripts synth_pre.tcl] $synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE Default $synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION off $synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS false $synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING auto $synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt $synth_run
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
# Post-route physical optimization. The design sits close to the 100 MHz
# limit in the SPI master, and placement moves a little with every change;
# this recovers the occasional few-tens-of-ps miss instead of failing the build.
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
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
set jobs 4
if {[info exists ::env(A2_IMPL_JOBS)] && $::env(A2_IMPL_JOBS) ne ""} { set jobs $::env(A2_IMPL_JOBS) }
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $outdir timing_summary.rpt]
report_utilization -file [file join $outdir utilization.rpt]
report_drc -file [file join $outdir drc.rpt]
set bit [lindex [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]] 0]
if {$bit eq ""} { error "No bitstream was produced" }
file copy -force $bit [file join $outdir xillydemo.bit]
puts "A2ZYNQ_BUILD_OK: [file join $outdir xillydemo.bit]"
exit 0
