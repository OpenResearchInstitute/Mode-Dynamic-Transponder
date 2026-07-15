################################################################################
# run_chain_tone.tcl
# Vivado 2022.2 xsim script for the bare-channelizer tone verification bench.
#
# DUT (rtl/channelizer/):
#   haifuraiya_coeffs_pkg, polyphase_filterbank_parallel, r2sdf_stage,
#   r2sdf_reorder, r2sdf_fft, haifuraiya_channelizer_top
# TB:  tb_chain_tone.vhd    (this sim/ dir)
#
# Measures four properties of the core with two complex tones:
#   1. production input path at 20 Msps: halfband (20->10) then channelizer
#   2. signal check: +791.25 kHz -> channel 5, offset preserved
#   3. alias fold: +5.16625 MHz crosses the 10 Msps boundary into channel 33
#   4. alias rejection vs the direct ch33 reference tone
#
# GHDL 4.1.0 measured reference (2026-07-14, files as received):
#   +791.25 kHz -> ch 5, tone +10.5 kHz; alias probe -> ch 33 at 9.18 dB
#   below the direct reference (analytic |H| ratio predicts 9.18 dB)
#
# USAGE (Vivado TCL console, from sim/):  source run_chain_tone.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# regenerate tone stimuli (falls back to committed files on failure)
if {![catch {exec /usr/bin/python3 gen_chain_stim.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped/failed stimulus regen (using committed files):"
    puts $genlog
}
foreach v {tone20_p.txt tone20_alias.txt tone20_ref33.txt} {
    if {![file exists $v]} {
        puts "ERROR: missing stimulus $v -- run the gen script from a shell and re-source"
        return
    }
}

set project_name "chain_tone_sim"
set project_dir  "./chain_tone_sim_project"
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
safe_add_files sim_1 { tb_chain_tone.vhd }

# tb_chain_tone uses std.env.finish -> VHDL-2008
set_property FILE_TYPE {VHDL 2008} [get_files tb_chain_tone.vhd]

set_property top tb_chain_tone [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2000 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"

# two passes: +tone then -tone. File IO in xsim resolves in the run dir,
# so the stimulus is copied in and the capture copied back out per pass.
foreach pass {p alias ref33} {
    puts "\n==================== tone_${pass} ===================="
    set_property generic \
        [list STIM_FILE=tone20_${pass}.txt OUT_FILE=chain_out_${pass}.txt SMP_PERIOD=5] \
        [get_filesets sim_1]
    file mkdir $sim_run_dir
    file copy -force tone20_${pass}.txt $sim_run_dir/
    launch_simulation
    run all
    file copy -force $sim_run_dir/chain_out_${pass}.txt .
    close_sim -force
}

puts "\nAnalyzing..."
if {![catch {exec /usr/bin/python3 analyze_tone.py} alog]} {
    puts $alog
} else {
    puts "analyze_tone.py could not run inside Vivado (its bundled python"
    puts "shadows the system one). From a shell in sim/:  python3 analyze_tone.py"
    puts $alog
}
puts "\nDone. Captures: chain_out_p/alias/ref33.txt (in sim/)."
