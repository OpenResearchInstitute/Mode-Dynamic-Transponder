################################################################################
# run_sym_lock_detector_test.tcl
# Vivado 2022.2 simulation script for the symbol lock detector unit bench
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    sym_lock_detector
# Scope:  windowed-|TED| lock detector contract (C++ SymbolLockDetector port):
#           T1 noise never locks          T4 gross error unlocks
#           T2 lock at exact window math  T5 window-change flush + relock
#           T3 hysteresis band holds      T6 sweep: 3 register configurations
#                                            (window 16 / 64 / 256, matched
#                                             thresholds) x lock/never/unlock
#         Self-checking; console prints PASS per assertion, then
#         "ALL TESTS PASS". System-bench integration (SL-A..D on the real
#         engine error stream) is specified in SYM_LOCK_INTEGRATION.md.
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/sim/run_sym_lock_detector_test.tcl
#
################################################################################

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

set project_name "sym_lock_detector_sim"
set project_dir  "./sym_lock_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

# Create clean project
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "Symbol Lock Detector Unit Testbench"
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

# --- Synthesizable RTL (production source) ---
puts "\nAdding synthesizable RTL..."
safe_add_files sources_1 {
    ../rtl/rx/sym_lock_detector.vhd
    ./sym_lock_detector.vhd
}
# (Both candidate locations listed; safe_add_files skips the absent one.
#  Production home is rtl/rx/ -- see SYM_LOCK_INTEGRATION.md for placement
#  and the component.xml entry required at integration.)

# --- Simulation sources ---
puts "\nAdding simulation sources..."
safe_add_files sim_1 {
    ./tb_sym_lock_detector.vhd
}

set_property top tb_sym_lock_detector [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Simulation launched. Check the xsim console output for the"
puts "PASS/FAIL summary:"
puts "  - 'ALL TESTS PASS' note  -> green (20 assertions)"
puts "  - any 'FAIL:' error      -> investigate"
puts "========================================"

################################################################################
# Waveform layout -- collapsible groups in SIGNAL-FLOW order:
#   TB_Control          what the bench drives (init, error stream, verdicts)
#   Detector_Config     the register-backed knobs (map v6 0x0A4/0x0A8/0x0AC)
#   Detector_State      the measurement and the verdict (map v6 0x0A0)
#   Detector_Internals  windowed-sum machinery (review only; no addresses)
################################################################################

set TB  /tb_sym_lock_detector
set DUT $TB/dut

add_wave_group {TB_Control}
add_wave -into {TB_Control}                    $TB/init
add_wave -into {TB_Control}                    $TB/ev
add_wave -into {TB_Control} -radix unsigned    $TB/ee
add_wave -into {TB_Control} -radix unsigned    $TB/ele
add_wave -into {TB_Control} -radix unsigned    $TB/fails

add_wave_group {Detector_Config}
add_wave -into {Detector_Config} -radix unsigned $TB/pl
add_wave -into {Detector_Config} -radix unsigned $TB/pu
add_wave -into {Detector_Config} -radix unsigned $TB/wl2

add_wave_group {Detector_State}
add_wave -into {Detector_State}                  $TB/lck
add_wave -into {Detector_State} -radix unsigned  $TB/pct
add_wave -into {Detector_State}                  $TB/wfull

add_wave_group {Detector_Internals}
add_wave -into {Detector_Internals} -radix unsigned $DUT/s_num
add_wave -into {Detector_Internals} -radix unsigned $DUT/s_den
add_wave -into {Detector_Internals} -radix unsigned $DUT/fill
add_wave -into {Detector_Internals} -radix unsigned $DUT/wr_ptr
add_wave -into {Detector_Internals} -radix unsigned $DUT/wlog_r
add_wave -into {Detector_Internals}                 $DUT/locked_r

run all
