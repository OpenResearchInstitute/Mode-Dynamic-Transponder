################################################################################
# run_chain_opv.tcl
# Vivado 2022.2 xsim script for the OPV decode-oracle capture.
#
# DUT: halfband_decimator + haifuraiya_channelizer_top (20 Msps input path)
# TB : tb_chain_opv.vhd -- captures ONLY raw bin 59 (channel 5) as "I Q" text.
#
# BEFORE sourcing: from a shell in sim/, generate the stimulus (needs numpy
# and your opv-cxx-demod build):
#     python3 gen_opv20_stim.py --bin <path-to-opv-cxx-demod>/bin --frames 10
# The stimulus is ~18M lines (~220 MB); the runner copies it into the xsim
# run dir. Sim time is ~900 ms of design time -- expect a MULTI-HOUR wall
# clock run. Kick it off and walk away.
#
# PREDICTION (bit-exact golden model, validated against this RTL):
#   chan5_iq.txt decodes via convert_chan_iq.py + opv-demod -c -R 625000 to
#   exactly 10 frames, 5 perfect, LOCKED, AFC 0.0 Hz -- identical bytes to
#   the model run, because the sample streams are integer-identical.
#
# USAGE (Vivado TCL console, from sim/):  source run_chain_opv.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

foreach v {opv20_stim.txt} {
    if {![file exists $v]} {
        puts "ERROR: missing stimulus $v -- run gen_opv20_stim.py from a shell and re-source"
        return
    }
}

set project_name "chain_opv_sim"
set project_dir  "./chain_opv_sim_project"
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
    ../rtl/channelizer/fft_pkg.vhd
    ../rtl/resampler/halfband_taps_pkg.vhd
    ../rtl/resampler/halfband_decimator.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/r2sdf_stage.vhd
    ../rtl/channelizer/r2sdf_reorder.vhd
    ../rtl/channelizer/r2sdf_fft.vhd
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
}

puts "\nAdding TB..."
safe_add_files sim_1 { tb_chain_opv.vhd }

# tb_chain_opv uses std.env.finish -> VHDL-2008
set_property FILE_TYPE {VHDL 2008} [get_files tb_chain_opv.vhd]

set_property top tb_chain_opv [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1500 ms} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"

# two passes: +tone then -tone. File IO in xsim resolves in the run dir,
# so the stimulus is copied in and the capture copied back out per pass.
puts "
==================== OPV decode capture ===================="
set_property generic \
    [list STIM_FILE=opv20_stim.txt OUT_FILE=chan5_iq.txt SMP_PERIOD=5] \
    [get_filesets sim_1]
file mkdir $sim_run_dir
file copy -force opv20_stim.txt $sim_run_dir/
launch_simulation
run all
file copy -force $sim_run_dir/chan5_iq.txt .
close_sim -force

puts "
Done. chan5_iq.txt is in sim/. From a shell:"
puts "  python3 convert_chan_iq.py chan5_iq.txt chan5_iq.cs16"
puts "  opv-demod -c -R 625000 < chan5_iq.cs16"
puts "  python3 check_opv_bitexact.py opv20_stim.txt chan5_iq.txt   (optional)"
