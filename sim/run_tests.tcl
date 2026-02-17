################################################################################
# run_tests.tcl
# Vivado TCL Script for Running Polyphase Channelizer Testbenches
################################################################################
# Open Research Institute
# Project: Polyphase Channelizer (MDT / Haifuraiya)
#
# Usage:
#   From Vivado TCL console:
#     source /path/to/Mode-Dynamic-Transponder/sim/run_tests.tcl
#
#   The script will automatically:
#     - Close any existing simulation
#     - Delete and recreate the project
#     - Add all source files with VHDL-2008
#     - Run the specified testbench
#
################################################################################

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]
cd ..

puts "========================================"
puts "Polyphase Channelizer Testbench Runner"
puts "Working directory: [pwd]"
puts "========================================"

set project_name "channelizer_sim"
set project_dir "./sim/vivado_project"
set part_name "xc7a35tcpg236-1"

# Delete existing project and create fresh
if {[file exists $project_dir]} {
    puts "Removing existing project..."
    file delete -force $project_dir
}

puts "Creating project: $project_name"
create_project $project_name $project_dir -part $part_name -force
set_property target_language VHDL [current_project]
set_property simulator_language VHDL [current_project]

# VHDL-2008 configuration
set_property -name {xsim.compile.xvhdl.more_options} -value {-2008} -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.xelab.more_options} -value {-2008} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {10ms} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]

################################################################################
# File adding helper with detailed error reporting
################################################################################

proc safe_add_files {fileset file_list} {
    foreach file $file_list {
        if {[file exists $file]} {
            puts "  ✓ Adding: $file"
            add_files -fileset $fileset -norecurse $file
            set_property file_type {VHDL 2008} [get_files $file]
        } else {
            puts "  ✗ MISSING: $file"
            puts "    Current directory: [pwd]"
            puts "    Full path would be: [file normalize $file]"
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

# Package (must be first)
puts "\n--- Package ---"
safe_add_files sources_1 {
    ./rtl/pkg/channelizer_pkg.vhd
}

# Channelizer modules
puts "\n--- Channelizer Modules ---"
safe_add_files sources_1 {
    ./rtl/channelizer/coeff_rom.vhd
    ./rtl/channelizer/delay_line.vhd
    ./rtl/channelizer/mac.vhd
    ./rtl/channelizer/fir_branch.vhd
    ./rtl/channelizer/polyphase_filterbank.vhd
    ./rtl/channelizer/fft_4pt.vhd
    ./rtl/channelizer/fft_64pt.vhd
    ./rtl/channelizer/polyphase_channelizer_top.vhd
}

# Testbenches
puts "\n--- Testbenches ---"
safe_add_files sim_1 {
    ./sim/tb_coeff_rom.vhd
    ./sim/tb_delay_line.vhd
    ./sim/tb_mac.vhd
    ./sim/tb_fir_branch.vhd
    ./sim/tb_polyphase_filterbank.vhd
    ./sim/tb_fft_4pt.vhd
    ./sim/tb_fft_64pt.vhd
}

puts "\n========================================"
puts "File addition complete"
puts "========================================"

################################################################################
# Copy coefficient files to simulation directory
################################################################################

puts "\nCopying coefficient files..."
set coeff_src "./rtl/coeffs"
set coeff_dst "$project_dir/$project_name.sim/sim_1/behav/xsim"
file mkdir $coeff_dst

foreach hex_file [glob -nocomplain [file join $coeff_src "*.hex"]] {
    file copy -force $hex_file $coeff_dst
    puts "  ✓ Copied: [file tail $hex_file]"
}

################################################################################
# Update compile order
################################################################################

puts "\nUpdating compile order..."
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

################################################################################
# Testbench list
################################################################################

set testbenches {
    tb_coeff_rom
    tb_delay_line
    tb_mac
    tb_fir_branch
    tb_polyphase_filterbank
    tb_fft_4pt
    tb_fft_64pt
}

################################################################################
# Procedures for running tests
################################################################################

proc run_test {tb_name} {
    variable testbenches
    
    # Verify testbench exists
    if {[lsearch -exact $testbenches $tb_name] == -1} {
        puts "ERROR: Unknown testbench '$tb_name'"
        puts "Available testbenches: $testbenches"
        return -1
    }
    
    puts ""
    puts "========================================"
    puts "Running testbench: $tb_name"
    puts "========================================"
    
    # Set the top module for simulation
    set_property top $tb_name [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    
    # Launch simulation
    if {[catch {launch_simulation -simset sim_1 -mode behavioral} result]} {
        puts "✗ Simulation launch failed: $result"
        return -1
    }
    
    puts "✓ Simulation launched successfully"
    
    # Run simulation
    run 10ms
    
    puts ""
    puts "========================================"
    puts "Testbench $tb_name complete"
    puts "========================================"
    
    return 0
}

proc run_test_gui {tb_name} {
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
    if {[catch {launch_simulation -simset sim_1 -mode behavioral} result]} {
        puts "✗ Simulation launch failed: $result"
        return -1
    }
    
    puts ""
    puts "✓ Simulation launched for $tb_name"
    puts "  Use 'run 10ms' or 'run -all' to execute"
    puts "  Waveform viewer is open for inspection"
    puts ""
    
    return 0
}

proc run_all_tests {} {
    variable testbenches
    
    set passed 0
    set failed 0
    set results {}
    
    puts ""
    puts "========================================"
    puts "RUNNING ALL TESTBENCHES"
    puts "========================================"
    
    foreach tb $testbenches {
        puts ""
        puts "----------------------------------------"
        puts "Starting: $tb"
        puts "----------------------------------------"
        
        # Close any previous simulation
        catch {close_sim -force}
        
        if {[catch {run_test $tb} result]} {
            puts "✗ FAILED: $tb - $result"
            incr failed
            lappend results [list $tb "FAILED"]
        } else {
            puts "✓ PASSED: $tb"
            incr passed
            lappend results [list $tb "PASSED"]
        }
        
        # Close simulation before next test
        catch {close_sim -force}
    }
    
    # Print summary
    puts ""
    puts "========================================"
    puts "TEST SUMMARY"
    puts "========================================"
    puts "Passed: $passed"
    puts "Failed: $failed"
    puts "Total:  [expr {$passed + $failed}]"
    puts ""
    
    foreach r $results {
        set name [lindex $r 0]
        set status [lindex $r 1]
        if {$status == "PASSED"} {
            puts "  ✓ $name: $status"
        } else {
            puts "  ✗ $name: $status"
        }
    }
    puts "========================================"
    
    return [expr {$failed == 0}]
}

################################################################################
# Print usage
################################################################################

puts ""
puts "========================================"
puts "Setup complete! Available commands:"
puts "========================================"
puts ""
puts "  run_test <tb_name>     - Run testbench, auto-close when done"
puts "  run_test_gui <tb_name> - Run testbench, keep waveform open"
puts "  run_all_tests          - Run all testbenches"
puts ""
puts "Available testbenches:"
foreach tb $testbenches {
    puts "  $tb"
}
puts ""
puts "Example:"
puts "  run_test tb_coeff_rom"
puts "  run_test_gui tb_mac"
puts "  run_all_tests"
puts "========================================"
puts ""
