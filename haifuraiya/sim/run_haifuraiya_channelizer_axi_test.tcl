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
    ../rtl/channelizer/fir_branch_parallel.vhd
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
    ../rtl/axi/haifuraiya_channelizer_axi.vhd
    ../third_party/pluto_msk/nco/src/sin_cos_lut.vhd
    ../third_party/pluto_msk/nco/src/nco.vhd
    ../third_party/pluto_msk/pi_controller/src/pi_controller.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_lock_detect.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_loop.vhd
    ../third_party/pluto_msk/msk_demodulator/src/msk_demodulator.vhd
    ../third_party/pluto_msk/src/frame_sync_detector_soft.vhd
    ../rtl/rx/haifuraiya_demod_regs.vhd
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
set stim_file [file join [file dirname [info script]] "opv_chan_stim_dc.txt"]
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
# Waveform layout -- collapsible groups, ordered by signal flow (same idiom as
# the standalone msk_modem bench: add_wave_group + add_wave -into).
#
# NEW this round: the Demod_AXI_Init_Bracket group. Watch s_axi_demod_* carry
# the bracket writes and u_demod/init pulse 1->0 -- the step the old bench could
# not perform (the demod slave used to be tied idle).
################################################################################

# --- TB progress / counters -------------------------------------------------
add_wave_group {TB_Control}
add_wave -into {TB_Control} -radix unsigned {/tb_haifuraiya_channelizer_axi/frames_observed}
add_wave -into {TB_Control} -radix unsigned {/tb_haifuraiya_channelizer_axi/n_target_samps}
add_wave -into {TB_Control} -radix unsigned {/tb_haifuraiya_channelizer_axi/n_soft_beats}
add_wave -into {TB_Control} -radix unsigned {/tb_haifuraiya_channelizer_axi/n_soft_frames}
add_wave -into {TB_Control} {/tb_haifuraiya_channelizer_axi/running}

# --- control plane: channelizer AXI-Lite writes -----------------------------
add_wave_group {Channelizer_AXI_Ctrl}
add_wave -into {Channelizer_AXI_Ctrl} -radix hex {/tb_haifuraiya_channelizer_axi/s_axi_ctrl_awaddr}
add_wave -into {Channelizer_AXI_Ctrl} {/tb_haifuraiya_channelizer_axi/s_axi_ctrl_awvalid}
add_wave -into {Channelizer_AXI_Ctrl} -radix hex {/tb_haifuraiya_channelizer_axi/s_axi_ctrl_wdata}
add_wave -into {Channelizer_AXI_Ctrl} {/tb_haifuraiya_channelizer_axi/s_axi_ctrl_wvalid}
add_wave -into {Channelizer_AXI_Ctrl} {/tb_haifuraiya_channelizer_axi/s_axi_ctrl_bvalid}

# --- NEW control plane: demod AXI-Lite init bracket -------------------------
#   cause (AXI writes) + effect (init / rx_enable inside the demod)
add_wave_group {Demod_AXI_Init_Bracket}
add_wave -into {Demod_AXI_Init_Bracket} -radix hex {/tb_haifuraiya_channelizer_axi/s_axi_demod_awaddr}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/s_axi_demod_awvalid}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/s_axi_demod_awready}
add_wave -into {Demod_AXI_Init_Bracket} -radix hex {/tb_haifuraiya_channelizer_axi/s_axi_demod_wdata}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/s_axi_demod_wvalid}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/s_axi_demod_wready}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/s_axi_demod_bvalid}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/init}
add_wave -into {Demod_AXI_Init_Bracket} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_enable}

# --- channelizer INPUT stream: the burst going IN.  WATCH tready: if tvalid
#     sits high while tready stays low, p_stim is stalled at the injection-loop
#     wait (tb line ~1046) because the core is not accepting samples.
add_wave_group {Channelizer_Input}
add_wave -into {Channelizer_Input}            {/tb_haifuraiya_channelizer_axi/s_axis_data_tvalid}
add_wave -into {Channelizer_Input}            {/tb_haifuraiya_channelizer_axi/s_axis_data_tready}
add_wave -into {Channelizer_Input} -radix hex {/tb_haifuraiya_channelizer_axi/s_axis_data_tdata}

# --- channelizer output / channel targeting ---------------------------------
add_wave_group {Channelizer_Output_TDEST}
add_wave -into {Channelizer_Output_TDEST} -radix hex      {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/chans_tdata}
add_wave -into {Channelizer_Output_TDEST} -radix unsigned {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/chans_tdest}
add_wave -into {Channelizer_Output_TDEST}                 {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/chans_tvalid}

# --- samples handed to the demod --------------------------------------------
add_wave_group {Demod_Input}
add_wave -into {Demod_Input}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/rx_svalid}
add_wave -into {Demod_Input} -radix hex {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/chan_i_reg}
add_wave -into {Demod_Input} -radix hex {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/chan_q_reg}
add_wave -into {Demod_Input} -radix unsigned {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/discard_rxnco}

# --- Costas carrier recovery (f1 & f2) --------------------------------------
add_wave_group {Costas_Loops}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/lpf_accum_f1}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/lpf_accum_f2}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/f1_error}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/f2_error}
add_wave -into {Costas_Loops} -radix hex {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/f1_nco_adjust}
add_wave -into {Costas_Loops} -radix hex {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/f2_nco_adjust}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/cst_lock_f1}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/cst_lock_f2}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbg_acc_i_f1}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbg_acc_q_f1}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbg_acc_iq_delta_f1}

# --- Costas Math ------------------------------------------------------------
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f1/rx_cos_acc}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f1/rx_sin_acc}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f1/rx_cos_dump}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f1/rx_sin_dump}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/data_f1}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f2/rx_cos_acc}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f2/rx_sin_acc}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f2/rx_cos_dump}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/u_f2/rx_sin_dump}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/data_f2}

add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/U_f1/u_lock_detect/acc_valid}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/U_f2/u_lock_detect/acc_valid}  
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/U_f1/u_lock_detect/icntr}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/U_f2/u_lock_detect/icntr}  

add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_sq_re}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_mix_re}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_fir_i}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_angle}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_phase}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/pi_out}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_sq_im}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_mix_im}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_fir_q}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dbu_angle_valid}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/common_err}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/common_adj_valid}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_i_samples}
add_wave -into {Costas_Loops}            {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_q_samples}


# --- bit decisions ----------------------------------------------------------
add_wave_group {Bit_Decisions}
add_wave -into {Bit_Decisions} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_data}
add_wave -into {Bit_Decisions} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_data_soft}
add_wave -into {Bit_Decisions} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_dvalid}

# --- frame sync -------------------------------------------------------------
add_wave_group {Frame_Sync}
add_wave -into {Frame_Sync}                 {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/frame_sync_locked}
add_wave -into {Frame_Sync} -radix unsigned {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/frames_received}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/debug_corr_peak}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/debug_correlation}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/debug_state}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/debug_consecutive_good}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/debug_missed_syncs}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/rx_bit}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/rx_bit_valid}
add_wave -into {Frame_Sync} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_fsync/demod_sync_lock}

# --- clocks / timing recovery -----------------------------------------------
add_wave_group {Clocks}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/tclk}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/tclk_dly}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dclk}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dclk_d}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/dclk_slv}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/rx_dec_lbk_tclk}
add_wave -into {Clocks} {/tb_haifuraiya_channelizer_axi/u_rx/u_rx/u_demod/lbk_tclk}

run all
