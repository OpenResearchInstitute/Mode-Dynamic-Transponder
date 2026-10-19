################################################################################
# run_mdt_vck190_sim.tcl
# Vivado project bootstrap for the MDT core on the VCK190 (Versal VC1902)
#
# Open Research Institute
# Project: Mode-Dynamic Transponder (Haifuraiya configuration) VCK190 shell
# Target:  VCK190 eval board (xcvc1902-vsva2197-2MP-e-S)
# Tools:   Vivado 2022.2, VHDL-2008
# License: CERN-OHL-S-2.0
#
# Location: haifuraiya/platforms/vck190/sim/  (paths below assume this)
#
# ------------------------------------------------------------------------------
# DOCTRINE
# ------------------------------------------------------------------------------
# One core, two shells. The signal-processing core (haifuraiya/rtl/) is the
# same source that the ZCU102 runs. 
# Everything VCK190-specific lives under haifuraiya/platforms/vck190/. 
# The ZCU102 build is the working reference.
#
# This script is built part by part. Each PART below is complete and runs good
# before the next is added. Later parts assume earlier ones succeeded.
#
#   PART 1  project bootstrap: environment gate, create project, target part
#   PART 2  source manifest: core RTL via safe_add_files
#   PART 3  testbench + VHDL-2008 properties + stimulus staging
#   PART 4  (pending) launch_simulation + waveform layout
#
# USAGE (from the Vivado TCL console on chococat):
#   source /path/to/haifuraiya/platforms/vck190/sim/run_mdt_vck190_sim.tcl
#
# PREREQUISITES
#   - Submodules initialized (sim set only):
#       git submodule update --init haifuraiya/third_party/power_detector \
#                                   haifuraiya/third_party/lowpass_ema
#   - Stimulus generated (Part 3 stages it; see sim/opv_stim.py --out)
################################################################################

################################################################################
# PART 1 -- project bootstrap
################################################################################

# --- environment gate --------------------------------------------------------
# Baseline is Vivado 2022.2. The ESIstream VCK190 package carries board ref
# vck190:part0:2.2 (measured from the package project script, 2026-10), which
# is satisfied by the 2022.x board store. Other versions may work; this gate
# WARNS loudly rather than just dying, so an intentional version experiment is
# possible, but the warning goes in the log where it cannot be unseen.
set EXPECTED_VIVADO "2022.2"
set this_vivado [version -short]
if {![string match "${EXPECTED_VIVADO}*" $this_vivado]} {
    puts "*** WARNING ********************************************************"
    puts "*** Vivado $this_vivado, baseline is $EXPECTED_VIVADO."
    puts "*** Proceeding, but any anomaly is suspect #1: re-run on $EXPECTED_VIVADO"
    puts "*** before filing a bug against the RTL."
    puts "********************************************************************"
}

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

# --- identity ----------------------------------------------------------------
set project_name "mdt_vck190_sim"
set project_dir  "./mdt_vck190_sim_project"

# Part string measured from the ESIstream VCK190 package (script_64b.tcl):
# keeping our target identical to the vendor deliverable's means the two
# projects don't fight too much.
set part_name    "xcvc1902-vsva2197-2MP-e-S"
set board_ref    "xilinx.com:vck190:part0:2.2"

# --- create clean project ----------------------------------------------------
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "MDT core on VCK190 -- simulation project"
puts "Project:     $project_name"
puts "Part:        $part_name (VCK190, Versal VC1902)"
puts "Vivado:      $this_vivado (baseline $EXPECTED_VIVADO)"
puts "Working dir: [pwd]"
puts "========================================"

create_project $project_name $project_dir -part $part_name

# --- board targeting, with gracefull fallback -------------------------------
# The board file matters little for behavioral simulation (the part string is
# what xsim elaborates against) but setting it now means the SAME project
# bootstrap serves the later synthesis and block-design parts, where the board
# file supplies pin and interface presets. If this install's board store lacks
# vck190 2.2, we say so and continue part-only, which is not too bad.
if {[catch {set_property board_part $board_ref [current_project]} msg]} {
    puts "*** NOTE: board_part $board_ref not available in this install."
    puts "***       ($msg)"
    puts "***       Continuing PART-ONLY. Fine for simulation; install the"
    puts "***       VCK190 board files (Vivado XHub store) before the"
    puts "***       synthesis/BD parts of this flow."
    set board_state "part-only"
} else {
    puts "  OK board_part = $board_ref"
    set board_state "board"
}

# --- helper: add files that exist, log the ones that don't --------------------
# Carried over from the ZCU102 flow: a missing file is a loud SKIP in the log,
# and it helped there quite a lot with debugging.
proc safe_add_files {fileset file_list {library "work"}} {
    foreach file $file_list {
        if {[file exists $file]} {
            add_files -fileset $fileset -norecurse $file
            puts "  OK   $file"
        } else {
            puts "  SKIP $file (not found)"
        }
    }
}

puts ""
puts "PART 1 complete: project created ($board_state)."

################################################################################
# PART 2 -- source manifest: the MDT core
################################################################################
# This manifest is the ZCU102 manifest (run_haifuraiya_channelizer_axi_test.tcl)
# re-rooted from haifuraiya/sim/ to haifuraiya/platforms/vck190/sim/ -- three
# levels up instead of one. Same files, same order, verified file-by-file
# against the repo tree (2026-10-14). Differences from the ZCU102 list, both
# deliberate:
#
#   REMOVED  ../rtl/rx/channel_normalizer.vhd
#            Ghost entry: the file exists nowhere in the repo and has SKIPped
#            on every ZCU102 run. The normalizer in service is
#            channel_normalizer_mux.vhd (listed below).
#            (Check: git status haifuraiya/rtl/rx/ on keroppi.)
#
#   ABSENT   third_party/esistream/*
#            Deliberate. Simulation target #1 is the core alone, retargeted to
#            the VC1902, so we have one variable per test. ESIstream sources 
#            join in a later part, when the reassembler/DDC seam exists to 
#            connect them up. 
#
# If a submodule SKIPs below, run the sim-set init and re-source:
#   git submodule update --init haifuraiya/third_party/power_detector \
#                               haifuraiya/third_party/lowpass_ema

puts "\nAdding synthesizable RTL (the core, unmodified)..."
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

# Hard gate: Part 2 is only complete if every core file landed. A SKIP in the
# core manifest means a missing submodule or a moved file, so stop and look,
# don't let elaboration discover it later when things blow up.
set n_added [llength [get_files -of_objects [get_filesets sources_1]]]
set n_expected 31
if {$n_added != $n_expected} {
    puts "*** ERROR: expected $n_expected core files, got $n_added."
    puts "***        Scroll up for SKIP lines. Most likely cause: sim"
    puts "***        submodules not initialized (see PREREQUISITES header)."
    error "PART 2 incomplete: core manifest short ($n_added/$n_expected)"
}

puts ""
puts "PART 2 complete: $n_added core files added."

################################################################################
# PART 3 -- testbench, VHDL-2008 properties, stimulus staging
################################################################################
# The testbench is referenced in place right now from the ZCU102 sim directory, not
# copied. This is on purpose. Simulation target #1 asks "does the proven core + proven
# bench pass unchanged on the VC1902?" So we don't make a new copy until it must 
# genuinely diverge (when the input side becomes ESIstream-shaped).
#
# Stimulus is generated by sim/opv_stim.py and default output is probably still 
# opv_chan_stim_dc.txt, but it isn't the 0 channel necessarily, so don't get confused.

puts "\nAdding testbench (referenced from haifuraiya/sim/, not copied)..."
safe_add_files sim_1 {
    ../../../sim/tb_haifuraiya_channelizer_axi.vhd
}

# Set VHDL-2008 language for all of our files
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
 
# Pick the testbench as top-level for simulation
set_property top tb_haifuraiya_channelizer_axi [get_filesets sim_1]
 
# The testbench's stim process drives everything explicitly and calls finish;
# this is just an upper bound.
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
 
# --- stimulus + LUT staging into the xsim run dir ------------------------------
# Both files are opened by the testbench by RELATIVE name, so they must sit in
# the xsim working directory. The LUT is committed; the stimulus is generated.
set stim_file [file join [file dirname [info script]] ../../../sim/opv_chan_stim.txt]
set lut_file  [file join [file dirname [info script]] ../../../sim/lut16q_hex.txt]
 
if {![file exists $stim_file]} {
    puts "*** ERROR: stimulus not found: $stim_file"
    puts "***"
    puts "***        The OPV stimulus is generated, not committed. Create it:"
    puts "***          cd haifuraiya/sim"
    puts "***          python3 opv_stim.py --out opv_chan_stim.txt"
    puts "***        then re-source this script."
    error "PART 3 incomplete: stimulus file missing (see generator command above)"
}
if {![file exists $lut_file]} {
    error "PART 3 incomplete: lut16q_hex.txt missing from haifuraiya/sim/ (committed file -- check the clone)"
}
 
set xsim_dir [file join $project_dir ${project_name}.sim sim_1 behav xsim]
file mkdir $xsim_dir
file copy -force $stim_file $xsim_dir
puts "  OK staged [file tail $stim_file] -> $xsim_dir"
file copy -force $lut_file $xsim_dir
puts "  OK staged [file tail $lut_file] -> $xsim_dir"
 
puts ""
puts "PART 3 complete: testbench set as top, stimulus staged."

################################################################################
# PART 4 -- simulation launch + waveform layout
################################################################################
# The waveform layout is the ZCU102 layout, unchanged: the bench and DUT
# hierarchy crossed to this platform intact, so every probe path still holds.
# Groups appear in SIGNAL-FLOW order. The normalizer groups live in
# waves_normalizer.tcl beside this script (copied from haifuraiya/sim/ -- a
# LAYOUT file, not a source file, so the no-copy rule doesn't apply; it may
# diverge freely as this platform grows Versal-specific probes).
 
puts "\nLaunching simulation..."
launch_simulation
 
puts "\n========================================"
puts "Simulation launched. Check the xsim console output for test"
puts "PASS/FAIL summary, or:"
puts "  - 'ALL TESTS PASSED' note -> green"
puts "  - 'TESTS FAILED' error    -> investigate"
puts "========================================"
 
# --- waveform layout: signal-flow order ---------------------------------------
set TB   /tb_haifuraiya_channelizer_axi
set RX   $TB/u_rx/u_rx
set CHAN $RX/u_chan
set DEM  $RX/u_demod
set FS   $RX/u_fsync
 
# --- bench progress ---------------------------------------------------------
add_wave_group {TB_Control}
add_wave -into {TB_Control} -radix unsigned $TB/frames_observed
add_wave -into {TB_Control} -radix unsigned $TB/n_target_samps
add_wave -into {TB_Control} -radix unsigned $TB/n_soft_beats
add_wave -into {TB_Control} -radix unsigned $TB/n_soft_frames
add_wave -into {TB_Control} $TB/running
 
# --- control plane: channelizer enable --------------------------------------
add_wave_group {Control_Plane_Channelizer}
add_wave -into {Control_Plane_Channelizer} -radix hex $TB/s_axi_ctrl_awaddr
add_wave -into {Control_Plane_Channelizer} $TB/s_axi_ctrl_awvalid
add_wave -into {Control_Plane_Channelizer} -radix hex $TB/s_axi_ctrl_wdata
add_wave -into {Control_Plane_Channelizer} $TB/s_axi_ctrl_wvalid
add_wave -into {Control_Plane_Channelizer} $TB/s_axi_ctrl_bvalid
 
# --- control plane: demod init bracket --------------------------------------
add_wave_group {Control_Plane_Demod}
add_wave -into {Control_Plane_Demod} -radix hex $TB/s_axi_demod_awaddr
add_wave -into {Control_Plane_Demod} $TB/s_axi_demod_awvalid
add_wave -into {Control_Plane_Demod} $TB/s_axi_demod_awready
add_wave -into {Control_Plane_Demod} -radix hex $TB/s_axi_demod_wdata
add_wave -into {Control_Plane_Demod} $TB/s_axi_demod_wvalid
add_wave -into {Control_Plane_Demod} $TB/s_axi_demod_wready
add_wave -into {Control_Plane_Demod} $TB/s_axi_demod_bvalid
add_wave -into {Control_Plane_Demod} $DEM/init
add_wave -into {Control_Plane_Demod} $DEM/rx_enable
 
# --- channelizer INPUT stream -----------------------------------------------
#   WATCH tready: if tvalid sits high while tready stays low, p_stim is stalled
#   because the core is not accepting samples.
add_wave_group {Channelizer_Input}
add_wave -into {Channelizer_Input}            $TB/s_axis_data_tvalid
add_wave -into {Channelizer_Input}            $TB/s_axis_data_tready
add_wave -into {Channelizer_Input} -radix hex $TB/s_axis_data_tdata
 
# --- CHANNEL NUMBERING: the k -> (N-k) relabel fix --------------------------
#   For a bin-5 tone the tone beat should read: int=59, int_r=5, eq_chan=5.
#   DC (0) and Nyquist (32) are fixed points -- they do NOT move.
add_wave_group {Channel_Numbering}
add_wave -into {Channel_Numbering} -radix unsigned $CHAN/chan_idx_int
add_wave -into {Channel_Numbering} -radix unsigned $CHAN/chan_idx_int_r
add_wave -into {Channel_Numbering} -radix unsigned $CHAN/eq_chan
add_wave -into {Channel_Numbering} $CHAN/chan_valid
add_wave -into {Channel_Numbering} $CHAN/chan_valid_r
add_wave -into {Channel_Numbering} $CHAN/eq_valid
 
# --- channelizer OUTPUT stream: where the energy lands + TLAST ---------------
add_wave_group {Channelizer_Output}
add_wave -into {Channelizer_Output}                 $RX/chans_tvalid
add_wave -into {Channelizer_Output} -radix unsigned $RX/chans_tdest
add_wave -into {Channelizer_Output} -radix hex      $RX/chans_tdata
add_wave -into {Channelizer_Output}                 $RX/chans_tlast
add_wave -into {Channelizer_Output}                 $CHAN/chan_last
 
# --- the one channel demux'd to the demod -----------------------------------
add_wave_group {Demod_Input}
add_wave -into {Demod_Input}                 $RX/rx_svalid
add_wave -into {Demod_Input} -radix hex      $RX/chan_i_reg
add_wave -into {Demod_Input} -radix hex      $RX/chan_q_reg
 
# --- normalizer + register-map groups (separate layout file, as on ZCU102) ---
set waves_norm [file join [file dirname [info script]] waves_normalizer.tcl]
if {[file exists $waves_norm]} {
    source $waves_norm
    puts "  OK sourced waves_normalizer.tcl"
} else {
    puts "  SKIP waves_normalizer.tcl (not found beside this script -- copy it"
    puts "       from haifuraiya/sim/ if the normalizer groups are wanted)"
}
 
# --- elastic store -----------------------------------------------------------
add_wave_group {Elastic_Store}
add_wave -into {Elastic_Store}                 $DEM/rx_svalid
add_wave -into {Elastic_Store} -radix unsigned $DEM/st_wr_ptr_rd
add_wave -into {Elastic_Store} -radix unsigned $DEM/st_fill_ptr
add_wave -into {Elastic_Store} -radix unsigned $DEM/st_fill_lead
add_wave -into {Elastic_Store} -radix unsigned $DEM/st_occ
add_wave -into {Elastic_Store}                 $DEM/store_hold
add_wave -into {Elastic_Store}                 $DEM/st_fill_pend
add_wave -into {Elastic_Store}                 $DEM/st_starve
add_wave -into {Elastic_Store}                 $DEM/st_stomp
 
# --- symbol engine: the timing loop ------------------------------------------
add_wave_group {MLSE_Engine}
add_wave -into {MLSE_Engine} -radix unsigned $DEM/engine/pos
add_wave -into {MLSE_Engine} -radix unsigned $DEM/engine/k
add_wave -into {MLSE_Engine} -radix dec      $DEM/engine/freq
add_wave -into {MLSE_Engine}                 $DEM/e_valid
add_wave -into {MLSE_Engine} -radix dec      $DEM/e_y1r
add_wave -into {MLSE_Engine} -radix dec      $DEM/e_y2r
 
# --- MLSE: per-survivor phase (the four thetas should cluster at lock) -------
add_wave_group {MLSE_Trellis}
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th0
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th1
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th2
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th3
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/dbg_best
add_wave -into {MLSE_Trellis}                 $DEM/m_busy
 
# --- symbol lock detector ----------------------------------------------------
set SL $DEM/u_symlock
add_wave_group {Symbol_Lock}
add_wave -into {Symbol_Lock}                 $DEM/sl_locked
add_wave -into {Symbol_Lock} -radix unsigned $SL/ratio_pct
add_wave -into {Symbol_Lock}                 $SL/window_full
add_wave -into {Symbol_Lock} -radix unsigned $SL/s_num
add_wave -into {Symbol_Lock} -radix unsigned $SL/s_den
add_wave -into {Symbol_Lock} -radix unsigned $SL/fill
add_wave -into {Symbol_Lock} -radix unsigned $SL/wlog_r
add_wave -into {Symbol_Lock} -radix unsigned $DEM/sl_e_early
add_wave -into {Symbol_Lock} -radix unsigned $DEM/sl_e_late
add_wave -into {Symbol_Lock}                 $DEM/sl_e_err_v
add_wave -into {Symbol_Lock} -radix dec      $DEM/sym_clk_offset
 
# --- CFO chain ----------------------------------------------------------------
add_wave_group {CFO}
set CFO $RX/u_cfo
add_wave -into {CFO} -radix dec      $RX/cfo_word
add_wave -into {CFO}                 $CFO/en
add_wave -into {CFO}                 $CFO/out_valid
add_wave -into {CFO} -radix unsigned $CFO/phase
add_wave -into {CFO} -radix dec      $CFO/i_out
add_wave -into {CFO} -radix dec      $CFO/q_out
set AFC $RX/u_demod/u_afc
add_wave -into {CFO} -radix dec      $AFC/est_hz
add_wave -into {CFO} -radix unsigned $AFC/state_o
add_wave -into {CFO} -radix unsigned $AFC/quality
add_wave -into {CFO}                 $AFC/cfo_locked
 
# --- bit decisions: the ACTUAL demod output ----------------------------------
add_wave_group {Bit_Decisions}
add_wave -into {Bit_Decisions}            $DEM/rx_data
add_wave -into {Bit_Decisions} -radix dec $DEM/rx_data_soft
add_wave -into {Bit_Decisions}            $DEM/rx_dvalid
add_wave -into {Bit_Decisions}            $DEM/demod_lock
 
# --- frame sync ---------------------------------------------------------------
add_wave_group {Frame_Sync}
add_wave -into {Frame_Sync}                 $RX/frame_sync_locked
add_wave -into {Frame_Sync} -radix unsigned $RX/frames_received
add_wave -into {Frame_Sync} $FS/debug_corr_peak
add_wave -into {Frame_Sync} $FS/debug_correlation
add_wave -into {Frame_Sync} $FS/debug_state
add_wave -into {Frame_Sync} $FS/debug_consecutive_good
add_wave -into {Frame_Sync} $FS/debug_missed_syncs
add_wave -into {Frame_Sync} $FS/rx_bit
add_wave -into {Frame_Sync} $FS/rx_bit_valid
add_wave -into {Frame_Sync} $FS/demod_sync_lock
add_wave -into {Frame_Sync} $FS/demod_sync_lock_d
add_wave -into {Frame_Sync} $FS/debug_soft_current
add_wave -into {Frame_Sync} $FS/debug_soft_quantized
add_wave -into {Frame_Sync} $FS/corr_prev
add_wave -into {Frame_Sync} $FS/energy_prev

add_wave -into {Frame_Sync} /tb_haifuraiya_channelizer_axi/u_rx/u_rx/afc_frozen_s
add_wave -into {Frame_Sync} /tb_haifuraiya_channelizer_axi/u_rx/u_rx/fsync_lck_s
add_wave -into {Frame_Sync} /tb_haifuraiya_channelizer_axi/u_rx/u_rx/afc_freeze_s

# --- scoreboard + CFO-applied probes ------------------------------------------
add_wave $TB/sb_tvalid
add_wave $TB/sb_tdata
add_wave $TB/sb_tlast
add_wave $RX/cfo_applied
 
run all
 
puts ""
puts "PART 4 complete: simulation ran to the bench's own finish."
