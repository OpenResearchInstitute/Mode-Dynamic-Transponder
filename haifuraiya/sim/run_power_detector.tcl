################################################################################
# run_power_detector.tcl
# Vivado 2022.2 xsim script for the dual-oracle power_detector testbench.
#
# DUT (git submodules, public ORI repos, CERN-OHL-W, M. Wishek):
#   ../third_party/lowpass_ema/src/lowpass_ema.vhd        @ 280fe847
#   ../third_party/power_detector/src/power_detector.vhd  @ 86bae9a0
#   *** Confirm these SHAs match your pinned submodule commits. If your pins
#       differ, regenerate vectors after checking out your versions. ***
# TB:  tb_power_detector.vhd                               this sim/ dir
#
# Oracles: (2) bit-exact power_squared AND dbg_ema_1 vs golden/vectors/
#              pd_{input,expected}.txt (aligned by a pipeline-latency search);
#          (1) in-hardware hold gating: dbg_ema_1 holds while dbg_ema_1_ena='0'.
# Config:  DATA_W=16, ALPHA_W=18, IQ_MOD, EMA_CASCADE; alpha1=4096, alpha2=64.
#
# NOTE on the GHDL pre-commit gate (sandbox only, not used here): GHDL mcode
# rejects the lowpass_ema saturation-constant aggregates
#   (PROD_W-1 => '0', OTHERS => '1')     -- non-locally-static choice
# so the sandbox uses a two-line patched copy that builds the SAME values
#   SAT_MIN_P := shift_left(to_signed(-1,PROD_W), PROD_W-1);
#   SAT_MAX_P := NOT shift_left(to_signed(-1,PROD_W), PROD_W-1);
# Vivado xsim accepts the ORIGINAL aggregates, so this script uses the
# unmodified submodule sources.
#
# USAGE (Vivado TCL console, from the sim/ directory):
#   source run_power_detector.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# vector regen is a convenience; the generator is numpy-free and self-gates
# (DC-convergence + 51-bit-feedback-trap analytic checks) before emitting.
if {![catch {exec python3 golden/gen_power_detector_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped/failed vector regen (using committed vectors):"
    puts $genlog
}

set vec_dir "[file normalize golden/vectors]/"
puts "VEC_DIR = $vec_dir"

foreach v {pd_input.txt pd_expected.txt} {
    if {![file exists golden/vectors/$v]} {
        puts "ERROR: golden/vectors/$v not found. Commit the vectors or run"
        puts "       python3 golden/gen_power_detector_vectors.py"
        return -code error "missing vector $v"
    }
}

set project_name "power_detector_sim"
set project_dir  "./power_detector_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

proc safe_add_files {fileset file_list} {
    foreach f $file_list {
        if {[file exists $f]} { add_files -fileset $fileset -norecurse $f; puts "  OK   $f" } \
        else                  { puts "  SKIP $f (not found)" }
    }
}

puts "\nAdding RTL (lowpass_ema BEFORE power_detector)..."
safe_add_files sources_1 {
    ../third_party/lowpass_ema/src/lowpass_ema.vhd
    ../third_party/power_detector/src/power_detector.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_power_detector.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_power_detector [get_filesets sim_1]
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {30 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {pd_input.txt pd_expected.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'POWER DETECTOR TB PASSED (bit-exact power_squared + ema_1, hold gating)'"
puts "best latency should report 2, mismatches 0, hold_errs 0."
puts "========================================"
