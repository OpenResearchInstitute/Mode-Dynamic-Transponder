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
#set stim_file [file join [file dirname [info script]] "opv_chan_stim.txt"]
set stim_file [file join [file dirname [info script]] "cw_tone_27k_10msps.txt"]
if {[file exists $stim_file]} {
    file mkdir $coeff_dst
# ensure the dir exists, whatever the order
    file copy -force $stim_file $coeff_dst
    puts "  OK Copied: [file tail $stim_file] -> $coeff_dst"
} else {
    puts "  WARNING: $stim_file not found -- generate it with gen_opv_stimulus.py"
    puts "           and drop it in sim/, or the OPV phase will fail on file open."
}


# Pick the testbench as top-level for simulation
set_property top tb_haifuraiya_channelizer_axi [get_filesets sim_1]

# Reasonable simulation runtime - the testbench's stim process drives
# everything explicitly and calls finish, so this is just an upper bound.
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Simulation launched. Check the xsim console output for test"
puts "PASS/FAIL summary, or:"
puts "  - 'ALL TESTS PASSED' note -> green"
puts "  - 'TESTS FAILED' error    -> investigate"
puts "========================================"


# demod loop visibility (instance-internal -> not auto-added)
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/lpf_accum_f1}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/lpf_accum_f2}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/f1_error}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/f2_error}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/dbg_acc_i_f1}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/dbg_acc_q_f1}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/tclk}
add_wave {/tb_haifuraiya_channelizer_axi/u_fsync/frame_sync_locked}
add_wave {/tb_haifuraiya_channelizer_axi/u_fsync/frames_received}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/cst_lock_f1}
add_wave {/tb_haifuraiya_channelizer_axi/u_demod/cst_lock_f2}
add_wave {/tb_haifuraiya_channelizer_axi/u_fsync/frame_sync_locked}
add_wave {/tb_haifuraiya_channelizer_axi/n_target_samps}
add_wave {/tb_haifuraiya_channelizer_axi/rx_data_soft}

run all
