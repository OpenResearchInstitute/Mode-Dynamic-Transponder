# vck190_playback_project.tcl -- VCK190 playback self-test: Vivado project
#
# STATUS: DRAFT, NOT YET RUN THROUGH VIVADO (2026-10-23).  Companion to
# vck190_playback_bd.tcl.  Builds the project, adds the receiver RTL (the
# same manifest the sim runner uses, unchanged), the two small platform
# blocks, the block design, the wrapper, and -- when asked -- runs
# synthesis/implementation and writes the bitstream and the .xsa that the
# PetaLinux project is built from.
#
# From this directory on chococat (Vivado 2022.2, VCK190 board files):
#   vivado -mode batch -source vck190_playback_project.tcl               ;# project + BD + wrapper only
#   vivado -mode batch -source vck190_playback_project.tcl -tclargs build ;# ... and synth/impl/bitstream/xsa
#
# Paths are relative to THIS script, as in the sim runner.  Additive to the
# repo: nothing under syn/zcu102* or sim/ is modified; the ZCU102 soft-bit
# widener is reused read-only.

set script_dir   [file dirname [file normalize [info script]]]
set project_name "mdt_vck190_playback"
set project_dir  [file join $script_dir "${project_name}_project"]
set part_name    "xcvc1902-vsva2197-2MP-e-S"
set board_ref    "xilinx.com:vck190:part0:2.2"
set do_build     [expr {[llength $argv] > 0 && [lindex $argv 0] eq "build"}]

if {[file exists $project_dir]} {
    puts "Removing stale project dir $project_dir"
    file delete -force $project_dir
}
create_project $project_name $project_dir -part $part_name
if {[catch {set_property board_part $board_ref [current_project]} msg]} {
    error "board_part $board_ref not available: $msg"
}
set_property target_language VHDL [current_project]

proc safe_add_files {fileset file_list} {
    global script_dir
    foreach f $file_list {
        set p [file normalize [file join $script_dir $f]]
        if {[file exists $p]} {
            add_files -fileset $fileset -norecurse $p
        } else {
            puts "  SKIP (missing): $p"
        }
    }
}

# --- the receiver, unchanged: same manifest as ../sim/run_mdt_vck190_sim.tcl
safe_add_files sources_1 {
    ../../../third_party/lowpass_ema/src/lowpass_ema.vhd
    ../../../third_party/power_detector/src/power_detector.vhd
    ../../../rtl/channelizer/fft_pkg.vhd
    ../../../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../../../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../../../rtl/channelizer/r2sdf_stage.vhd
    ../../../rtl/channelizer/r2sdf_reorder.vhd
    ../../../rtl/channelizer/r2sdf_fft.vhd
    ../../../rtl/channelizer/haifuraiya_channelizer_top.vhd
    ../../../rtl/axi/axi_lite_regs.vhd
    ../../../rtl/resampler/halfband_taps_pkg.vhd
    ../../../rtl/resampler/halfband_decimator.vhd
    ../../../rtl/resampler/channel_gain_pkg.vhd
    ../../../rtl/resampler/channel_eq.vhd
    ../../../rtl/channelizer/channel_normalizer_mux.vhd
    ../../../rtl/axi/haifuraiya_channelizer_axi.vhd
    ../../../rtl/rx/msk_symbol_engine.vhd
    ../../../rtl/rx/msk_mlse4.vhd
    ../../../rtl/rx/sym_lock_detector.vhd
    ../../../rtl/rx/cfo_rotator.vhd
    ../../../rtl/rx/cfo_afc.vhd
    ../../../rtl/rx/cfo_pre_da.vhd
    ../../../rtl/rx/msk_demodulator_mlse.vhd
    ../../../rtl/rx/lut16q_pkg.vhd
    ../../../rtl/rx/frame_sync_detector_soft.vhd
    ../../../rtl/rx/haifuraiya_demod_regs.vhd
    ../../../rtl/rx/frame_drop_gate.vhd
    ../../../rtl/rx/axis_async_fifo.vhd
    ../../../rtl/rx/cfo_slew.vhd
    ../../../rtl/rx/cfo_fine.vhd
    ../../../rtl/rx/haifuraiya_rx_top.vhd
    ../../../rtl/rx/haifuraiya_rx_axi.vhd
}
# --- platform blocks (this directory tree) + the ZCU102 widener, read-only reuse
safe_add_files sources_1 {
    ../rtl/axis_sample_pacer.vhd
    ../../../syn/zcu102_with_adrv9001/axis_softbit_widen.vhd
}
set n_added [llength [get_files -of_objects [get_filesets sources_1]]]
if {$n_added != 34} {
    error "source manifest short ($n_added/34) -- see SKIP lines (submodules initialized?)"
}
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sources_1]]
update_compile_order -fileset sources_1

# --- block design
source [file join $script_dir "vck190_playback_bd.tcl"]
make_wrapper -files [get_files playback.bd] -top
add_files -norecurse [file join $project_dir "${project_name}.gen/sources_1/bd/playback/hdl/playback_wrapper.vhd"]
set_property top playback_wrapper [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_files playback.bd]

if {$do_build} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    launch_runs impl_1 -to_step write_device_image -jobs 8
    wait_on_run impl_1
    open_run impl_1
    report_timing_summary -file [file join $script_dir "timing_summary.rpt"]
    report_utilization    -file [file join $script_dir "utilization.rpt"]
    write_hw_platform -fixed -include_bit -force -file [file join $script_dir "${project_name}.xsa"]
    puts "INFO: wrote ${project_name}.xsa, timing_summary.rpt, utilization.rpt"
} else {
    puts "INFO: project built; re-run with -tclargs build for synth/impl/xsa"
}
