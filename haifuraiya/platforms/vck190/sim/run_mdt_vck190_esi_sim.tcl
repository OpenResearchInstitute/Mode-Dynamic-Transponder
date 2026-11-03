################################################################################
# run_mdt_vck190_esi_sim.tcl -- tier 2: ESIstream digital loopback in the
# sample path, same stimulus and grade as tier 1.
#
# Open Research Institute -- Mode-Dynamic Transponder (Haifuraiya) VCK190 shell
# License: CERN-OHL-S-2.0
#
# This is the tier-1 runner with one switch thrown.  Everything else (part,
# board, core manifest, stimulus staging, waveform layout) is the same file,
# so the two tiers cannot drift apart.  See run_mdt_vck190_sim.tcl USAGE.
#
# USAGE (Vivado TCL console on chococat):
#   source /path/to/haifuraiya/platforms/vck190/sim/run_mdt_vck190_esi_sim.tcl
# Pass: "ALL TESTS PASSED" (which now includes the "ESI link" check) and the
# same 25/25 frame grade as tier 1 on the soft-bit file.
################################################################################
set ESI_LOOP 1
source [file join [file dirname [info script]] run_mdt_vck190_sim.tcl]
