################################################################################
# run_cfo_afc_test.tcl -- Vivado 2022.2 unit bench for the AFC estimator
# DUT: cfo_afc (WP2 step 2). Self-checking, 8 assertions:
#   T1 cold acquisition +5 kHz -> HELD, est +5000
#   T2 mid-run step to -3 kHz -> gear downshift, re-HELD, est -3000
#   T3 dead air -> LOST/SEARCH, estimate retained warm
#   T4 signal returns at +2 kHz -> autonomous reacquisition (anti-wedge,
#      the scenario that requires a C++ restart -- KB5MU 2026-07-07)
# Console: "ALL TESTS PASS" -> green.
# USAGE: source from the Vivado TCL console in sim/.
################################################################################
catch {close_sim -force}
cd [file dirname [info script]]
set project_name "cfo_afc_sim"
set project_dir  "./cfo_afc_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name
proc safe_add_files {fileset file_list {library "work"}} {
    foreach file $file_list {
        if {[file exists $file]} { add_files -fileset $fileset -norecurse $file; puts "  OK   $file"
        } else { puts "  SKIP $file (not found)" } } }
safe_add_files sources_1 { ../rtl/rx/cfo_afc.vhd ./cfo_afc.vhd }
safe_add_files sim_1 { ./tb_cfo_afc.vhd }
set_property top tb_cfo_afc [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
launch_simulation
set TB /tb_cfo_afc
add_wave_group {AFC}
add_wave -into {AFC} -radix dec      $TB/est
add_wave -into {AFC} -radix unsigned $TB/st
add_wave -into {AFC} -radix unsigned $TB/q
add_wave -into {AFC}                 $TB/lck
add_wave -into {AFC} -radix dec      $TB/y1r
run all
