################################################################################
# run_sync_normalized.tcl
#
# Proves the frame-sync threshold change in
#   ../rtl/rx/frame_sync_detector_soft.vhd
#
#   OLD:        corr >= FS_HUNT_THRESH          an absolute count
#   NEW:  100 * corr >= FS_HUNT_PCT * energy    a fraction of the energy
#
#   corr   = sum over 24 taps of soft * bipolar_sync
#   energy = sum over the same 24 taps of |soft|
#
# The bench is SELF-CONTAINED. It carries both rules inside itself and needs no
# RTL, no vectors, and no python. Run it BEFORE applying the patch.
#
# USAGE, from sim/ in the Vivado TCL console:
#     source run_sync_normalized.tcl
#
# EXPECTED:
#   N2 PASS: perfect alignment gives corr = energy, ratio = 1.000
#   N3 PASS: p flipped sync symbols give ratio = 1 - 2p/24 exactly
#   N1 PASS: the NEW rule triggers at every amplitude from 1000 to 32000 (30 dB)
#   N4: ratio std against random data = 0.2042  (theory 1/sqrt(24) = 0.2041)
#       HUNT at 0.85 = 4.16 sigma; fired 1 time in 200,000
#   N5 ok (negative control): the OLD rule MISSES the same sync at half amplitude
#   N5 ok (negative control): the OLD rule fires on 14% of loud random data
#   SYNC NORMALIZATION TB PASSED
#
# If the two N5 lines do NOT appear, the bench is testing nothing.
#
# GHDL equivalent:
#   ghdl -a --std=08 tb_sync_normalized.vhd
#   ghdl -e --std=08 tb_sync_normalized
#   ghdl -r --std=08 tb_sync_normalized --ieee-asserts=disable
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

proc add_required {fileset file_list} {
    foreach f $file_list {
        if {![file exists $f]} {
            puts "ERROR: required source not found: $f  (cwd is [pwd])"
            return -code error "missing source $f"
        }
        add_files -fileset $fileset -norecurse $f
        puts "  OK   $f"
    }
}

set project_name "sync_normalized_sim"
set project_dir  "./sync_normalized_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

puts "\nAdding testbench (no RTL required -- both rules live inside it)..."
add_required sim_1 { ./tb_sync_normalized.vhd }

foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}
set_property top tb_sync_normalized [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1 us} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'SYNC NORMALIZATION TB PASSED'"
puts "and the TWO 'N5 ok (negative control)' lines."
puts "========================================"
