#------------------------------------------------------------------------------
# run_tests.tcl
# Vivado TCL Script for Running Polyphase Channelizer Testbenches
#------------------------------------------------------------------------------
# Open Research Institute
# Project: Polyphase Channelizer (MDT / Haifuraiya)
#
# Usage:
#   From Vivado TCL console:
#     cd /path/to/Mode-Dynamic-Transponder
#     source sim/run_tests.tcl
#     run_all_tests              ;# Run all testbenches
#     run_test tb_coeff_rom      ;# Run single testbench
#
#   Or from command line:
#     vivado -mode batch -source sim/run_tests.tcl -tclargs run_all
#
#------------------------------------------------------------------------------

# Get the directory where this script lives
variable script_dir [file dirname [info script]]
variable repo_root [file normalize [file join $script_dir ".."]]

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

# RTL source files (in compilation order)
set rtl_files {
    rtl/pkg/channelizer_pkg.vhd
    rtl/channelizer/coeff_rom.vhd
    rtl/channelizer/delay_line.vhd
    rtl/channelizer/mac.vhd
    rtl/channelizer/fir_branch.vhd
    rtl/channelizer/polyphase_filterbank.vhd
    rtl/channelizer/fft_4pt.vhd
    rtl/channelizer/fft_64pt.vhd
    rtl/channelizer/polyphase_channelizer_top.vhd
}

# Testbench files
set tb_files {
    sim/tb_coeff_rom.vhd
    sim/tb_delay_line.vhd
    sim/tb_mac.vhd
    sim/tb_fir_branch.vhd
    sim/tb_polyphase_filterbank.vhd
    sim/tb_fft_4pt.vhd
    sim/tb_fft_64pt.vhd
}

# List of all testbench names (entity names)
set testbenches {
    tb_coeff_rom
    tb_delay_line
    tb_mac
    tb_fir_branch
    tb_polyphase_filterbank
    tb_fft_4pt
    tb_fft_64pt
}

#------------------------------------------------------------------------------
# Procedures
#------------------------------------------------------------------------------

proc create_sim_project {project_name} {
    # Create a new simulation-only project
    variable repo_root
    
    set project_dir [file join $repo_root "sim" "vivado_project"]
    
    # Remove existing project if present
    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }
    
    # Create project
    create_project $project_name $project_dir -part xc7a35tcpg236-1
    
    # Set project for simulation only
    set_property target_language VHDL [current_project]
    set_property simulator_language VHDL [current_project]
    
    # Add RTL sources
    variable rtl_files
    foreach f $rtl_files {
        set full_path [file join $repo_root $f]
        if {[file exists $full_path]} {
            add_files -norecurse $full_path
            puts "Added: $f"
        } else {
            puts "WARNING: File not found: $full_path"
        }
    }
    
    # Add testbench sources
    variable tb_files
    foreach f $tb_files {
        set full_path [file join $repo_root $f]
        if {[file exists $full_path]} {
            add_files -fileset sim_1 -norecurse $full_path
            puts "Added TB: $f"
        } else {
            puts "WARNING: File not found: $full_path"
        }
    }
    
    # Copy coefficient files to simulation directory
    set coeff_src [file join $repo_root "rtl" "coeffs"]
    set coeff_dst [file join $project_dir "${project_name}.sim" "sim_1" "behav" "xsim"]
    file mkdir $coeff_dst
    
    foreach hex_file [glob -nocomplain [file join $coeff_src "*.hex"]] {
        file copy -force $hex_file $coeff_dst
        puts "Copied: [file tail $hex_file] to simulation directory"
    }
    
    # Update compile order
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
    
    puts "\nProject created: $project_dir"
    return $project_dir
}

proc run_test {tb_name {runtime "10ms"}} {
    # Run a single testbench
    variable testbenches
    
    # Verify testbench exists
    if {[lsearch -exact $testbenches $tb_name] == -1} {
        puts "ERROR: Unknown testbench '$tb_name'"
        puts "Available testbenches: $testbenches"
        return -1
    }
    
    puts "\n============================================================"
    puts "Running testbench: $tb_name"
    puts "============================================================\n"
    
    # Set the top module for simulation
    set_property top $tb_name [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    
    # Launch simulation
    launch_simulation
    
    # Run for specified time
    run $runtime
    
    puts "\n============================================================"
    puts "Testbench $tb_name complete"
    puts "============================================================\n"
    
    # Close simulation
    close_sim
    
    return 0
}

proc run_all_tests {{runtime "10ms"}} {
    # Run all testbenches
    variable testbenches
    
    set passed 0
    set failed 0
    set results {}
    
    puts "\n============================================================"
    puts "RUNNING ALL TESTBENCHES"
    puts "============================================================\n"
    
    foreach tb $testbenches {
        puts "----------------------------------------"
        puts "Starting: $tb"
        puts "----------------------------------------"
        
        if {[catch {run_test $tb $runtime} result]} {
            puts "FAILED: $tb - $result"
            incr failed
            lappend results [list $tb "FAILED" $result]
        } else {
            puts "PASSED: $tb"
            incr passed
            lappend results [list $tb "PASSED" ""]
        }
    }
    
    # Print summary
    puts "\n============================================================"
    puts "TEST SUMMARY"
    puts "============================================================"
    puts "Passed: $passed"
    puts "Failed: $failed"
    puts "Total:  [expr {$passed + $failed}]"
    puts ""
    
    foreach r $results {
        set name [lindex $r 0]
        set status [lindex $r 1]
        puts "  $name: $status"
    }
    puts "============================================================\n"
    
    return [expr {$failed == 0}]
}

proc run_test_gui {tb_name} {
    # Run testbench with waveform viewer
    variable testbenches
    
    if {[lsearch -exact $testbenches $tb_name] == -1} {
        puts "ERROR: Unknown testbench '$tb_name'"
        puts "Available testbenches: $testbenches"
        return -1
    }
    
    # Set the top module for simulation
    set_property top $tb_name [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    
    # Launch simulation with GUI
    launch_simulation
    
    # Add useful signals to waveform
    # (User can add more interactively)
    
    puts "\nSimulation launched for $tb_name"
    puts "Use 'run 10ms' or 'run -all' to execute"
    puts "Use 'close_sim' when done"
    
    return 0
}

#------------------------------------------------------------------------------
# Print usage
#------------------------------------------------------------------------------
proc print_usage {} {
    puts ""
    puts "Polyphase Channelizer Testbench Runner"
    puts "======================================="
    puts ""
    puts "Available commands:"
    puts "  create_sim_project <name>  - Create Vivado simulation project"
    puts "  run_test <tb_name>         - Run single testbench"
    puts "  run_all_tests              - Run all testbenches"
    puts "  run_test_gui <tb_name>     - Run testbench with waveform viewer"
    puts "  print_usage                - Show this help"
    puts ""
    puts "Available testbenches:"
    variable testbenches
    foreach tb $testbenches {
        puts "  $tb"
    }
    puts ""
    puts "Example:"
    puts "  create_sim_project channelizer_sim"
    puts "  run_test tb_mac"
    puts "  run_all_tests"
    puts ""
}

#------------------------------------------------------------------------------
# Handle command line arguments (for batch mode)
#------------------------------------------------------------------------------
if {[info exists argc] && $argc > 0} {
    set cmd [lindex $argv 0]
    
    switch $cmd {
        "run_all" {
            create_sim_project "channelizer_sim"
            run_all_tests
            exit
        }
        "run" {
            if {$argc > 1} {
                set tb [lindex $argv 1]
                create_sim_project "channelizer_sim"
                run_test $tb
                exit
            } else {
                puts "ERROR: Specify testbench name"
                exit 1
            }
        }
        default {
            puts "Unknown command: $cmd"
            print_usage
            exit 1
        }
    }
} else {
    # Interactive mode - just print usage
    print_usage
}
