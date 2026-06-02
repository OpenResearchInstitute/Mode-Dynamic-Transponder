################################################################################
# run_halfband_decimator_test.tcl
# Vivado 2022.2 simulation script for the halfband decimator unit testbench.
#
# DUT:   halfband_decimator  (rtl/resampler/)
# Check: self-checking against golden vectors from the Python model
#        (tb_input.txt / tb_expected.txt). Reports PASS/FAIL and stops.
#
# USAGE (from the Vivado TCL console, run from the sim/ directory):
#   source run_halfband_decimator_test.tcl
#
# The vector files tb_input.txt and tb_expected.txt must sit next to this
# script (in sim/). They are copied into the xsim working dir below, the same
# way the channelizer run copies its coefficient .hex files.
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

set project_name "halfband_decimator_sim"
set project_dir  "./halfband_decimator_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

if {[file exists $project_dir]} { file delete -force $project_dir }

puts "========================================"
puts "Halfband Decimator Unit Testbench"
puts "Part: $part_name"
puts "Dir:  [pwd]"
puts "========================================"

create_project $project_name $project_dir -part $part_name

proc safe_add_files {fileset file_list {library "work"}} {
    foreach file $file_list {
        if {[file exists $file]} {
            add_files -fileset $fileset -norecurse $file
            puts "  OK   $file"
        } else {
            puts "  SKIP $file (not found)"
        }
    }
}

# RTL: package before the module that uses it.
puts "\nAdding RTL..."
safe_add_files sources_1 {
    ../rtl/resampler/halfband_taps_pkg.vhd
    ../rtl/resampler/halfband_decimator.vhd
}

puts "\nAdding testbench..."
safe_add_files sim_1 {
    ./tb_halfband_decimator.vhd
}

# VHDL-2008 for everything (the TB uses std.env.stop and textio).
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}

# Golden vectors must be in the xsim working dir where the TB opens them.
puts "\nCopying golden vectors to xsim working dir..."
set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach vec {tb_input.txt tb_expected.txt} {
    if {[file exists ./$vec]} {
        file copy -force ./$vec $sim_run_dir
        puts "  OK Copied: $vec -> $sim_run_dir"
    } else {
        puts "  WARN missing vector file: $vec (TB will fail to open it)"
    }
}

set_property top tb_halfband_decimator [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2 ms} \
    -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation
restart
run all

puts "\n========================================"
puts "Look for: 'PASS: decimator is bit-exact to the golden model'"
puts "========================================"
