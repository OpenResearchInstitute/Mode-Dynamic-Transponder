################################################################################
# run_soft_quantizer.tcl
#
# Proves the fix to FUNCTION quantize() in rtl/.../frame_sync_detector_soft.vhd.
#
# This bench is SELF-CONTAINED. It needs no RTL, no vectors, no python. Both the
# CURRENT function and the PROPOSED replacement are written out inside the
# testbench, so you can run it BEFORE you touch any source file.
#
# It checks:
#   Q1  q(-s) = 7 - q(s)              (the map must be symmetric)
#   Q2  all 8 codes reachable         (the current one never emits 6)
#   Q3  monotone in soft              (a quantizer must not fold)
#   Q4  the 3<->4 boundary is at 0    (the current one puts it at -thr1)
#   Q6  q(0) = 4                      (matches opv_demod.hpp int(3.5+0.5))
#   COMPAT  outside +/-thr3 the fix changes NOTHING
#
# and three NEGATIVE CONTROLS that must FAIL on the current function. If those
# stop firing, someone already applied the fix and this bench is testing nothing.
#
# USAGE, from the sim/ directory in the Vivado TCL console:
#     source run_soft_quantizer.tcl
#
# EXPECTED OUTPUT:
#     Q5 ok (negative control): CURRENT violates q(-s)=7-q(s) on 921 of 1601 points
#     Q5 ok (negative control): CURRENT never emits code 6
#     Q5 ok (negative control): CURRENT's 3<->4 boundary is at soft = -92, not 0
#     Q1 PASS  Q2 PASS  Q3 PASS  Q4 PASS  Q6 PASS
#     COMPAT PASS: outside +/-thr3 the fix changes NOTHING.
#     SOFT QUANTIZER TB PASSED
#
# GHDL equivalent (no Vivado needed):
#     ghdl -a --std=08 tb_soft_quantizer.vhd
#     ghdl -e --std=08 tb_soft_quantizer
#     ghdl -r --std=08 tb_soft_quantizer --ieee-asserts=disable
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

set project_name "soft_quantizer_sim"
set project_dir  "./soft_quantizer_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

puts "\nAdding testbench (no RTL required -- both functions live inside it)..."
add_required sim_1 { ./tb_soft_quantizer.vhd }

foreach f [get_files -of_objects [get_filesets sim_1] -filter {FILE_TYPE == VHDL}] {
    set_property file_type {VHDL 2008} $f
}

set_property top tb_soft_quantizer [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1 us} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'SOFT QUANTIZER TB PASSED'"
puts ""
puts "The three 'Q5 ok (negative control)' lines confirm the CURRENT function"
puts "is broken. If they do NOT appear, the fix is already applied."
puts "========================================"
