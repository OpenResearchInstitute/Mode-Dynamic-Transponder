################################################################################
# run_halfband_decimator.tcl
# Vivado 2022.2 xsim script for the dual-oracle halfband decimator testbench.
#
# DUT:    halfband_decimator            (rtl/resampler/)
# TB:     tb_halfband_decimator.vhd     (this sim/ dir)
# Oracles: (1) analytic  - unity DC gain, in-TB
#          (2) bit-exact - vs golden/vectors/hb_{input,expected}.txt
#
# USAGE (from the Vivado TCL console, run from the sim/ directory):
#   source run_halfband_decimator.tcl
#
# File paths are handled by passing the absolute vectors directory to the TB as
# generic VEC_DIR, so it does not matter that xsim runs from a nested project
# dir. As a fallback (in case a given xsim build ignores the string generic) the
# vectors are ALSO copied into the xsim run dir, where VEC_DIR="" would find
# them. Vectors are regenerated from the model if python3 is available; they are
# committed too, so python is not required to run this.
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# --- regenerate golden vectors from the model (optional; committed anyway) ---
if {![catch {exec python3 golden/gen_halfband_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped vector regen (python3 not on path); using committed vectors"
}

set vec_dir "[file normalize golden/vectors]/"     ;# trailing slash required
puts "VEC_DIR = $vec_dir"

set project_name "halfband_decimator_sim"
set project_dir  "./halfband_decimator_sim_project"
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
    ../rtl/resampler/halfband_taps_pkg.vhd
    ../rtl/resampler/halfband_decimator.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_halfband_decimator.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_halfband_decimator [get_filesets sim_1]
# PRIMARY: hand the TB the absolute vectors path.
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2 ms} -objects [get_filesets sim_1]

# FALLBACK: also drop the vectors in the run dir (VEC_DIR="" would find them).
set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {hb_input.txt hb_expected.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'PASS: halfband_decimator bit-exact to golden model AND unity DC gain'"
puts "========================================"
