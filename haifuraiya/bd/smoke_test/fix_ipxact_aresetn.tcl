# ============================================================================
# Fix: Remove erroneous ASSOCIATED_BUSIF from aresetn bus interface
# ============================================================================
#
# Yesterday's packaging session incorrectly added ASSOCIATED_BUSIF to the
# aresetn bus interface, mirroring what we did on aclk. The convention is
# asymmetric: ASSOCIATED_BUSIF belongs on clocks, not resets. The reset's
# association with bus interfaces is inferred via aclk's ASSOCIATED_RESET
# parameter, which is already correctly set.
#
# Symptom (in any BD that instantiates this IP):
#   CRITICAL WARNING: [BD 41-1732] Bus interface 'X' is found to be
#   associated with multiple clock-pins. List of associated clock-pins:
#     aclk, aresetn
#
# Usage:
#   source /path/to/haifuraiya/bd/smoke_test/fix_ipxact_aresetn.tcl
#
# Or in batch:
#   cd /path/to/haifuraiya
#   vivado -mode batch -source bd/smoke_test/fix_ipxact_aresetn.tcl
# ============================================================================

# Path resolution from script location
set script_dir [file dirname [file normalize [info script]]]
set ip_repo_path [file normalize "${script_dir}/../.."]
set component_xml "${ip_repo_path}/component.xml"

if {![file exists $component_xml]} {
    puts "ERROR: No component.xml found at $component_xml"
    return
}

puts "INFO: Opening IP at $component_xml"

# Close any open project to avoid conflicts
catch {close_project}

# Open the core for editing. This makes the IP-XACT the current core
# for subsequent ipx:: operations, no project context required.
ipx::open_core $component_xml

# Verify the parameter exists before trying to remove it
set aresetn_bif [ipx::get_bus_interfaces aresetn -of_objects [ipx::current_core]]
set bad_params [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $aresetn_bif]

if {[llength $bad_params] == 0} {
    puts "INFO: aresetn has no ASSOCIATED_BUSIF parameter - nothing to remove."
    puts "      Either you've already fixed this, or the bug never existed in this IP."
    return
}

puts "INFO: Found ASSOCIATED_BUSIF on aresetn (the bug). Removing it..."
ipx::remove_bus_parameter ASSOCIATED_BUSIF $aresetn_bif

# Verify removal
set check [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $aresetn_bif]
if {[llength $check] != 0} {
    puts "ERROR: Failed to remove ASSOCIATED_BUSIF from aresetn."
    return
}

# Verify aclk's ASSOCIATED_RESET is still in place (this is what
# actually associates the reset with the bus interfaces)
set aclk_bif [ipx::get_bus_interfaces aclk -of_objects [ipx::current_core]]
set aclk_assoc_reset [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $aclk_bif]

if {[llength $aclk_assoc_reset] == 0} {
    puts "WARNING: aclk does not have ASSOCIATED_RESET. The reset may not be"
    puts "         properly associated with the buses without this."
    puts "         Consider adding it manually:"
    puts "           ipx::add_bus_parameter ASSOCIATED_RESET \$aclk_bif"
    puts "           set_property value aresetn \[ipx::get_bus_parameters ASSOCIATED_RESET -of \$aclk_bif\]"
} else {
    set v [get_property value $aclk_assoc_reset]
    puts "INFO: aclk's ASSOCIATED_RESET = '$v' (this is what associates the reset)"
}

# Save the corrected IP
ipx::save_core [ipx::current_core]
puts "INFO: Saved corrected component.xml"

# Report
puts ""
puts "============================================================="
puts "  IP-XACT aresetn fix applied."
puts ""
puts "  Removed: ASSOCIATED_BUSIF from aresetn bus interface"
puts "  Reason:  This parameter belongs on clocks, not resets."
puts "           Reset-to-bus association is inferred via aclk's"
puts "           ASSOCIATED_RESET parameter (still in place)."
puts ""
puts "  Re-run the smoke test to confirm the CRITICAL WARNINGs are gone:"
puts "    source ${script_dir}/bd_smoke_test.tcl"
puts "============================================================="
