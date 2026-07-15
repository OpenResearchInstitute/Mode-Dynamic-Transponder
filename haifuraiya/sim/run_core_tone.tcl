################################################################################
# run_core_tone.tcl
# Vivado 2022.2 xsim script for the bare-channelizer tone verification bench.
#
# DUT (rtl/channelizer/):
#   haifuraiya_coeffs_pkg, polyphase_filterbank_parallel, r2sdf_stage,
#   r2sdf_reorder, r2sdf_fft, haifuraiya_channelizer_top
# TB:  tb_core_tone.vhd    (this sim/ dir)
#
# Measures four properties of the core with two complex tones:
#   1. bin mapping: +781.25 kHz -> raw bin 59 -> relabeled channel 5
#   2. adjacent-channel rejection at the probe offset
#   3. oversampled-output derotation: +10 kHz in-channel stays +10 kHz
#      (a missing/wrong-sign (-j)^(k*m) shows up at +/-156.25 kHz)
#   4. conjugation: the in-bin tone keeps its sign (+in -> +out)
#
# Runs the +791.25 kHz and -791.25 kHz stimuli back to back, copies the
# capture files back to sim/, and runs analyze_tone.py.
#
# GHDL 4.1.0 measured reference (2026-07-14, files as received):
#   +791.25 kHz: raw bin 59 -> ch 5, next bin -35.5 dB, in-bin tone +10.1 kHz
#   -791.25 kHz: raw bin  5 -> ch 59, in-bin tone -10.1 kHz, 0 dropped frames
#
# USAGE (Vivado TCL console, from sim/):  source run_core_tone.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# regenerate tone stimuli (falls back to committed files on failure)
if {![catch {exec /usr/bin/python3 gen_tone_stim.py} genlog]} {
    puts $genlog
} else {
    puts "NOTE: skipped/failed stimulus regen (using committed files):"
    puts $genlog
}
foreach v {tone_p.txt tone_m.txt} {
    if {![file exists $v]} {
        puts "ERROR: missing stimulus $v -- run the gen script from a shell and re-source"
        return
    }
}

set project_name "core_tone_sim"
set project_dir  "./core_tone_sim_project"
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
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/r2sdf_stage.vhd
    ../rtl/channelizer/r2sdf_reorder.vhd
    ../rtl/channelizer/r2sdf_fft.vhd
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
}

puts "\nAdding TB..."
safe_add_files sim_1 { tb_core_tone.vhd }

# tb_core_tone uses std.env.finish -> VHDL-2008
set_property FILE_TYPE {VHDL 2008} [get_files tb_core_tone.vhd]

set_property top tb_core_tone [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2000 us} -objects [get_filesets sim_1]

set sim_run_dir "$project_dir/$project_name.sim/sim_1/behav/xsim"

# two passes: +tone then -tone. File IO in xsim resolves in the run dir,
# so the stimulus is copied in and the capture copied back out per pass.
foreach pass {p m} {
    puts "\n==================== tone_${pass} ===================="
    set_property generic \
        [list STIM_FILE=tone_${pass}.txt OUT_FILE=chan_out_${pass}.txt SMP_PERIOD=10] \
        [get_filesets sim_1]
    file mkdir $sim_run_dir
    file copy -force tone_${pass}.txt $sim_run_dir/
    launch_simulation
    run all
    file copy -force $sim_run_dir/chan_out_${pass}.txt .
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
puts "\nDone. Captures: chan_out_p.txt, chan_out_m.txt (in sim/)."
