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
# Debug variant (VCK190_ILA=1 in the environment; `make vck190-xsa-ila`):
# a System ILA on the soft-bit path (rx -> widen -> DMA S2MM).  Separate
# project dir, XSA and reports so the working image is never overwritten.
set with_ila [expr {[info exists ::env(VCK190_ILA)] && $::env(VCK190_ILA) ne "0"}]
# Tier (VCK190_TIER in the environment; `make vck190-project-esi` / `vck190-xsa-esi`):
#   1 (default) memory loopback, the receiver fed straight from the pacer
#   2           ESIstream digital loopback: Teledyne's TX/RX around a real GTY
#               quad in near-end PMA loopback, between the pacer and the
#               receiver (rtl/esi/esi_link_hw.vhd; ESISTREAM_NOTES.md section 4.2)
# Separate project dir, XSA and reports per tier, so the tier-1 image is never
# overwritten by a tier-2 build.
set tier [expr {[info exists ::env(VCK190_TIER)] ? $::env(VCK190_TIER) : 1}]
if {$tier ni {1 2}} { error "VCK190_TIER must be 1 or 2 (got '$tier')" }
if {$tier == 2} { append project_name "_esi" }
if {$with_ila} { append project_name "_ila" }
puts "INFO: tier $tier -> project $project_name"

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
# (axi_mon_tap.vhd left the tree 2026-11-02; the manifest count follows)
safe_add_files sources_1 {
    ../rtl/axis_sample_pacer.vhd
    ../rtl/axis_softbit_tap.vhd
    ../../../syn/zcu102_with_adrv9001/axis_softbit_widen.vhd
}
set n_expected 35
set module_ref_tops {haifuraiya_rx_axi.vhd axis_sample_pacer.vhd axis_softbit_widen.vhd axis_softbit_tap.vhd}

# --- tier 2: Teledyne e2v's ESIstream TX/RX (public domain, vendored under
# third_party/esistream_vck190/ -- see README_ORI.md there) and our splice
# (rtl/esi/).  The same list the sim runner uses, plus the hardware wrapper.
# The real rx_xpm_async_fifo (XPM) is used; Vivado has XPM.
if {$tier == 2} {
    set esi ../../../third_party/esistream_vck190
    if {![file exists [file normalize [file join $script_dir $esi/src_pkg/esistream_pkg_64b.vhd]]]} {
        error "tier 2 needs the Teledyne ESIstream package extracted under third_party/esistream_vck190/ (README_ORI.md)"
    }
    safe_add_files sources_1 [list \
        $esi/src_pkg/esistream_pkg_64b.vhd \
        $esi/src_common/two_flop_synchronizer.vhd \
        $esi/src_common/ff_synchronizer_array.vhd \
        $esi/src_rx/rx_delay.vhd \
        $esi/src_rx/rx_xpm_async_fifo.vhd \
        $esi/src_rx/rx_xpm_output_buffer.vhd \
        $esi/src_rx/rx_frame_alignment.vhd \
        $esi/src_rx/rx_lfsr_init.vhd \
        $esi/src_rx/rx_decoding.vhd \
        $esi/src_rx/rx_lane_decoding.vhd \
        $esi/src_rx/rx_control.vhd \
        $esi/src_rx/rx_esistream.vhd \
        $esi/src_tx/tx_lfsr.vhd \
        $esi/src_tx/tx_scrambling.vhd \
        $esi/src_tx/tx_disparity_word_16b.vhd \
        $esi/src_tx/tx_disparity.vhd \
        $esi/src_tx/tx_encoding.vhd \
        $esi/src_tx/tx_esistream.vhd \
        ../rtl/esi/esi_loop_pkg.vhd \
        ../rtl/esi/esi_sample_packer.vhd \
        ../rtl/esi/esi_sample_reassembler.vhd \
        ../rtl/esi/esi_link_loop.vhd \
        ../rtl/esi/esi_link_hw.vhd \
    ]
    incr n_expected 23
    lappend module_ref_tops esi_link_hw.vhd
    # GT reference clock pins, lane pins, the GT clocks as asynchronous to the PL clock
    add_files -fileset constrs_1 -norecurse [file normalize [file join $script_dir vck190_esi_link.xdc]]
    # after the GT IP's own constraints, so the clock names it creates exist
    set_property PROCESSING_ORDER LATE [get_files vck190_esi_link.xdc]
}

set n_added [llength [get_files -of_objects [get_filesets sources_1]]]
if {$n_added != $n_expected} {
    error "source manifest short ($n_added/$n_expected) -- see SKIP lines (submodules initialized?)"
}
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sources_1]]

# module-reference tops must be plain VHDL (the flow's rule, not ours);
# everything they instantiate stays VHDL 2008
set_property file_type {VHDL} [get_files $module_ref_tops]

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
    set rpt_sfx [expr {$tier == 2 ? "_esi" : ""}][expr {$with_ila ? "_ila" : ""}]
    report_timing_summary -file [file join $script_dir "timing_summary${rpt_sfx}.rpt"]
    report_utilization    -file [file join $script_dir "utilization${rpt_sfx}.rpt"]
    write_hw_platform -fixed -include_bit -force -file [file join $script_dir "${project_name}.xsa"]
    if {$with_ila} {
        # probes file for the Hardware Manager (open_hw -> refresh with this .ltx)
        write_debug_probes -force [file join $script_dir "${project_name}.ltx"]
        puts "INFO: wrote ${project_name}.ltx (ILA probes)"
    }
    puts "INFO: wrote ${project_name}.xsa, timing_summary${rpt_sfx}.rpt, utilization${rpt_sfx}.rpt"
} else {
    puts "INFO: project built; re-run with -tclargs build for synth/impl/xsa"
}
