# vck190_esi_link.xdc -- tier 2 (ESIstream digital loopback): the GTY quad's pins
# and clocks.  Added to the project only when VCK190_TIER=2
# (vck190_playback_project.tcl).  Everything else in the design -- DDR, the PL
# clock -- is constrained by the CIPS/NoC IP from the board part.
#
# Where the numbers come from (VCK190 Evaluation Board User Guide, UG1366,
# "GTY transceivers" and "FMC1 HSPC" tables; the lane pins are the same ones
# Teledyne's xm107 constraints use for lanes 0 and 1):
#
#   GTY quad 201 (bank 201) is the quad whose channels 0-3 are FMC1 DP0-DP3.
#     ch0  TX AB7/AB6   RX AB2/AB1        <- lane 0
#     ch1  TX AA9/AA8   RX AA4/AA3        <- lane 1
#   refclk0 of quad 201 = SI570_8A34001_MUX_BUF0 on AB11 (P) / AB10 (N):
#     the user SI570 (U205) through the SI53340 buffer when J306 is OFF (the
#     default).  It powers up at 100.000 MHz and is programmed to 156.25 MHz
#     over I2C (address 0x5F) after every power cycle -- VCK190_USER_GUIDE.md,
#     "Program the GT reference clock".  Tier 3 moves the refclk to refclk1 =
#     FMC1_GBTCLK0 (M15/M14), the ADC's SSO; same frequency, same GT config.
#
# Block-design port names (make_wrapper): esi_refclk_clk_p/n and
# esi_gt_{grx,gtx}_{p,n}[3:0]; lanes 2 and 3 of the quad exist as ports but
# carry nothing and are left to the placer (they stay in the same quad).

# --- GT reference clock: 156.25 MHz = 6.400 ns ------------------------------------
set_property PACKAGE_PIN AB11 [get_ports esi_refclk_clk_p]
set_property PACKAGE_PIN AB10 [get_ports esi_refclk_clk_n]
create_clock -period 6.400 -name esi_gt_refclk [get_ports esi_refclk_clk_p]

# --- serial lanes: quad 201 channels 0 and 1 = FMC1 DP0 and DP1 -----------------------
set_property PACKAGE_PIN AB7 [get_ports {esi_gt_gtx_p[0]}]
set_property PACKAGE_PIN AB6 [get_ports {esi_gt_gtx_n[0]}]
set_property PACKAGE_PIN AB2 [get_ports {esi_gt_grx_p[0]}]
set_property PACKAGE_PIN AB1 [get_ports {esi_gt_grx_n[0]}]
set_property PACKAGE_PIN AA9 [get_ports {esi_gt_gtx_p[1]}]
set_property PACKAGE_PIN AA8 [get_ports {esi_gt_gtx_n[1]}]
set_property PACKAGE_PIN AA4 [get_ports {esi_gt_grx_p[1]}]
set_property PACKAGE_PIN AA3 [get_ports {esi_gt_grx_n[1]}]

# --- clock relationships ----------------------------------------------------------------
# The GT user clocks (ch0 txoutclk and rxoutclk through the BUFG_GTs) are
# asynchronous to the 100 MHz PL clock (clk_pl_0) and to each other; every
# crossing in esi_link_hw / esi_link_loop is a two-flop synchronizer, a
# toggle handshake, or an XPM/axis async FIFO, so no path between them is a
# timing path.  Teledyne's example does the same with set_false_path pairs.
# The clock names are what the quad IP creates; this is resolved late (after
# the IP's own constraints) so the names exist by then.
set_clock_groups -asynchronous -quiet \
    -group [get_clocks clk_pl_0] \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *bufg_gt_tx*/O}]] \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *bufg_gt_rx*/O}]]
