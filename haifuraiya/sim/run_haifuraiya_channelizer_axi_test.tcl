################################################################################
# run_haifuraiya_channelizer_axi_test.tcl
# Vivado 2022.2 simulation script for the Haifuraiya channelizer AXI wrapper
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    haifuraiya_channelizer_axi
# Scope:  AXI-Lite control plane + AXI-Stream wiring smoke test
#         (does not re-run the 6-test channelizer regression; that lives
#          in run_haifuraiya_channelizer_test.tcl against the bare core)
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/sim/run_haifuraiya_channelizer_axi_test.tcl
#
################################################################################

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

set project_name "haifuraiya_chan_axi_sim"
set project_dir  "./haifuraiya_axi_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

# Create clean project
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "Haifuraiya Channelizer AXI Wrapper Testbench"
puts "Project:    $project_name"
puts "Part:       $part_name (ZCU102)"
puts "Working dir: [pwd]"
puts "========================================"

create_project $project_name $project_dir -part $part_name

# Helper - skip files that don't exist on disk and log them
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

# --- Synthesizable RTL (production sources) ---
# Order is important for some VHDL-2008 dependency analyzers; the synth
# tools generally figure it out from elaboration but listing in dep order
# makes the simulator's job easier.

puts "\nAdding synthesizable RTL..."
safe_add_files sources_1 {
    ../third_party/lowpass_ema/src/lowpass_ema.vhd
    ../third_party/power_detector/src/power_detector.vhd
    ../rtl/channelizer/fft_pkg.vhd
    ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/r2sdf_stage.vhd
    ../rtl/channelizer/r2sdf_reorder.vhd
    ../rtl/channelizer/r2sdf_fft.vhd
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
    ../rtl/axi/axi_lite_regs.vhd
    ../rtl/resampler/halfband_taps_pkg.vhd
    ../rtl/resampler/halfband_decimator.vhd
    ../rtl/resampler/channel_gain_pkg.vhd
    ../rtl/resampler/channel_eq.vhd
    ../rtl/channelizer/channel_normalizer_mux.vhd
    ../rtl/axi/haifuraiya_channelizer_axi.vhd
    ../third_party/pluto_msk/nco/src/sin_cos_lut.vhd
    ../third_party/pluto_msk/nco/src/nco.vhd
    ../third_party/pluto_msk/pi_controller/src/pi_controller.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_lock_detect.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_loop.vhd
    ../third_party/pluto_msk/msk_demodulator/src/msk_demodulator.vhd
    ../third_party/pluto_msk/src/frame_sync_detector_soft.vhd
    ../rtl/rx/haifuraiya_demod_regs.vhd
    ../rtl/rx/channel_normalizer.vhd
    ../rtl/rx/haifuraiya_rx_top.vhd
    ../rtl/rx/haifuraiya_rx_axi.vhd
}

# --- Testbench ---
puts "\nAdding testbench..."
safe_add_files sim_1 {
    ./tb_haifuraiya_channelizer_axi.vhd
}

# Set VHDL-2008 language for all of our files
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}

# Stage the OPV I/Q stimulus into the xsim working dir (read by p_stim's file
# playback). Kept in sim/ so it survives the project delete/recreate above.
#set stim_file [file join [file dirname [info script]] "tone_minus.txt"]
set stim_file [file join [file dirname [info script]] "opv_chan_stim.txt"]
#set stim_file [file join [file dirname [info script]] "opv_chan_stim.txt"]
#set stim_file [file join [file dirname [info script]] "cw_tone_27k_10msps.txt"]


# Pick the testbench as top-level for simulation
set_property top tb_haifuraiya_channelizer_axi [get_filesets sim_1]

# Reasonable simulation runtime - the testbench's stim process drives
# everything explicitly and calls finish, so this is just an upper bound.
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]

# Stage the stimulus into the xsim run dir (the tb opens it by relative name)
set xsim_dir [file join $project_dir ${project_name}.sim sim_1 behav xsim]
file mkdir $xsim_dir
file copy -force $stim_file $xsim_dir
puts "  OK staged [file tail $stim_file] -> $xsim_dir"

puts "\nLaunching simulation..."
launch_simulation


puts "\n========================================"
puts "Simulation launched. Check the xsim console output for test"
puts "PASS/FAIL summary, or:"
puts "  - 'ALL TESTS PASSED' note -> green"
puts "  - 'TESTS FAILED' error    -> investigate"
puts "========================================"


################################################################################
# Waveform layout -- collapsible groups in SIGNAL-FLOW order:
#
#   TB_Control                bench progress / counters
#   Control_Plane_Channelizer AXI-Lite enable of the channelizer
#   Control_Plane_Demod       AXI-Lite init bracket of the demod
#   Channelizer_Input         s_axis burst going in
#   Channel_Numbering         *** the k -> (N-k) relabel fix -- watch this ***
#   Channelizer_Output        the AXI burst coming out (TDEST + TLAST)
#   Demod_Input               the one channel demux'd to the demod
#   Demod_Carrier_CORDIC      carrier recovery (CORDIC phase discriminator)
#   Demod Carrier Recovery
#   Demod_SymbolLock          per-tone symbol lock (real, process-driven)
#   Demod_Telemetry_rewire    old stubbed ports -- alive after you rewire them
#   Bit_Decisions             soft/hard bits out of the demod
#   Frame_Sync                sync-word correlation + frame lock
#
# Hierarchy: u_rx = rx_axi, u_rx/u_rx = rx_top, u_rx/u_rx/u_chan = channelizer_axi.
################################################################################

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
#   chan_idx_int   = raw index from channelizer_top  (bin order, 0..63)
#   chan_idx_int_r = AFTER the relabel  (should be (N - int) mod N)
#   eq_chan        = index carried to TDEST / CHANNEL_POWER
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
#   Correlate chans_tdata magnitude vs chans_tdest: the big beat = the tone's
#   channel. chan_last / chans_tlast must pulse ONCE per 64-beat frame.
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
add_wave -into {Demod_Input} -radix unsigned $DEM/discard_rxnco





################################################################################
# waves_normalizer.tcl
#
# Waveform groups for the per-channel normalizer, in the style of
# run_haifuraiya_channelizer_axi_test.tcl.
#
# To use, add ONE line to run_haifuraiya_channelizer_axi_test.tcl, right after
#
#     set FS   $RX/u_fsync
#
# namely
#
#     source [file join [file dirname [info script]] waves_normalizer.tcl]
#
# Groups appear in creation order. Put the source line wherever you want these
# groups to land relative to the existing ones.
#
# NOTE: the Normalizer_Seam group probes $CHAN/norm_*, which exist only after
# the normalizer insertion patch has been applied.
#
# Signal flow:
#
#   eq_valid / eq_chan / eq_re / eq_im       one channel per beat
#      +--> power_detector                    measures power BEFORE the gain
#      +--> u_norm                            applies the gain
#             +--> m_axis_chans               out to the demod
#
#   gain = GAIN_TARGET / sqrt(max(power, SQUELCH_THR))
#      p = m * 2^e             -> s1_p, s2_e
#      gain = TARGET*rom >> sh -> s3_rom, s3_sh, s4_gain
#
# IN BYPASS (gain_mode = '0'), check three things:
#   1. s4_gain reads 1024 (0x0400) at all times
#   2. gain_sat never asserts
#   3. out_i equals in_i delayed exactly 5 clocks
################################################################################

set NORM $CHAN/u_norm

# --- channelizer control plane, decoded --------------------------------------
add_wave_group {Channelizer_Registers}
add_wave -into {Channelizer_Registers}                 $CHAN/ctrl_enable
add_wave -into {Channelizer_Registers}                 $CHAN/ctrl_soft_reset
add_wave -into {Channelizer_Registers}                 $CHAN/core_reset
add_wave -into {Channelizer_Registers} -radix unsigned $CHAN/ctrl_output_shift
add_wave -into {Channelizer_Registers} -radix unsigned $CHAN/ctrl_alpha1
add_wave -into {Channelizer_Registers} -radix unsigned $CHAN/ctrl_alpha2
add_wave -into {Channelizer_Registers} -radix unsigned $CHAN/stat_frame_count
add_wave -into {Channelizer_Registers} -radix unsigned $CHAN/stat_dropped_frames

# --- power detector: the normalizer's only input -----------------------------
# Measured on the UN-normalized equalizer output. Sense before, correct after.
# dbg_pd0_ema_2 is channel 0, the LO-leakage DC spike: it shows the detector is
# alive. It is not a level to judge anything by.
add_wave_group {Power_Detector}
add_wave -into {Power_Detector}                 $CHAN/pd_data_ena
add_wave -into {Power_Detector} -radix unsigned $CHAN/dbg_pd0_ema_2

# --- normalizer boundary -----------------------------------------------------
add_wave_group {Normalizer}
add_wave -into {Normalizer}                 $NORM/in_valid
add_wave -into {Normalizer} -radix unsigned $NORM/in_chan
add_wave -into {Normalizer}                 $NORM/in_last
add_wave -into {Normalizer} -radix dec      $NORM/in_i
add_wave -into {Normalizer} -radix dec      $NORM/in_q
add_wave -into {Normalizer} -radix unsigned $NORM/power
add_wave -into {Normalizer}                 $NORM/gain_mode
add_wave -into {Normalizer} -radix unsigned $NORM/gain_target
add_wave -into {Normalizer} -radix unsigned $NORM/squelch_thr
add_wave -into {Normalizer} -radix hex      $NORM/gain_manual
add_wave -into {Normalizer} -radix unsigned $NORM/gain_current
add_wave -into {Normalizer}                 $NORM/gain_sat
add_wave -into {Normalizer}                 $NORM/out_valid
add_wave -into {Normalizer} -radix unsigned $NORM/out_chan
add_wave -into {Normalizer}                 $NORM/out_last
add_wave -into {Normalizer} -radix dec      $NORM/out_i
add_wave -into {Normalizer} -radix dec      $NORM/out_q

# --- normalizer internals ----------------------------------------------------
# s2_e and s3_sh are VHDL integers: no radix.
add_wave_group {Normalizer_Pipeline}
add_wave -into {Normalizer_Pipeline} -radix unsigned $NORM/s1_p
add_wave -into {Normalizer_Pipeline}                 $NORM/s2_e
add_wave -into {Normalizer_Pipeline} -radix unsigned $NORM/s3_rom
add_wave -into {Normalizer_Pipeline}                 $NORM/s3_sh
add_wave -into {Normalizer_Pipeline} -radix unsigned $NORM/s4_gain
add_wave -into {Normalizer_Pipeline}                 $NORM/sat_r

# --- the seam: eq in, normalizer out, AXIS out -------------------------------
add_wave_group {Normalizer_Seam}
add_wave -into {Normalizer_Seam}                 $CHAN/eq_valid
add_wave -into {Normalizer_Seam} -radix unsigned $CHAN/eq_chan
add_wave -into {Normalizer_Seam} -radix dec      $CHAN/eq_re
add_wave -into {Normalizer_Seam} -radix dec      $CHAN/eq_im
add_wave -into {Normalizer_Seam}                 $CHAN/chan_last_d
add_wave -into {Normalizer_Seam}                 $CHAN/norm_valid
add_wave -into {Normalizer_Seam} -radix unsigned $CHAN/norm_chan
add_wave -into {Normalizer_Seam}                 $CHAN/norm_last
add_wave -into {Normalizer_Seam} -radix dec      $CHAN/norm_i
add_wave -into {Normalizer_Seam} -radix dec      $CHAN/norm_q

# --- Demod carrier recovery -- dual Costas loops (per-tone PI, restored) ------
add_wave_group {Demod_Carrier}
add_wave -into {Demod_Carrier} -radix dec $DEM/f1_nco_adjust  ;# f1 carrier freq correction (settles at lock)
add_wave -into {Demod_Carrier} -radix dec $DEM/lpf_accum_f1   ;# f1 carrier phase integrator
add_wave -into {Demod_Carrier} -radix dec $DEM/f1_error       ;# f1 loop error (shrinks at lock)
add_wave -into {Demod_Carrier} -radix dec $DEM/f2_nco_adjust  ;# f2 carrier freq correction
add_wave -into {Demod_Carrier} -radix dec $DEM/lpf_accum_f2   ;# f2 carrier phase integrator

# --- Demod symbol TIMING -- fractional NCO + discriminants (the new path) -----
add_wave_group {Demod_Timing}
add_wave -into {Demod_Timing}                 $DEM/tclk       ;# symbol strobe into integrate-and-dump
add_wave -into {Demod_Timing}                 $DEM/tclk_nco   ;# fractional-NCO strobe (SYM_SPS_FP path)
add_wave -into {Demod_Timing} -radix unsigned $DEM/sym_ph     ;# symbol-phase accumulator (16.16)
add_wave -into {Demod_Timing}                 $DEM/dclk       ;# symbol-clock discriminant (sign)
add_wave -into {Demod_Timing} -radix dec      $DEM/dclk_slv   ;# signed timing discriminant (future TED source)
add_wave -into {Demod_Timing}                 $DEM/cclk       ;# carrier/data discriminant (sign)
add_wave -into {Demod_Timing} -radix dec      $DEM/data_sum   ;# f1-f2 integrated -> soft, pre-differential

# --- Demod symbol lock -- BOTH tones now observable -------------------------
add_wave_group {Demod_SymbolLock}
add_wave -into {Demod_SymbolLock}            $DEM/cst_lock_f1
add_wave -into {Demod_SymbolLock}            $DEM/cst_lock_f2
add_wave -into {Demod_SymbolLock} -radix dec $DEM/dbg_acc_iq_delta_f1 ;# f1 LOCK METRIC (aif1-aqf1)
add_wave -into {Demod_SymbolLock} -radix dec $DEM/f2_error            ;# f2 LOCK METRIC (aif2-aqf2)
add_wave -into {Demod_SymbolLock} -radix dec $DEM/dbg_acc_i_f1        ;# f1 in-phase energy
add_wave -into {Demod_SymbolLock} -radix dec $DEM/dbg_acc_q_f1        ;# f1 quadrature energy
add_wave -into {Demod_SymbolLock} -radix dec $DEM/f2_nco_adjust       ;# f2 in-phase energy
add_wave -into {Demod_SymbolLock} -radix dec $DEM/lpf_accum_f2        ;# f2 quadrature energy

# --- bit decisions -- the ACTUAL demod output (is it emitting symbols?) ------
#   rx_dvalid should pulse at the symbol rate once the FSM reaches S_RUN;
#   rx_data_soft is the soft metric that swings with the data.
add_wave_group {Bit_Decisions}
add_wave -into {Bit_Decisions}            $DEM/rx_data
add_wave -into {Bit_Decisions} -radix dec $DEM/rx_data_soft
add_wave -into {Bit_Decisions}            $DEM/rx_dvalid

# --- frame sync -------------------------------------------------------------
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


################################################################################
# Timing_Search -- coarse timing acquisition visibility (S_SEARCH)
#
# dbg_setot[0..11] IS the energy-vs-sampling-phase curve: |ee1-ee2| summed over
# NSRCH symbols at each 1-sample candidate phase. dbg_search_phase is the phase
# the search picked (argmax). Read it after dbg_search_done rises:
#   - SHARP peak, phase lands on it  -> coarse timing is fine; the ~5.5 dB is
#     NOT timing acquisition -- keep hunting the missing gain elsewhere.
#   - FLAT / ambiguous / noisy curve -> the metric can't resolve phase; the
#     search is landing badly -> timing IS the loss, build the S_RUN TED loop.
#
# If u_demod wraps msk_demodulator (u_demod/u_core), set MSK accordingly.
################################################################################
#set MSK $DEM
# set MSK $DEM/u_core    ;# uncomment if msk_demodulator is one level down

#add_wave_group {Timing_Search}
#add_wave -into {Timing_Search}                 $MSK/dbg_search_done
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_search_phase
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_search_best
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_0
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_1
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_2
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_3
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_4
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_5
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_6
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_7
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_8
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_9
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_10
#add_wave -into {Timing_Search} -radix unsigned $MSK/dbg_setot_11


run all
