# Vivado 2024.2 synthesis optimizer workaround, applied inside the synthesis
# process.
#
# Vivado 2024.2 segfaults on this design in the mux-chain collapsing pass:
#
#   HARTHOptDfg::optimizePass2 -> HOptDfg::earlyMuxRestructuring
#     -> muxCollapseOpt::doMuxCollapse -> collectMuxChainsToBeCollapsed
#     -> muxChain::analyzeEquivalency -> DFPin::calcConstantInt (recursing)
#     -> DFNode::calcConstantBSel   <-- SIGSEGV
#
# No documented synth_design switch reaches that pass: -flatten_hierarchy none,
# -fsm_extraction off, -no_lc, keep_hierarchy and use_dsp=no were all tried and
# all still crash. The pass is reachable only as an internal Rodin engine
# parameter, and synth.elaboration.rodinMoreOptions is the sole supported hook
# for setting those.
#
# launch_runs spawns a separate Vivado process, so this file is registered as
# STEPS.SYNTH_DESIGN.TCL.PRE to guarantee the parameter lands in the process
# that actually runs synth_design.
#
#   A2_RODIN_OPTS  override the clause list (';'-separated), for bisecting
#                  which parameter is the effective one.

set a2_rodin_default "rt::set_parameter earlyMuxRestructuring false"

set a2_rodin_opts $a2_rodin_default
if {[info exists ::env(A2_RODIN_OPTS)]} {
    # Deliberately allow an empty value, so a baseline run can be requested.
    set a2_rodin_opts $::env(A2_RODIN_OPTS)
}

if {[string trim $a2_rodin_opts] eq ""} {
    puts "INFO: A2 rodinMoreOptions disabled (baseline run)"
} else {
    set a2_rodin_existing [get_param synth.elaboration.rodinMoreOptions]
    if {[string trim $a2_rodin_existing] eq ""} {
        set a2_rodin_combined $a2_rodin_opts
    } else {
        set a2_rodin_combined "$a2_rodin_existing; $a2_rodin_opts"
    }
    if {[catch {
        set_param synth.elaboration.rodinMoreOptions $a2_rodin_combined
    } a2_rodin_err]} {
        puts "WARNING: could not set rodinMoreOptions: $a2_rodin_err"
    } else {
        puts "INFO: A2 rodinMoreOptions = [get_param synth.elaboration.rodinMoreOptions]"
    }
}
