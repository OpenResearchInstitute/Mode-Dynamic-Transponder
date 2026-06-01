# =============================================================================
# repackage_add_dbg_ports.tcl
# =============================================================================
#
# One-shot IP repackaging for the haifuraiya_channelizer_axi IP. Adds the
# fifteen dbg_* output ports that were added to the entity for ILA debugging
# of the channelizer -> power_detector signal path on hardware.
#
# Once these are in component.xml, the BD's `ad_connect channelizer_rx1/
# dbg_*  ila_channelizer_pd/probeN` lines in system_bd.tcl will be able
# to find the ports and route correctly.
#
# Follows the same `ipx::open_core` pattern as fix_ipxact_aresetn.tcl
# and repackage_no_coeff_file.tcl -- no project context needed.
#
# IPX property names (per Vivado 2022.2; confirmed by discover script):
#   DIRECTION           out
#   IS_VECTOR           true  for vectors, false (or unset) for scalars
#   SIZE_LEFT/RIGHT     vector range (only set for vectors)
#   TYPE_NAME           std_logic_vector for vectors, std_logic for scalars
#   VIEW_NAME_REFS      synthesis + behavioral simulation views
#
# Usage (once, from repo root):
#   vivado -mode batch -source haifuraiya/scripts/repackage_add_dbg_ports.tcl
#
# After it succeeds:
#   1. git diff haifuraiya/component.xml   (sanity-check the new ports)
#   2. git add + commit
#   3. make haifuraiya-xsa-integrated CMOS_LVDS_N=0  (rebuild with ILA)
# =============================================================================

# Path resolution from script location
set script_dir    [file dirname [file normalize [info script]]]
set ip_root       [file normalize "${script_dir}/.."]
set component_xml "${ip_root}/component.xml"

# Sanity
if {![file exists $component_xml]} {
    puts "ERROR: component.xml not found at $component_xml"
    return
}

puts "INFO: Opening IP at $component_xml"
catch {close_project}
ipx::open_core $component_xml

# -----------------------------------------------------------------------------
# Port table.
# Each entry:  { name  left_index }
#   left_index = -1   -> scalar std_logic
#   left_index = N    -> vector std_logic_vector(N downto 0), width = N+1
# All fifteen dbg_* ports are direction = out.
#   dbg_pd0_* are channel-0 power-detector internals (dsum/ema), width 31 -> left=30.
# -----------------------------------------------------------------------------
set dbg_ports [list \
    [list dbg_chan_re_q       15] \
    [list dbg_chan_im_q       15] \
    [list dbg_chan_valid_r    -1] \
    [list dbg_chan_idx_int_r   5] \
    [list dbg_chan_valid      -1] \
    [list dbg_chan_idx_int     5] \
    [list dbg_pd_data_ena     63] \
    [list dbg_core_reset      -1] \
    [list dbg_core_dropped    -1] \
    [list dbg_chan_last       -1] \
    [list dbg_pd0_dsum         30] \
    [list dbg_pd0_dsum_e2      -1] \
    [list dbg_pd0_ema_1        30] \
    [list dbg_pd0_ema_1_ena    -1] \
    [list dbg_pd0_ema_2        30] \
]

set added 0
set skipped 0

foreach entry $dbg_ports {
    lassign $entry name left

    set existing [ipx::get_ports $name -of_objects [ipx::current_core]]
    if {[llength $existing] > 0} {
        puts "INFO: port $name already present in component.xml -- skipping"
        incr skipped
        continue
    }

    puts "INFO: Adding port $name [expr {$left < 0 ? "(scalar)" : "(vector \[$left:0\])"}]"
    set port [ipx::add_port $name [ipx::current_core]]
    set_property direction      out  $port
    set_property view_name_refs "xilinx_anylanguagesynthesis xilinx_anylanguagebehavioralsimulation" $port

    if {$left >= 0} {
        # Vector port
        set_property is_vector  true              $port
        set_property size_left  $left             $port
        set_property size_right 0                 $port
        set_property type_name  std_logic_vector  $port
    } else {
        # Scalar port
        set_property type_name  std_logic         $port
    }

    incr added
}

# -----------------------------------------------------------------------------
# Save and report
# -----------------------------------------------------------------------------
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums  [ipx::current_core]
ipx::save_core         [ipx::current_core]

puts ""
puts "============================================================="
puts "  Repackaging complete."
puts ""
puts "  dbg_* ports added:   $added"
puts "  dbg_* ports skipped: $skipped (already present)"
puts ""
puts "  Next:"
puts "    1. Review: git diff haifuraiya/component.xml"
puts "       (expect ~30 lines of new spirit:port entries)"
puts "    2. git add haifuraiya/component.xml && git commit"
puts "    3. Make sure system_bd.tcl has the ILA block appended"
puts "    4. Rebuild: make haifuraiya-xsa-integrated CMOS_LVDS_N=0"
puts "============================================================="
