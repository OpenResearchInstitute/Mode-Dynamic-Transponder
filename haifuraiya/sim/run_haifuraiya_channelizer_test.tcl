################################################################################
# run_haifuraiya_channelizer_test.tcl
# Vivado 2022.2 simulation script for the Haifuraiya polyphase channelizer
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    haifuraiya_channelizer_top
# Tests:  smoke, DC, complex-exp tones, off-bin, adjacent-channel rejection,
#         OPV-like carrier in single channel
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/sim/run_haifuraiya_channelizer_test.tcl
#
# This script lives alongside the existing run_tests.tcl and
# msk_modem_134byte_test.tcl. It creates its own throwaway project so it
# does not collide with either of them.
################################################################################

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

set project_name "haifuraiya_channelizer_sim"
set project_dir  "./haifuraiya_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

# Create clean project
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "Haifuraiya Channelizer Testbench"
puts "Project:    $project_name"
puts "Part:       $part_name (ZCU102)"
puts "Working dir: [pwd]"
puts "========================================"

create_project $project_name $project_dir -part $part_name -force
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# VHDL-2008 configuration
set_property -name {xsim.compile.vhdl.more_options}  -value {-2008} -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.vhdl.more_options} -value {-2008} -objects [get_filesets sim_1]
# Don't auto-run during launch_simulation; we want to add waves first,
# then run explicitly so signals are logged from t=0.
set_property -name {xsim.simulate.runtime}           -value {0ns}   -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals}   -value {true}  -objects [get_filesets sim_1]

################################################################################
# File adding helper with detailed error reporting
################################################################################

proc safe_add_files {fileset file_list {library "work"}} {
    foreach file $file_list {
        if {[file exists $file]} {
            puts "OK Adding: $file"
            add_files -fileset $fileset -norecurse $file
            set_property file_type {VHDL 2008} [get_files $file]
            if {$library != "work"} {
                set_property library $library [get_files $file]
            }
        } else {
            puts "MISSING: $file"
            puts "  Current directory: [pwd]"
            puts "  Full path would be: [file normalize $file]"
            return 0
        }
    }
    return 1
}

################################################################################
# Add VHDL source files
################################################################################

puts ""
puts "========================================"
puts "Adding VHDL source files..."
puts "========================================"

# Shared package
puts "\n--- Package ---"
safe_add_files sources_1 {
    ../rtl/pkg/channelizer_pkg.vhd
}

# Channelizer building blocks (must compile before the top wrapper)
# fft_pkg must come before fft_n_pt (the FFT uses helpers from the package)
puts "\n--- Channelizer Building Blocks ---"
safe_add_files sources_1 {
    ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../rtl/channelizer/fir_branch_parallel.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/fft_pkg.vhd
    ../rtl/channelizer/fft_n_pt.vhd
}

# Haifuraiya top wrapper
puts "\n--- Haifuraiya Top Wrapper ---"
safe_add_files sources_1 {
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
}

# Testbench
puts "\n--- Testbench ---"
safe_add_files sim_1 {
    ./tb_haifuraiya_channelizer_top.vhd
}

puts "\n========================================"
puts "File addition complete"
puts "========================================"

################################################################################
# Copy coefficient file to xsim working directory
# fir_branch_parallel uses TEXTIO to read its own slice of the .hex file at
# elaboration time using a relative path, so the file must be reachable from
# the xsim cwd. Each of the 64 branches in each filterbank opens the file
# independently and skips to its own offset; this is safe because file_open
# is per-elaboration and read-only.
################################################################################

puts "\nCopying coefficient files to xsim working directory..."
set coeff_src "../rtl/coeffs"
set coeff_dst "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $coeff_dst

foreach hex_file [glob -nocomplain [file join $coeff_src "*.hex"]] {
    file copy -force $hex_file $coeff_dst
    puts "  OK Copied: [file tail $hex_file] -> $coeff_dst"
}

################################################################################
# Compile order, top, launch
################################################################################

puts "\nUpdating compile order..."
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property top tb_haifuraiya_channelizer_top [get_filesets sim_1]
set_property top_lib work                      [get_filesets sim_1]

puts "\n========================================"
puts "Launching behavioral simulation..."
puts "========================================"

if {[catch {launch_simulation -simset sim_1 -mode behavioral} result]} {
    puts "Simulation launch failed: $result"
    return
}

puts "Simulation launched successfully"

################################################################################
# Waveform setup
################################################################################

puts "\nSetting up waveform..."

# Top-level groups
add_wave_group {Test_Control}
add_wave_group {Top_IO}
add_wave_group {Status}
add_wave_group {Filterbank_I}
add_wave_group {Filterbank_Q}
add_wave_group {P2S_Adapter}
add_wave_group {FFT_0}
add_wave_group {FFT_1}
add_wave_group {Output_Capture}

# Test_Control: high-level test progress
add_wave -into {Test_Control} /tb_haifuraiya_channelizer_top/running
add_wave -into {Test_Control} -radix unsigned /tb_haifuraiya_channelizer_top/frame_seq
add_wave -into {Test_Control} -radix unsigned /tb_haifuraiya_channelizer_top/frame_dropped_count

# Top_IO: DUT external interface
add_wave -into {Top_IO} /tb_haifuraiya_channelizer_top/clk
add_wave -into {Top_IO} /tb_haifuraiya_channelizer_top/reset
add_wave -into {Top_IO} -radix dec /tb_haifuraiya_channelizer_top/sample_re
add_wave -into {Top_IO} -radix dec /tb_haifuraiya_channelizer_top/sample_im
add_wave -into {Top_IO} /tb_haifuraiya_channelizer_top/sample_valid
add_wave -into {Top_IO} -radix dec /tb_haifuraiya_channelizer_top/channel_re
add_wave -into {Top_IO} -radix dec /tb_haifuraiya_channelizer_top/channel_im
add_wave -into {Top_IO} -radix unsigned /tb_haifuraiya_channelizer_top/channel_idx
add_wave -into {Top_IO} /tb_haifuraiya_channelizer_top/channel_valid
add_wave -into {Top_IO} /tb_haifuraiya_channelizer_top/channel_last

# Status
add_wave -into {Status} /tb_haifuraiya_channelizer_top/ready
add_wave -into {Status} /tb_haifuraiya_channelizer_top/frame_dropped

# Filterbank I path
add_wave -into {Filterbank_I} -radix dec /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/sample_in
add_wave -into {Filterbank_I} /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/sample_valid
add_wave -into {Filterbank_I} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/branch_select
add_wave -into {Filterbank_I} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/samples_since_fc
add_wave -into {Filterbank_I} /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/frame_complete_d0
add_wave -into {Filterbank_I} /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/frame_complete_d1
add_wave -into {Filterbank_I} /tb_haifuraiya_channelizer_top/dut/u_filterbank_i/outputs_valid
add_wave -into {Filterbank_I} -radix hex /tb_haifuraiya_channelizer_top/dut/fb_i_outputs

# Filterbank Q path
add_wave -into {Filterbank_Q} -radix dec /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/sample_in
add_wave -into {Filterbank_Q} /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/sample_valid
add_wave -into {Filterbank_Q} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/branch_select
add_wave -into {Filterbank_Q} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/samples_since_fc
add_wave -into {Filterbank_Q} /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/frame_complete_d0
add_wave -into {Filterbank_Q} /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/frame_complete_d1
add_wave -into {Filterbank_Q} /tb_haifuraiya_channelizer_top/dut/u_filterbank_q/outputs_valid
add_wave -into {Filterbank_Q} -radix hex /tb_haifuraiya_channelizer_top/dut/fb_q_outputs

# Parallel-to-Sequential adapter (dual-FFT version)
# The arbiter signals show round-robin behavior:
#   next_fft toggles between '0' and '1' on each successful latch
#   current_fft selects which FFT is being streamed to
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/p2s_state
add_wave -into {P2S_Adapter} -radix unsigned /tb_haifuraiya_channelizer_top/dut/p2s_idx
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/next_fft
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/current_fft
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft0_busy
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft1_busy
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/frame_dropped_r
# FFT_0 input drive (shown here so you can see which FFT is receiving)
add_wave -into {P2S_Adapter} -radix dec /tb_haifuraiya_channelizer_top/dut/fft0_x_re
add_wave -into {P2S_Adapter} -radix unsigned /tb_haifuraiya_channelizer_top/dut/fft0_x_idx
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft0_x_valid
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft0_x_last
# FFT_1 input drive
add_wave -into {P2S_Adapter} -radix dec /tb_haifuraiya_channelizer_top/dut/fft1_x_re
add_wave -into {P2S_Adapter} -radix unsigned /tb_haifuraiya_channelizer_top/dut/fft1_x_idx
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft1_x_valid
add_wave -into {P2S_Adapter} /tb_haifuraiya_channelizer_top/dut/fft1_x_last

# FFT_0 internals
add_wave -into {FFT_0} /tb_haifuraiya_channelizer_top/dut/u_fft_0/state
add_wave -into {FFT_0} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_0/stage_cnt
add_wave -into {FFT_0} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_0/butterfly_cnt
add_wave -into {FFT_0} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_0/out_cnt
add_wave -into {FFT_0} /tb_haifuraiya_channelizer_top/dut/u_fft_0/src_is_buf_a
add_wave -into {FFT_0} /tb_haifuraiya_channelizer_top/dut/fft0_busy
add_wave -into {FFT_0} /tb_haifuraiya_channelizer_top/dut/fft0_out_valid
add_wave -into {FFT_0} /tb_haifuraiya_channelizer_top/dut/fft0_out_last
add_wave -into {FFT_0} -radix unsigned /tb_haifuraiya_channelizer_top/dut/fft0_out_idx
add_wave -into {FFT_0} -radix dec /tb_haifuraiya_channelizer_top/dut/fft0_out_re
add_wave -into {FFT_0} -radix dec /tb_haifuraiya_channelizer_top/dut/fft0_out_im

# FFT_1 internals
add_wave -into {FFT_1} /tb_haifuraiya_channelizer_top/dut/u_fft_1/state
add_wave -into {FFT_1} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_1/stage_cnt
add_wave -into {FFT_1} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_1/butterfly_cnt
add_wave -into {FFT_1} -radix unsigned /tb_haifuraiya_channelizer_top/dut/u_fft_1/out_cnt
add_wave -into {FFT_1} /tb_haifuraiya_channelizer_top/dut/u_fft_1/src_is_buf_a
add_wave -into {FFT_1} /tb_haifuraiya_channelizer_top/dut/fft1_busy
add_wave -into {FFT_1} /tb_haifuraiya_channelizer_top/dut/fft1_out_valid
add_wave -into {FFT_1} /tb_haifuraiya_channelizer_top/dut/fft1_out_last
add_wave -into {FFT_1} -radix unsigned /tb_haifuraiya_channelizer_top/dut/fft1_out_idx
add_wave -into {FFT_1} -radix dec /tb_haifuraiya_channelizer_top/dut/fft1_out_re
add_wave -into {FFT_1} -radix dec /tb_haifuraiya_channelizer_top/dut/fft1_out_im

# Output Capture: easier to read the captured frame than the raw stream
add_wave -into {Output_Capture} -radix unsigned /tb_haifuraiya_channelizer_top/frame_seq_at_last_capture
# Sample bins of interest for the tone tests
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[0]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[4]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[15]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[16]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[17]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[28]
add_wave -into {Output_Capture} -radix dec /tb_haifuraiya_channelizer_top/frame_re[40]

################################################################################
# Run simulation
################################################################################

puts ""
puts "========================================"
puts "RUNNING HAIFURAIYA CHANNELIZER TEST"
puts "  100 MHz clk, 10 Msps input"
puts "  N=64 channels, 24 taps/branch"
puts "  Tests: smoke, DC, tones, off-bin,"
puts "         adjacent-rejection, OPV-carrier"
puts "========================================"
puts ""

run 5 ms

puts ""
puts "Simulation complete!"
puts ""
puts "Look in the transcript for per-test results:"
puts "  TEST 1 PASS: smoke"
puts "  TEST 2 PASS: DC energy in bin 0"
puts "  TEST 3.k=N PASS:  tone in bin N"
puts "  TEST 4 PASS:  off-bin energy split between adjacent bins"
puts "  TEST 5 PASS:  rejection > 25 dB"
puts "  TEST 6 PASS:  clean carrier capture, no frame drops"
puts ""
puts "Any 'NOTE' lines flag tests that completed but warrant review."
puts "========================================"
