################################################################################
# run_mdt_vck190_sim.tcl
# Vivado project bootstrap for the MDT core on the VCK190 (Versal VC1902)
#
# Open Research Institute
# Project: Mode-Dynamic Transponder (Haifuraiya configuration) VCK190 shell
# Target:  VCK190 eval board (xcvc1902-vsva2197-2MP-e-S)
# Tools:   Vivado 2022.2, VHDL-2008
# License: CERN-OHL-S-2.0
#
# Location: haifuraiya/platforms/vck190/sim/  (paths below assume this)
#
# ------------------------------------------------------------------------------
# DOCTRINE
# ------------------------------------------------------------------------------
# One core, two shells. The signal-processing core (haifuraiya/rtl/) is the
# same source that the ZCU102 runs. 
# Everything VCK190-specific lives under haifuraiya/platforms/vck190/. 
# The ZCU102 build is the working reference.
#
# This script is built part by part. Each PART below is complete and runs good
# before the next is added. Later parts assume earlier ones succeeded.
#
#   PART 1  project bootstrap: environment gate, create project, target part
#   PART 2  source manifest: core RTL via safe_add_files
#   PART 3  (pending) testbench + VHDL-2008 properties + stimulus staging
#   PART 4  (pending) launch_simulation + waveform layout
#
# USAGE (from the Vivado TCL console on chococat):
#   source /path/to/haifuraiya/platforms/vck190/sim/run_mdt_vck190_sim.tcl
#
# PREREQUISITES
#   - Submodules initialized (sim set only):
#       git submodule update --init haifuraiya/third_party/power_detector \
#                                   haifuraiya/third_party/lowpass_ema
#   - Stimulus generated (Part 3 stages it; see sim/opv_stim.py --out)
################################################################################

################################################################################
# PART 1 -- project bootstrap
################################################################################

# --- environment gate --------------------------------------------------------
# Baseline is Vivado 2022.2. The ESIstream VCK190 package carries board ref
# vck190:part0:2.2 (measured from the package project script, 2026-10), which
# is satisfied by the 2022.x board store. Other versions may work; this gate
# WARNS loudly rather than just dying, so an intentional version experiment is
# possible, but the warning goes in the log where it cannot be unseen.
set EXPECTED_VIVADO "2022.2"
set this_vivado [version -short]
if {![string match "${EXPECTED_VIVADO}*" $this_vivado]} {
    puts "*** WARNING ********************************************************"
    puts "*** Vivado $this_vivado, baseline is $EXPECTED_VIVADO."
    puts "*** Proceeding, but any anomaly is suspect #1: re-run on $EXPECTED_VIVADO"
    puts "*** before filing a bug against the RTL."
    puts "********************************************************************"
}

# Close any existing simulation
catch {close_sim -force}

# Change to script directory for consistent relative path resolution
cd [file dirname [info script]]

# --- identity ----------------------------------------------------------------
set project_name "mdt_vck190_sim"
set project_dir  "./mdt_vck190_sim_project"

# Part string measured from the ESIstream VCK190 package (script_64b.tcl):
# keeping our target identical to the vendor deliverable's means the two
# projects don't fight too much.
set part_name    "xcvc1902-vsva2197-2MP-e-S"
set board_ref    "xilinx.com:vck190:part0:2.2"

# --- create clean project ----------------------------------------------------
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "========================================"
puts "MDT core on VCK190 -- simulation project"
puts "Project:     $project_name"
puts "Part:        $part_name (VCK190, Versal VC1902)"
puts "Vivado:      $this_vivado (baseline $EXPECTED_VIVADO)"
puts "Working dir: [pwd]"
puts "========================================"

create_project $project_name $project_dir -part $part_name

# --- board targeting, with gracefull fallback -------------------------------
# The board file matters little for behavioral simulation (the part string is
# what xsim elaborates against) but setting it now means the SAME project
# bootstrap serves the later synthesis and block-design parts, where the board
# file supplies pin and interface presets. If this install's board store lacks
# vck190 2.2, we say so and continue part-only, which is not too bad.
if {[catch {set_property board_part $board_ref [current_project]} msg]} {
    puts "*** NOTE: board_part $board_ref not available in this install."
    puts "***       ($msg)"
    puts "***       Continuing PART-ONLY. Fine for simulation; install the"
    puts "***       VCK190 board files (Vivado XHub store) before the"
    puts "***       synthesis/BD parts of this flow."
    set board_state "part-only"
} else {
    puts "  OK board_part = $board_ref"
    set board_state "board"
}

# --- helper: add files that exist, log the ones that don't --------------------
# Carried over from the ZCU102 flow: a missing file is a loud SKIP in the log,
# and it helped there quite a lot with debugging.
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

puts ""
puts "PART 1 complete: project created ($board_state)."

################################################################################
# PART 2 -- source manifest: the MDT core
################################################################################
# This manifest is the ZCU102 manifest (run_haifuraiya_channelizer_axi_test.tcl)
# re-rooted from haifuraiya/sim/ to haifuraiya/platforms/vck190/sim/ -- three
# levels up instead of one. Same files, same order, verified file-by-file
# against the repo tree (2026-10-14). Differences from the ZCU102 list, both
# deliberate:
#
#   REMOVED  ../rtl/rx/channel_normalizer.vhd
#            Ghost entry: the file exists nowhere in the repo and has SKIPped
#            on every ZCU102 run. The normalizer in service is
#            channel_normalizer_mux.vhd (listed below).
#            (Check: git status haifuraiya/rtl/rx/ on keroppi.)
#
#   ABSENT   third_party/esistream/*
#            Deliberate. Simulation target #1 is the core alone, retargeted to
#            the VC1902, so we have one variable per test. ESIstream sources 
#            join in a later part, when the reassembler/DDC seam exists to 
#            connect them up. 
#
# If a submodule SKIPs below, run the sim-set init and re-source:
#   git submodule update --init haifuraiya/third_party/power_detector \
#                               haifuraiya/third_party/lowpass_ema

puts "\nAdding synthesizable RTL (the core, unmodified)..."
safe_add_files sources_1 {
    ../../../third_party/lowpass_ema/src/lowpass_ema.vhd
    ../../../third_party/power_detector/src/power_detector.vhd
    ../../../rtl/channelizer/fft_pkg.vhd
    ../../../rtl/channelizer/haifuraiya_coeffs_pkg.vhd
    ../../../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../../../rtl/channelizer/r2sdf_stage.vhd
    ../../../rtl/channelizer/r2sdf_reorder.vhd
    ../../../rtl/channelizer/r2sdf_fft.vhd
    ../../../rtl/channelizer/haifuraiya_channelizer_top.vhd
    ../../../rtl/axi/axi_lite_regs.vhd
    ../../../rtl/resampler/halfband_taps_pkg.vhd
    ../../../rtl/resampler/halfband_decimator.vhd
    ../../../rtl/resampler/channel_gain_pkg.vhd
    ../../../rtl/resampler/channel_eq.vhd
    ../../../rtl/channelizer/channel_normalizer_mux.vhd
    ../../../rtl/axi/haifuraiya_channelizer_axi.vhd
    ../../../rtl/rx/msk_symbol_engine.vhd
    ../../../rtl/rx/msk_mlse4.vhd
    ../../../rtl/rx/sym_lock_detector.vhd
    ../../../rtl/rx/cfo_rotator.vhd
    ../../../rtl/rx/cfo_afc.vhd
    ../../../rtl/rx/msk_demodulator_mlse.vhd
    ../../../rtl/rx/lut16q_pkg.vhd
    ../../../rtl/rx/frame_sync_detector_soft.vhd
    ../../../rtl/rx/haifuraiya_demod_regs.vhd
    ../../../rtl/rx/frame_drop_gate.vhd
    ../../../rtl/rx/axis_async_fifo.vhd
    ../../../rtl/rx/cfo_slew.vhd
    ../../../rtl/rx/cfo_fine.vhd
    ../../../rtl/rx/haifuraiya_rx_top.vhd
    ../../../rtl/rx/haifuraiya_rx_axi.vhd
}

# Hard gate: Part 2 is only complete if every core file landed. A SKIP in the
# core manifest means a missing submodule or a moved file, so stop and look,
# don't let elaboration discover it later when things blow up.
set n_added [llength [get_files -of_objects [get_filesets sources_1]]]
set n_expected 31
if {$n_added != $n_expected} {
    puts "*** ERROR: expected $n_expected core files, got $n_added."
    puts "***        Scroll up for SKIP lines. Most likely cause: sim"
    puts "***        submodules not initialized (see PREREQUISITES header)."
    error "PART 2 incomplete: core manifest short ($n_added/$n_expected)"
}

puts ""
puts "PART 2 complete: $n_added core files added."
puts "PART 3 (testbench + stimulus staging) not yet present in this script."

################################################################################
# PART 3 -- testbench, VHDL-2008 properties, stimulus staging (to be added)
################################################################################

################################################################################
# PART 4 -- simulation launch + waveform layout                (to be added)
################################################################################
