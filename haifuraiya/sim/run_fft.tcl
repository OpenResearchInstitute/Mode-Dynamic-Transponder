################################################################################
# run_fft.tcl
# Vivado 2022.2 xsim script for the dual-oracle R2SDF FFT testbench.
#
# DUT: r2sdf_fft (+ r2sdf_stage, r2sdf_reorder)   rtl/channelizer/
# TB:  tb_r2sdf_fft.vhd                            this sim/ dir
# Oracles: (1) channel ordering / reversal detector  (+k->k, -k->N-k)
#          (2) bit-exact vs golden/vectors/fft_{input,expected,peaks}.txt,
#              with an out_idx natural-order cross-check.
#
# USAGE (from the Vivado TCL console, run from the sim/ directory):
#   source run_fft.tcl
#
# Vectors path is handed to the TB via generic VEC_DIR (absolute, from this
# script's location) so xsim's nested run dir does not matter; vectors are also
# copied into the run dir as a fallback. Regenerated from the model if python3
# is present; committed too, so python is not required.
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

if {![catch {exec python3 golden/gen_fft_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped vector regen (python3 not on path); using committed vectors"
}

set vec_dir "[file normalize golden/vectors]/"
puts "VEC_DIR = $vec_dir"

set project_name "fft_sim"
set project_dir  "./fft_sim_project"
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
    ../rtl/channelizer/r2sdf_stage.vhd
    ../rtl/channelizer/r2sdf_reorder.vhd
    ../rtl/channelizer/r2sdf_fft.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_r2sdf_fft.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_r2sdf_fft [get_filesets sim_1]
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {100 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {fft_input.txt fft_expected.txt fft_peaks.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'PASS: r2sdf_fft bit-exact to golden model AND channel ordering correct'"
puts "========================================"
