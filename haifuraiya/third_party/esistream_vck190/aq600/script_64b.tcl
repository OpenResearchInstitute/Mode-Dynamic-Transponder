# -------------------------------------------------------------------------------
# -- This is free and unencumbered software released into the public domain.
# --
# -- Anyone is free to copy, modify, publish, use, compile, sell, or distribute
# -- this software, either in source code form or as a compiled bitstream, for 
# -- any purpose, commercial or non-commercial, and by any means.
# --
# -- In jurisdictions that recognize copyright laws, the author or authors of 
# -- this software dedicate any and all copyright interest in the software to 
# -- the public domain. We make this dedication for the benefit of the public at
# -- large and to the detriment of our heirs and successors. We intend this 
# -- dedication to be an overt act of relinquishment in perpetuity of all present
# -- and future rights to this software under copyright law.
# --
# -- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# -- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# -- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# -- AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
# -- ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# -- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# --
# -- THIS DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES. 
# -------------------------------------------------------------------------------
#All Tcl scripts have access to three predefined variables.
#    $argc - number items of arguments passed to a script.
#    $argv - list of the arguments.
#    $argv0 - name of the script.
set fpga_ref xcvc1902-vsva2197-2MP-e-S
set board_ref "xilinx.com:vck190:part0:2.2"
set platform_board_id "vck190"
#
set path_file [ dict get [ info frame 0 ] file ]
set script_name [lindex [file split $path_file] end]
#puts $script_name
set script_dir [string trim $script_name "tcl"]
set script_dir [string trim $script_dir "."]
#puts $script_dir
set script_ref [string trim $script_dir "script_"]
#puts $script_ref
set project_dir [lindex [file split $path_file] end-1]
set project_name $project_dir
append project_name "_"
append project_name $script_ref
#puts $project_name
set path_src [string trimright $path_file $script_name]
set path_src [string trimright $path_src "/"]
puts $path_src
set package_reference xilinx_v1902
set path_vw C:/vw_v1902
set path_project $path_vw/$project_name/
set path_src_ip $path_src/src_ip
set path_src_bd $path_src/src_bd
set path_src_common $path_src/../src_common
set path_src_pkg $path_src/../src_pkg
set path_src_rx $path_src/../src_rx
set path_src_tx $path_src/../src_tx
set path_src_tx_rx $path_src/../src_tx_rx
set path_src_rx_ip $path_src/../src_rx_ip
set path_src_tx_rx_ip $path_src/../src_tx_rx_ip
set path_src_tx $path_src/../src_tx
set path_src_tx_emulator $path_src/../src_tx_emulator
set path_src_tb_top $path_src/src_tb_top
set path_src_top $path_src/src_top
set path_xdc $path_src/xdc
set synth_top tx_rx_esistream_top
set sim_name sim_1
set sim_top tb_tx_rx_esistream_top
set tb_log_path $path_vw/tb_log.txt
# .xci files:
set ip_files [list \
     axi_uartlite_0\
     clk_wizard_0\
     add_u12\
     axis_ila_64b\
		 ]
# .bd files
set bd_files [list \
     gty_txrx_8lanes_64b\
     edt_versal\
                 ]

if { [lindex $argv 0] == 0 | $argc != 1 } {
    # Delete previous project
    file delete -force -- $path_project
     
    puts "script.tcl: delete previous project done."
     
    # Create project
    create_project -name $project_name -dir $path_project
    # Set project properties
    set obj [current_project]
    set_property part $fpga_ref $obj
    set_property target_language VHDL $obj
    set_property -name "board_part" -value $board_ref -objects $obj
    set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
    set_property -name "enable_vhdl_2008" -value "1" -objects $obj
    set_property -name "mem.enable_memory_map_generation" -value "1" -objects $obj
    set_property -name "platform.board_id" -value $platform_board_id -objects $obj
    set_property -name "revised_directory_structure" -value "1" -objects $obj
    set_property -name "simulator_language" -value "Mixed" -objects $obj
    set_property -name "xpm_libraries" -value "XPM_CDC XPM_FIFO XPM_MEMORY" -objects $obj
     
    puts "script.tcl: create project done."
     
    # Import ip:
    foreach ip_file $ip_files {
     import_ip $path_src_ip/$ip_file.xci
     reset_target {all} [get_ips $ip_file]
     generate_target {all} [get_ips $ip_file]
    }
    
    # Import bd:
    foreach bd_file $bd_files {
     # Create bd file vivado workspace directory:
     set bd_dir $path_project/$project_name.srcs/sources_1/bd/$bd_file
     file mkdir $bd_dir
     # import bd file in vivado workspace
     file copy -- $path_src_bd/$bd_file.bd $bd_dir
     # add bd file to vivado project
     add_files -norecurse $bd_dir/$bd_file.bd
     # call make_wrapper to create wrapper file
     set wrapper_path [make_wrapper -fileset sources_1 -files [ get_files -norecurse $bd_file.bd] -top]
     # add bd wrapper file
     add_files -norecurse -fileset sources_1 $wrapper_path
    }
 
    puts "script.tcl: import and reset ip(s) done."
     
    # Add vhdl files 
    add_files $path_src_top/
    add_files $path_src_common/sysreset.vhd
    add_files $path_src_common/axi4_lite_master.vhd
    add_files $path_src_common/delay.vhd
    add_files $path_src_common/delay_prog.vhd
    add_files $path_src_common/ff_synchronizer_array.vhd
    add_files $path_src_common/register_map.vhd
    add_files $path_src_common/register_map_fsm.vhd
    add_files $path_src_common/risingedge.vhd
    add_files $path_src_common/risingedge_array.vhd
    add_files $path_src_common/sync_generator.vhd
    add_files $path_src_common/timer.vhd
    add_files $path_src_common/two_flop_synchronizer.vhd
    add_files $path_src_common/uart_wrapper.vhd
    add_files $path_src_common/axis_ila_wrapper_64b.vhd
    add_files $path_src_common/sync_generator.vhd    
    add_files $path_src_common/spi_dual_master.vhd
    add_files $path_src_common/spi_dual_master_fsm.vhd
    add_files $path_src_common/spi_fifo.vhd
    add_files $path_src_common/spi_refclk.vhd
    add_files $path_src_rx/rx_delay.vhd
    add_files $path_src_rx/rx_xpm_async_fifo.vhd
    add_files $path_src_rx/rx_xpm_output_buffer.vhd
    add_files $path_src_rx/rx_lfsr_init.vhd
    add_files $path_src_rx/rx_control.vhd
    add_files $path_src_rx/rx_frame_alignment.vhd
    add_files $path_src_rx/rx_decoding.vhd
    add_files $path_src_rx/rx_lane_decoding.vhd
    add_files $path_src_rx/rx_esistream.vhd
    add_files $path_src_tx/tx_disparity_word_16b.vhd
    add_files $path_src_tx/tx_disparity.vhd
    add_files $path_src_tx/tx_lfsr.vhd
    add_files $path_src_tx/tx_scrambling.vhd
    add_files $path_src_tx/tx_encoding.vhd
    add_files $path_src_tx/tx_esistream.vhd
    add_files $path_src_tx_rx/tx_rx_esistream_with_xcvr.vhd
    add_files $path_src_tx_rx_ip/tx_rx_xcvr_wrapper_64b.vhd
    #add_files $path_src_rx_ip/rx_output_buffer_wrapper.vhd
    add_files $path_src_pkg/esistream_pkg_64b.vhd
    add_files $path_src_tx_emulator/tx_emu_data_gen.vhd
    add_files $path_src_tx_emulator/tx_emu_data_gen_top.vhd
    add_files $path_src_tx_emulator/txrx_frame_checking.vhd
     
    # Set top file:
    set_property top $synth_top [current_fileset]
    update_compile_order -fileset sources_1
     
    # Set simulation:
    add_files -fileset $sim_name -norecurse $path_src_tb_top/
    set_property top $sim_top [get_filesets $sim_name]
    set_property top_lib xil_defaultlib [get_filesets $sim_name]
    update_compile_order -fileset $sim_name
    # Set simulation runtime default value:
    #set_property -name {xsim.simulate.runtime} -value {15000ns} -objects [get_filesets $sim_name]
    # Generate simulation scrips only:
    launch_simulation -scripts_only -absolute_path -simset $sim_name
    #launch_simulation -scripts_only -simset $sim_name
     
    # Set constraint files:
    add_files -fileset constrs_1 $path_xdc/${synth_top}_64b.xdc
     
    puts "script.tcl: add files done."
    close_project
} elseif { [lindex $argv 0] > 0 } {
    puts "-- runtime us:"
    puts [lindex $argv 0]

    file delete -force -- $path_project/${project_name}.sim
    
    set path_xpr $path_project/$project_name.xpr
    puts "-- Open project"
    open_project $path_xpr
    puts "-- Launch simulation"
    launch_simulation -simset [get_filesets $sim_name]

    puts "-- runtime update us"
    run [lindex $argv 0] us

    puts "-- Close simulation"
    close_sim
    
    puts "-- Close project"
    close_project
} elseif { [lindex $argv 0] < 0 } {
    # SYNTHESIZE, IMPLEMENT AND GENERATE BITSTREAM
    set path_xpr $path_project/$project_name.xpr
    puts "-- Open project"
    open_project $path_xpr
    
    file delete -force -- $path_project/${project_name}.runs
    
    # Synthesize project
    reset_run synth_1
    # foreach ip_file $ip_files {
    #  	reset_run ${ip_file}_synth_1
    #  	puts ${ip_file}_synth_1
    # }
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
    puts "-- wait_on_run synth_1"
   
    # # Implement project
    # reset_run impl_1
    # launch_runs impl_1 -jobs 2
    # wait_on_run impl_1

    # Implement and generate bitstream:
    update_compile_order -fileset sources_1
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1
    puts "-- wait_on_run impl_1"

    # WRITE TB LOG FILE
    
    # If the synth_1 run completed successfully, the value will be "synth_design Complete!",
    # If it failed due to an error, then it will be "synth_design ERROR".
    set flog [open $tb_log_path a]
    set status [get_property STATUS [get_runs synth_1]]
    puts $flog $status
    puts "-- synthesis log"
    
    # The impl_1 run has a similar STATUS property, but has many more potential values:
    # it may end with "place_design ERROR", "route_design ERROR", presumably a number of others, or,
    # if it succeeds "route_design Complete!".
    set status [get_property STATUS [get_runs impl_1]]
    puts $flog $status
    puts "-- implementation log"

    # If these are both 0 then your design meets timing.
    # WNS = Worst Negative Slack
    # TNS = Total Negative Slack = sum of the negative slack paths
    # WHS = Worst Hold Slack
    # THS = Total Hold Slack = sum of the negative hold slack paths
    set status [get_property STATS.WNS [get_runs impl_1]]
    puts $flog $status
    set status [get_property STATS.WHS [get_runs impl_1]]
    puts $flog $status
    puts "-- timing constraints log"

    close $flog
    # ---------
    puts "-- Close project"
    close_project
    
}

