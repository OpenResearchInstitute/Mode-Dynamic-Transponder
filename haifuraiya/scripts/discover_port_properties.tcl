# =============================================================================
# discover_port_properties.tcl
# =============================================================================
#
# Diagnostic helper. Opens the IP and dumps all properties of an existing
# vector port so we can see what the correct property names are for setting
# vector left/right (the names depend on Vivado version).
#
# Usage:
#   vivado -mode batch -source haifuraiya/scripts/discover_port_properties.tcl
# =============================================================================

set script_dir    [file dirname [file normalize [info script]]]
set ip_root       [file normalize "${script_dir}/.."]
set component_xml "${ip_root}/component.xml"

catch {close_project}
ipx::open_core $component_xml

# m_axis_chans_tdata is a known 32-bit vector port -- a perfect reference.
puts ""
puts "=== Properties of m_axis_chans_tdata (32-bit vector reference) ==="
set p [ipx::get_ports m_axis_chans_tdata -of_objects [ipx::current_core]]
report_property $p

puts ""
puts "=== List of all property NAMES on this port ==="
foreach prop_info [list_property -class [get_property CLASS $p]] {
    puts "  $prop_info"
}

puts ""
puts "=== For comparison: properties of m_axis_chans_tvalid (1-bit scalar) ==="
set q [ipx::get_ports m_axis_chans_tvalid -of_objects [ipx::current_core]]
report_property $q
