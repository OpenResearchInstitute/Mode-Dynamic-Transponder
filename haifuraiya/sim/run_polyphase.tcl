################################################################################
# run_polyphase.tcl
# Vivado 2022.2 xsim script for the dual-oracle polyphase filterbank testbench.
#
# DUT: polyphase_filterbank_parallel (+ haifuraiya_coeffs_pkg)  rtl/channelizer/
# TB:  tb_polyphase_filterbank.vhd                               this sim/ dir
# Oracles: (1) channel-0 unity DC gain in hardware = commutator direction sane
#          (2) bit-exact branch outputs vs golden/vectors/poly_{input,expected}.txt
#
# The vector generator ALSO runs a coefficient PROVENANCE check comparing the
# .hex (design intent) against the compiled-in .vhd package (what synthesizes).
# Watch its output: any "PROVENANCE DEFECT" line means those two sources have
# drifted and must be reconciled by regenerating from polyphase_channelizer.ipynb.
# The golden model tracks the .vhd (shipped) values, so this TB proves the RTL
# LOGIC independent of that provenance question.
#
# USAGE (Vivado TCL console, from the sim/ directory):
#   source run_polyphase.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

if {![catch {exec python3 golden/gen_polyphase_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: vector regen reported nonzero (often just the provenance defect):"
    puts $genlog
}

set vec_dir "[file normalize golden/vectors]/"
puts "VEC_DIR = $vec_dir"

# Hard check: the TB reads these two text files. They are committed to the repo;
# the regen above is only a convenience (and now needs no numpy). If they are
# missing, stop here with a clear message instead of launching a doomed sim.
foreach v {poly_input.txt poly_expected.txt} {
    if {![file exists golden/vectors/$v]} {
        puts "ERROR: golden/vectors/$v not found."
        puts "       Commit the vector files to haifuraiya/sim/golden/vectors/,"
        puts "       or run: python3 golden/gen_polyphase_vectors.py"
        return -code error "missing vector $v"
    }
}

set project_name "poly_sim"
set project_dir  "./poly_sim_project"
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
    ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_polyphase_filterbank.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_polyphase_filterbank [get_filesets sim_1]
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {100 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {poly_input.txt poly_expected.txt poly_dcbin.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'PASS: polyphase_filterbank bit-exact to golden model AND channel-0 unity DC gain'"
puts "Also review the PROVENANCE section printed by the generator above."
puts "========================================"
