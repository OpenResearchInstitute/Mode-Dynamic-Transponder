# ============================================================================
# Block Design Smoke Test for haifuraiya_channelizer_axi v0.1
# ============================================================================
# Phase 1 Task 8: confirm the packaged IP instantiates cleanly in a block
# design, with AXI VIPs on its three interfaces, and passes Validate Design.
#
# Usage (from a fresh Vivado session, no project open):
#   In Tcl console:
#     source /path/to/haifuraiya/bd/smoke_test/bd_smoke_test.tcl
#
# Or batch mode:
#   cd /path/to/haifuraiya/bd/smoke_test
#   vivado -mode batch -source bd_smoke_test.tcl
#
# Requirements:
#   - Vivado 2022.2
#   - The script must live at <repo>/haifuraiya/bd/smoke_test/bd_smoke_test.tcl
#     (the script discovers the IP repo by walking up two directories)
#   - Verification IPs available: axi4stream_vip, axi_vip, clk_vip, rst_vip
#   - Target part: xczu9eg-ffvb1156-2-e (ZCU102)
#
# What this proves:
#   Phase 1 Task 8 - the packaged IP can be instantiated in a block design,
#   its three AXI bus interfaces wire to standard verification IPs cleanly,
#   clock/reset associations work, address space populates from the IP-XACT
#   memory map, and Validate Design passes without errors.
#
# Portability note:
#   The ip_repo_path is derived from this script's own location, so it works
#   from any working tree (brown, orange, burnt_sienna, mauve, etc.) without
#   editing the script. The script expects to live two directories below
#   the IP repo root (in haifuraiya/bd/smoke_test/).
# ============================================================================

# --- Path resolution (no more hardcoded crayon-box paths) -----------------

# Resolve absolute path to this script, regardless of how it was invoked
set script_dir [file dirname [file normalize [info script]]]

# Walk two directories up: bd/smoke_test/ -> bd/ -> haifuraiya/
set ip_repo_path [file normalize "${script_dir}/../.."]

puts "INFO: Script directory: $script_dir"
puts "INFO: Resolved IP repo path: $ip_repo_path"

# --- Parameters -----------------------------------------------------------

# Where to create the throwaway smoke-test project
set project_dir "/tmp/haifuraiya_smoke_test"

# Project + BD names
set project_name "haifuraiya_smoke_test"
set bd_name      "smoke_test_bd"

# Target part (ZCU102's main FPGA)
set part "xczu9eg-ffvb1156-2-e"

# IP version components (must match what we packaged)
set ip_vendor   "openresearch.institute"
set ip_library  "ip"
set ip_name     "haifuraiya_channelizer_axi"
set ip_version  "0.1"

# --- Sanity: verify the IP repo path exists -------------------------------

if {![file exists "$ip_repo_path/component.xml"]} {
    puts "ERROR: No component.xml found at resolved path $ip_repo_path"
    puts "       This script expects to live at <repo>/haifuraiya/bd/smoke_test/"
    puts "       so it can find the IP repo two directories up."
    puts "       Either move this script to that location, or edit the path"
    puts "       resolution logic at the top of the script."
    return
}
puts "INFO: Found component.xml at $ip_repo_path"

# --- Project setup --------------------------------------------------------

# Defensively close any currently open project
catch {close_project}

# Clean any prior attempt (smoke test is disposable)
file delete -force $project_dir

create_project $project_name $project_dir -part $part
puts "INFO: Created project $project_name at $project_dir"

# Point at the Haifuraiya IP repository and refresh the catalog
set_property ip_repo_paths [list $ip_repo_path] [current_project]
update_ip_catalog
puts "INFO: IP catalog refreshed with $ip_repo_path"

# Sanity: confirm the IP shows up in the catalog
set ip_def_full "${ip_vendor}:${ip_library}:${ip_name}:${ip_version}"
set found [get_ipdefs -filter "VLNV == \"$ip_def_full\""]
if {[llength $found] == 0} {
    puts "ERROR: IP $ip_def_full not visible in catalog after update_ip_catalog."
    puts "       Check that component.xml at $ip_repo_path matches the expected VLNV."
    return
}
puts "INFO: Confirmed $ip_def_full is in the catalog"

# Sanity: confirm VIPs are available
foreach vip {axi4stream_vip axi_vip clk_vip rst_vip} {
    set v [get_ipdefs -filter "NAME == \"$vip\""]
    if {[llength $v] == 0} {
        puts "ERROR: $vip not found in catalog. Verification IPs may not be installed."
        return
    }
}
puts "INFO: All required Verification IPs available."

# --- Create the block design ----------------------------------------------

create_bd_design $bd_name
puts "INFO: Created block design $bd_name"

# --- Add IPs --------------------------------------------------------------

# Clock generator (sim-only) - drives 100 MHz aclk
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_vip:1.0 clk_gen_0

# Reset generator (sim-only) - drives aresetn
# NOTE: rst_vip has NO clock input pin. It's a simple passthrough/master
# generator. We connect only rst_out (and optionally rst_in if monitoring).
create_bd_cell -type ip -vlnv xilinx.com:ip:rst_vip:1.0 rst_gen_0

# Haifuraiya channelizer (our IP under test)
create_bd_cell -type ip -vlnv $ip_def_full haifuraiya_0

# AXIS source (drives s_axis_data input)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi4stream_vip:1.1 axis_src_0

# AXIS sink (receives m_axis_chans output)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi4stream_vip:1.1 axis_snk_0

# AXI master (drives s_axi_ctrl control plane)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 axi_master_0

puts "INFO: Instantiated 6 IPs in block design"

# --- Save BD early so partial state survives any subsequent error --------

save_bd_design
puts "INFO: Saved BD with cells (pre-configuration) - on-disk checkpoint"

# --- Configure IPs --------------------------------------------------------

# Configure clk_vip for 100 MHz master clock output
set_property -dict [list \
    CONFIG.INTERFACE_MODE {MASTER} \
    CONFIG.FREQ_HZ {100000000} \
] [get_bd_cells clk_gen_0]

# Configure rst_vip for ACTIVE_LOW polarity (matches our IP's aresetn)
set_property -dict [list \
    CONFIG.INTERFACE_MODE {MASTER} \
    CONFIG.RST_POLARITY {ACTIVE_LOW} \
] [get_bd_cells rst_gen_0]

# Configure AXIS source to match Haifuraiya s_axis_data:
#   TDATA = 32 bits (Q[15:0] in high half + I[15:0] in low half)
#   No TLAST/TKEEP/TSTRB
set_property -dict [list \
    CONFIG.INTERFACE_MODE {MASTER} \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.HAS_TLAST {0} \
    CONFIG.HAS_TKEEP {0} \
    CONFIG.HAS_TSTRB {0} \
] [get_bd_cells axis_src_0]

# Configure AXIS sink to match Haifuraiya m_axis_chans:
#   TDATA = 32 bits per channel
#   TDEST = 8 bits (channel index 0..63)
#   TLAST present (channel_last)
set_property -dict [list \
    CONFIG.INTERFACE_MODE {SLAVE} \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.TDEST_WIDTH {8} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TKEEP {0} \
    CONFIG.HAS_TSTRB {0} \
] [get_bd_cells axis_snk_0]

# Configure AXI master VIP for AXI-Lite, 12-bit address (matches our IP default)
set_property -dict [list \
    CONFIG.INTERFACE_MODE {MASTER} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {12} \
    CONFIG.DATA_WIDTH {32} \
] [get_bd_cells axi_master_0]

puts "INFO: Configured all IPs"

# --- Wire it all up -------------------------------------------------------

# Distribute the clock to every block that has an aclk pin
# (rst_vip is NOT in this list - it has no clock pin)
set clk_pin [get_bd_pins clk_gen_0/clk_out]
connect_bd_net $clk_pin [get_bd_pins haifuraiya_0/aclk]
connect_bd_net $clk_pin [get_bd_pins axis_src_0/aclk]
connect_bd_net $clk_pin [get_bd_pins axis_snk_0/aclk]
connect_bd_net $clk_pin [get_bd_pins axi_master_0/aclk]

# Distribute the reset to every block that has an aresetn pin
set rst_pin [get_bd_pins rst_gen_0/rst_out]
connect_bd_net $rst_pin [get_bd_pins haifuraiya_0/aresetn]
connect_bd_net $rst_pin [get_bd_pins axis_src_0/aresetn]
connect_bd_net $rst_pin [get_bd_pins axis_snk_0/aresetn]
connect_bd_net $rst_pin [get_bd_pins axi_master_0/aresetn]

# AXIS source -> Haifuraiya s_axis_data
connect_bd_intf_net \
    [get_bd_intf_pins axis_src_0/M_AXIS] \
    [get_bd_intf_pins haifuraiya_0/s_axis_data]

# Haifuraiya m_axis_chans -> AXIS sink
connect_bd_intf_net \
    [get_bd_intf_pins haifuraiya_0/m_axis_chans] \
    [get_bd_intf_pins axis_snk_0/S_AXIS]

# AXI master -> Haifuraiya s_axi_ctrl
connect_bd_intf_net \
    [get_bd_intf_pins axi_master_0/M_AXI] \
    [get_bd_intf_pins haifuraiya_0/s_axi_ctrl]

puts "INFO: All interfaces wired"

# --- Save BD after wiring (second checkpoint) -----------------------------

save_bd_design
puts "INFO: Saved BD with full wiring - second on-disk checkpoint"

# --- Assign address ranges ------------------------------------------------

# This consumes the IP-XACT memory map we encoded last night (72 registers).
# Vivado finds the s_axi_ctrl/reg0 segment from component.xml and assigns it.
assign_bd_address [get_bd_addr_segs haifuraiya_0/s_axi_ctrl/reg0]
puts "INFO: Assigned address space for s_axi_ctrl/reg0"

# --- Validate -------------------------------------------------------------

regenerate_bd_layout

set valid_result [catch {validate_bd_design} valid_msg]
save_bd_design

# --- Report --------------------------------------------------------------

puts ""
puts "============================================================="
if {$valid_result == 0} {
    puts "  PHASE 1 TASK 8: SMOKE TEST SUCCESS"
    puts ""
    puts "  Block design '$bd_name' validates cleanly with:"
    puts "    - clk_vip @ 100 MHz driving aclk"
    puts "    - rst_vip (ACTIVE_LOW) driving aresetn"
    puts "    - axi4stream_vip (master) -> s_axis_data"
    puts "    - m_axis_chans -> axi4stream_vip (slave)"
    puts "    - axi_vip (master, AXI-Lite) -> s_axi_ctrl"
    puts "    - 72-register memory map mapped at 0x00000000 (range 0x1000)"
    puts ""
    puts "  The Haifuraiya IP is now confirmed BD-integratable."
    puts "  Phase 1 is closed."
} else {
    puts "  PHASE 1 TASK 8: VALIDATION FAILED"
    puts ""
    puts "  validate_bd_design returned errors:"
    puts "    $valid_msg"
    puts ""
    puts "  See the messages tab in the Vivado GUI for details."
    puts "  BD is saved at:"
    puts "    ${project_dir}/${project_name}.srcs/sources_1/bd/${bd_name}/${bd_name}.bd"
}
puts "============================================================="
puts ""
puts "Project location: $project_dir"
puts "Block design:     ${project_dir}/${project_name}.srcs/sources_1/bd/${bd_name}/${bd_name}.bd"
