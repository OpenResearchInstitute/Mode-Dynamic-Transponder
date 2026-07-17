################################################################################
# run_sync_fill_guard_test.tcl
# Vivado 2022.2 simulation script for the frame-sync fill-guard unit test
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    frame_sync_detector_soft
# Scope:  Unit test of the HUNTING fill guard -- HUNTING must not declare a lock
#         over a partially-filled correlation window (the insta-lock defect).
#         Isolated: instantiates the frame sync alone, no channelizer or demod.
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/sim/run_sync_fill_guard_test.tcl
#
# Read the xsim console for the summary:
#   'ALL TESTS PASSED' note  -> green (fill guard holding)
#   'TESTS FAILED'    error  -> insta-lock present (buggy RTL) or regression
################################################################################

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

set project_name "sync_fill_guard_sim"
set project_dir  "./sync_fill_guard_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

# Create clean project (full teardown every run -- no stale work library)
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "Frame-Sync Fill-Guard Unit Test"
puts "Project:     $project_name"
puts "Part:        $part_name (ZCU102)"
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

# --- Synthesizable RTL (production source) ---
# The one production file under test. This is the SAME file the rx build uses,
# so the test exercises the real RTL, not a copy.
puts "\nAdding synthesizable RTL..."
safe_add_files sources_1 {
    ../rtl/rx/frame_sync_detector_soft.vhd
}

# --- Testbench ---
puts "\nAdding testbench..."
safe_add_files sim_1 {
    ./tb_sync_fill_guard.vhd
}

# Set VHDL-2008 language for all of our files
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}

# Pick the testbench as top-level for simulation
set_property top tb_sync_fill_guard [get_filesets sim_1]

# The testbench drives everything explicitly and calls finish, so runtime is
# just an upper bound.
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Simulation launched. Check the xsim console output for:"
puts "  - 'ALL TESTS PASSED' note  -> green (fill guard holding)"
puts "  - 'TESTS FAILED'    error  -> insta-lock / regression"
puts "========================================"

################################################################################
# Waveform layout -- collapsible groups in SIGNAL-FLOW order:
#
#   TB_Control   bench progress: symbol counter and the captured lock symbol
#   Frame_Sync   the correlation decision plane. WATCH fill_prev: it ramps
#                1,2,3,... after the demod_sync_lock clear; debug_state must
#                stay HUNTING (1) until fill_prev reaches 24. On the buggy RTL,
#                debug_state jumps to LOCKED (2) at sym 2 with fill_prev = 1.
#
# Hierarchy: u_fsync = the frame_sync_detector_soft instance.
#
# NOTE: fill_prev and debug_sync_fill exist ONLY after the fill-guard patch has
# been applied; the catch{} wrappers keep this script working against the
# unpatched RTL too (those waves are simply skipped).
################################################################################

set TB /tb_sync_fill_guard
set FS $TB/u_fsync

# --- bench progress ---------------------------------------------------------
add_wave_group {TB_Control}
add_wave -into {TB_Control} $TB/running
add_wave -into {TB_Control} -radix unsigned $TB/sym_since_clear
add_wave -into {TB_Control} -radix dec      $TB/first_lock_sym

# --- frame sync decision plane ----------------------------------------------
add_wave_group {Frame_Sync}
add_wave -into {Frame_Sync} $FS/demod_sync_lock
add_wave -into {Frame_Sync} $FS/demod_sync_lock_d
add_wave -into {Frame_Sync} $FS/rx_bit_valid
add_wave -into {Frame_Sync} -radix dec $FS/debug_soft_current
add_wave -into {Frame_Sync} $FS/debug_state
add_wave -into {Frame_Sync} -radix dec $FS/corr_prev
add_wave -into {Frame_Sync} -radix dec $FS/energy_prev
catch {add_wave -into {Frame_Sync} -radix unsigned $FS/fill_prev}
catch {add_wave -into {Frame_Sync} -radix unsigned $FS/debug_sync_fill}
add_wave -into {Frame_Sync} $FS/debug_corr_peak
add_wave -into {Frame_Sync} $FS/debug_correlation
add_wave -into {Frame_Sync} $FS/debug_consecutive_good
add_wave -into {Frame_Sync} $FS/debug_missed_syncs

run all
