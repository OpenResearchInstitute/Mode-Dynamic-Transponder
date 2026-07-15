################################################################################
# run_channelizer_top.tcl
# Vivado 2022.2 xsim script for the dual-oracle channelizer_top bench.
#
# DUT (rtl/channelizer/):
#   haifuraiya_coeffs_pkg, fir_branch_parallel, polyphase_filterbank_parallel,
#   r2sdf_stage, r2sdf_reorder, r2sdf_fft, haifuraiya_channelizer_top
# TB:  tb_channelizer_top.vhd    (this sim/ dir)
#
# Oracle 2 (bit-exact): settled frame CAP_IDX of each burst == composed golden
#   model (channelizer_top_model = proven polyphase + FFT leaves + P2S bi+j*bq +
#   (-j)^(k*m) rotation), channel_re/channel_im 40-bit.
# Oracle 1 (empirical MAP): each tone burst's dominant OUTPUT channel (energy
#   summed over settled frames) is reported and asserted == model. Demonstrates
#   the k -> (N-k) reversal on real RTL (DC and Nyquist are fixed points).
#
# Samples driven one every 10 clocks (10 MSps @ 100 MHz) so the P2S drains --
# driving every clock makes the filterbank outrun the P2S and drop frames.
#
# USAGE (Vivado TCL console, from sim/):  source run_channelizer_top.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

if {![catch {exec python3 golden/gen_channelizer_top_vectors.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped/failed vector regen (using committed vectors):"
    puts $genlog
}

set vec_dir "[file normalize golden/vectors]/"
puts "VEC_DIR = $vec_dir"
foreach v {ct_sweep_input.txt ct_sweep_expected.txt} {
    if {![file exists golden/vectors/$v]} {
        return -code error "missing vector $v (run golden/gen_channelizer_top_vectors.py)"
    }
}

set project_name "channelizer_top_sim"
set project_dir  "./channelizer_top_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

proc safe_add_files {fileset file_list} {
    foreach f $file_list {
        if {[file exists $f]} { add_files -fileset $fileset -norecurse $f; puts "  OK   $f" } \
        else                  { puts "  SKIP $f (not found)" }
    }
}

puts "\nAdding RTL (dependency order)..."
safe_add_files sources_1 {
    ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../rtl/channelizer/fir_branch_parallel.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/r2sdf_stage.vhd
    ../rtl/channelizer/r2sdf_reorder.vhd
    ../rtl/channelizer/r2sdf_fft.vhd
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
}
puts "\nAdding testbench..."
safe_add_files sim_1 { ./tb_channelizer_top.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_channelizer_top [get_filesets sim_1]
set_property generic "VEC_DIR=$vec_dir" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1000 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $sim_run_dir
foreach v {ct_sweep_input.txt ct_sweep_expected.txt} {
    if {[file exists golden/vectors/$v]} { file copy -force golden/vectors/$v $sim_run_dir }
}

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for the printed input->output channel map (k -> N-k) and"
puts "'CHANNELIZER_TOP TB PASSED (bit-exact + empirical k->(N-k) map)'"
puts "========================================"
