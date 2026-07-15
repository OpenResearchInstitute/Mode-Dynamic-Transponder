################################################################################
# run_channel_eq.tcl
# Vivado 2022.2 xsim script for the dual-oracle channel_eq testbench.
#
# DUT: channel_eq (+ channel_gain_pkg)        rtl/resampler/
# TB:  tb_channel_eq.vhd                       this sim/ dir
# Oracles: (2) bit-exact vs golden/vectors/eq_{input,expected}.txt, plus
#              out_chan (TDEST) integrity;  (1) saturation clamp exercised.
#
# Vectors are committed; the generator regen is a convenience (numpy-free) and
# also runs a PROVENANCE check that the shipped gain ROM equals docs/channel_eq.py.
#
# USAGE (Vivado TCL console, from the sim/ directory):
#   source run_channel_eq.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# help the generator/model find the shipped gain package and the named model
set ::env(CEQ_PKG) "[file normalize ../rtl/resampler/channel_gain_pkg.vhd]"

if {![catch {exec python3 golden/gen_channel_eq_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped/failed vector regen (using committed vectors):"
    puts $genlog
}

set vec_dir "[file normalize golden/vectors]/"
puts "VEC_DIR = $vec_dir"

foreach v {eq_input.txt eq_expected.txt} {
    if {![file exists golden/vectors/$v]} {
        puts "ERROR: golden/vectors/$v not found. Commit the vectors or run"
        puts "       python3 golden/gen_channel_eq_vectors.py"
        return -code error "missing vector $v"
    }
}

set project_name "channel_eq_sim"
set project_dir  "./channel_eq_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

proc safe_add_files {fileset file_list} {
    foreach f $file_list {
        if {[file exists $f]} { add_files -fileset $fileset -norecurse $f; puts "  OK   $f" } \
        else                  { puts "  SKIP $f (not found)" }
    }
}

puts "\nAdding RTL..."
safe_add_files sources_1 {
    ../rtl/resampler/channel_gain_pkg.vhd
    ../rtl/resampler/channel_eq.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_channel_eq.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_channel_eq [get_filesets sim_1]
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {60 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {eq_input.txt eq_expected.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'PASS: channel_eq bit-exact to golden model, TDEST-correct gain, saturation clamps'"
puts "========================================"
