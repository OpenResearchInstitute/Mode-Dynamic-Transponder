################################################################################
# impl_haifuraiya_channelizer.tcl
#
# Run implementation (opt_design, place_design, route_design) on the OOC
# channelizer that was previously synthesized by
# synth_haifuraiya_channelizer.tcl.
#
# Stops AFTER route_design.  Does NOT generate a bitstream because this
# module is OOC (no top-level I/O pin constraints, no clock buffer); a
# bitstream is only meaningful when this block is instantiated inside a
# full Zynq block design.  What we want here is the post-route timing
# numbers to confirm that the synth-stage 9.68 ns data path delay
# survives routing.
#
# Run from the haifuraiya/syn/zcu102/ directory:
#   vivado -mode tcl
#   source impl_haifuraiya_channelizer.tcl
#
# (or from inside an existing Vivado Tcl Console)
################################################################################

set this_script [info script]
set syn_dir     [file dirname [file normalize $this_script]]
set project_dir [file join $syn_dir synth_project]
set xpr_file    [file join $project_dir haifuraiya_channelizer_synth.xpr]

if {![file exists $xpr_file]} {
    puts "============================================"
    puts "ERROR: Project file not found at"
    puts "  $xpr_file"
    puts ""
    puts "Run synth_haifuraiya_channelizer.tcl first to"
    puts "create the OOC synthesis project."
    puts "============================================"
    return
}

# Open the project that synth created
if {[catch {current_project} _]} {
    open_project $xpr_file
} else {
    puts "Using already-open project: [current_project]"
}

# Make sure synth is actually complete; impl needs the synth checkpoint
set synth_state [get_property PROGRESS [get_runs synth_1]]
if {$synth_state != "100%"} {
    puts "============================================"
    puts "ERROR: synth_1 is not complete (progress = $synth_state)"
    puts "Run synth_haifuraiya_channelizer.tcl first."
    puts "============================================"
    return
}

# --- OOC-specific impl configuration ---
# Skip bitstream generation; we have no I/O pin assignments and no clock
# buffer, so write_bitstream would fail.  The point of this run is the
# post-route timing report, not a downloadable bitstream.
set_property STEPS.WRITE_BITSTREAM.IS_ENABLED false [get_runs impl_1]

# Reset impl_1 in case a previous attempt left it in an intermediate
# state, so this run starts fresh from the synth_1 checkpoint.
if {[get_property PROGRESS [get_runs impl_1]] != "0%"} {
    puts "Resetting impl_1 (was at [get_property PROGRESS [get_runs impl_1]])"
    reset_run impl_1
}

puts ""
puts "============================================"
puts "LAUNCHING IMPLEMENTATION"
puts "  Steps : opt_design -> place_design -> route_design"
puts "  Skip  : write_bitstream (OOC sub-block)"
puts "  Part  : [get_property PART [current_project]]"
puts "============================================"
puts ""

# -to_step route_design halts cleanly after routing.  Implementation
# typically takes 5x-15x longer than synth for a design this size.
launch_runs impl_1 -to_step route_design
wait_on_runs impl_1

set impl_state    [get_property STATUS   [get_runs impl_1]]
set impl_progress [get_property PROGRESS [get_runs impl_1]]
puts ""
puts "Implementation state: $impl_state ($impl_progress)"

if {$impl_progress != "100%"} {
    puts "============================================"
    puts "IMPLEMENTATION DID NOT COMPLETE"
    puts "Inspect the impl_1 log in"
    puts "  $project_dir/haifuraiya_channelizer_synth.runs/impl_1"
    puts "for errors."
    puts "============================================"
    return
}

open_run impl_1

set runs_dir [file join $project_dir haifuraiya_channelizer_synth.runs impl_1]
puts ""
puts "--- Writing post-route reports to $runs_dir ---"

report_utilization                        -file $runs_dir/impl_utilization.rpt
report_utilization -hierarchical          -file $runs_dir/impl_utilization_hier.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
                                          -file $runs_dir/impl_timing_summary.rpt
report_timing -max_paths 20 -nworst 20 -delay_type max -sort_by group \
                                          -file $runs_dir/impl_timing_worst_paths.rpt
report_clock_interaction                  -file $runs_dir/impl_clock_interaction.rpt
report_clock_utilization                  -file $runs_dir/impl_clock_utilization.rpt
report_drc                                -file $runs_dir/impl_drc.rpt
report_power                              -file $runs_dir/impl_power.rpt

puts ""
puts "============================================"
puts "IMPLEMENTATION COMPLETE"
puts "============================================"
puts "Reports in: $runs_dir"
puts ""

set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
puts "  WNS (post-route): $wns ns"
puts "  TNS (post-route): $tns ns"
puts ""
puts "If WNS still comes back blank (the OOC HD.CLK_SRC issue we"
puts "haven't fully chased down), the real post-route data path"
puts "delay is in:"
puts "  impl_timing_summary.rpt"
puts "Look at the 'Max Delay Paths' section.  Target: < 10 ns to"
puts "close 100 MHz."
puts "============================================"
