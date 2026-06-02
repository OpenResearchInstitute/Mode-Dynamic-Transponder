################################################################################
# run_channel_eq_test.tcl
# Vivado 2022.2 simulation script for the channel EQ unit testbench.
#
# DUT:   channel_eq  (rtl/resampler/)
# Check: self-checking against golden vectors from the Python model
#        (eq_input.txt / eq_expected.txt). Reports PASS/FAIL and stops.
#
# USAGE (from the Vivado TCL console, run from the sim/ directory):
#   source run_channel_eq_test.tcl
#
# The vector files eq_input.txt and eq_expected.txt must sit next to this
# script (in sim/); they are copied into the xsim working dir below.
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

set project_name "channel_eq_sim"
set project_dir  "./channel_eq_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

if {[file exists $project_dir]} { file delete -force $project_dir }

puts "========================================"
puts "Channel EQ Unit Testbench"
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
    ../rtl/resampler/channel_gain_pkg.vhd
    ../rtl/resampler/channel_eq.vhd
}

puts "\nAdding testbench..."
safe_add_files sim_1 {
    ./tb_channel_eq.vhd
}

foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}

puts "\nCopying golden vectors to xsim working dir..."
set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach vec {eq_input.txt eq_expected.txt} {
    if {[file exists ./$vec]} {
        file copy -force ./$vec $sim_run_dir
        puts "  OK Copied: $vec -> $sim_run_dir"
    } else {
        puts "  WARN missing vector file: $vec (TB will fail to open it)"
    }
}

set_property top tb_channel_eq [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1 ms} \
    -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation
restart
run all

puts "\n========================================"
puts "Look for: 'PASS: channel_eq is bit-exact to the golden model'"
puts "========================================"
