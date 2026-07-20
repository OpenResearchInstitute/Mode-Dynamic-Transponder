################################################################################
# run_cfo_rotator_test.tcl
# Vivado 2022.2 simulation script for the CFO correction rotator unit bench
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    cfo_rotator (WP2 build step 1 -- WP2_CFO_DESIGN.md section 6)
# Scope:  T1 freq=0 passthrough (tone slope preserved, measured in Hz)
#         T2 +5 kHz tone + freq_hz=+5000 -> DC (slope < 40 Hz residual)
#         T3 -3 kHz tone + freq_hz=-3000 -> DC (sign convention)
#         T4 amplitude preserved through correction (rounding multiply)
#         Self-checking; console prints PASS per assertion then
#         "ALL TESTS PASS" (4 assertions).
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/sim/run_cfo_rotator_test.tcl
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

set project_name "cfo_rotator_sim"
set project_dir  "./cfo_rotator_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"

if {[file exists $project_dir]} { file delete -force $project_dir }

puts "========================================"
puts "CFO Rotator Unit Testbench"
puts "Project:    $project_name"
puts "Part:       $part_name (ZCU102)"
puts "========================================"

create_project $project_name $project_dir -part $part_name

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

puts "\nAdding synthesizable RTL..."
safe_add_files sources_1 {
    ../rtl/rx/lut16q_pkg.vhd
    ../rtl/rx/cfo_rotator.vhd
    ./cfo_rotator.vhd
}
puts "\nAdding simulation sources..."
safe_add_files sim_1 {
    ./tb_cfo_rotator.vhd
}

set_property top tb_cfo_rotator [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Check the xsim console: 'ALL TESTS PASS' (4 assertions) -> green"
puts "========================================"

set TB  /tb_cfo_rotator
set DUT $TB/dut

add_wave_group {TB_Control}
add_wave -into {TB_Control}                 $TB/rst
add_wave -into {TB_Control}                 $TB/en
add_wave -into {TB_Control} -radix dec      $TB/fhz
add_wave -into {TB_Control} -radix unsigned $TB/fails

add_wave_group {Rotator_IO}
add_wave -into {Rotator_IO} -radix dec      $TB/ii
add_wave -into {Rotator_IO} -radix dec      $TB/qi
add_wave -into {Rotator_IO}                 $TB/ov
add_wave -into {Rotator_IO} -radix dec      $TB/io
add_wave -into {Rotator_IO} -radix dec      $TB/qo

add_wave_group {Rotator_Internals}
add_wave -into {Rotator_Internals} -radix unsigned $DUT/phase
add_wave -into {Rotator_Internals} -radix unsigned $DUT/addr1
add_wave -into {Rotator_Internals}                 $DUT/cneg2
add_wave -into {Rotator_Internals}                 $DUT/sneg2

run all
