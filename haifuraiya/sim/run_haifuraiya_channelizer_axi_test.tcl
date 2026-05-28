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
    ../rtl/channelizer/fft_n_pt.vhd
    ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../rtl/channelizer/fir_branch_parallel.vhd
    ../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../rtl/channelizer/haifuraiya_channelizer_top.vhd
    ../rtl/axi/axi_lite_regs.vhd
    ../rtl/axi/haifuraiya_channelizer_axi.vhd
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

# Copy coefficient file to xsim working directory (same pattern as the
# existing run_haifuraiya_channelizer_test.tcl)
puts "\nCopying coefficient files to xsim working directory..."
set coeff_src "../rtl/coeffs"
set coeff_dst "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $coeff_dst
foreach hex_file [glob -nocomplain [file join $coeff_src "*.hex"]] {
    file copy -force $hex_file $coeff_dst
    puts "  OK Copied: [file tail $hex_file] -> $coeff_dst"
}

# Pick the testbench as top-level for simulation
set_property top tb_haifuraiya_channelizer_axi [get_filesets sim_1]

# Reasonable simulation runtime - the testbench's stim process drives
# everything explicitly and calls finish, so this is just an upper bound.
set_property -name {xsim.simulate.runtime} -value {2 ms} \
    -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Simulation launched. Check the xsim console output for test"
puts "PASS/FAIL summary, or:"
puts "  - 'ALL TESTS PASSED' note -> green"
puts "  - 'TESTS FAILED' error    -> investigate"
puts "========================================"
