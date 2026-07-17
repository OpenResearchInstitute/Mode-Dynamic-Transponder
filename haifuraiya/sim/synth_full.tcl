# synth_full.tcl -- FULL-DESIGN synthesis error hunt (project mode).
# Reuses the sim runner's source list; top = haifuraiya_rx_axi.
# Run from sim/:  vivado -mode batch -source synth_full.tcl
# ~20-60 min. Purpose today: FIND ERRORS + first full utilization/timing.
set part xczu9eg-ffvb1156-2-e
set proj_dir ./synth_full_project
file delete -force $proj_dir
create_project synth_full $proj_dir -part $part -force

# same sources as the sim runner, MINUS testbench (keep in sync by hand
# or source-list refactor later)
set rtl ../rtl

add_files [list \
  ../third_party/lowpass_ema/src/lowpass_ema.vhd \
  ../third_party/power_detector/src/power_detector.vhd \
  ../rtl/channelizer/fft_pkg.vhd \
  ../rtl/channelizer/haifuraiya_coeffs_pkg.vhd \
  ../rtl/channelizer/polyphase_filterbank_parallel.vhd \
  ../rtl/channelizer/r2sdf_stage.vhd \
  ../rtl/channelizer/r2sdf_reorder.vhd \
  ../rtl/channelizer/r2sdf_fft.vhd \
  ../rtl/channelizer/haifuraiya_channelizer_top.vhd \
  ../rtl/axi/axi_lite_regs.vhd \
  ../rtl/resampler/halfband_taps_pkg.vhd \
  ../rtl/resampler/halfband_decimator.vhd \
  ../rtl/resampler/channel_gain_pkg.vhd \
  ../rtl/resampler/channel_eq.vhd \
  ../rtl/channelizer/channel_normalizer_mux.vhd \
  ../rtl/axi/haifuraiya_channelizer_axi.vhd \
  ../rtl/rx/msk_symbol_engine.vhd \
  ../rtl/rx/msk_mlse4.vhd \
  ../rtl/rx/msk_demodulator_mlse.vhd \
  ../rtl/rx/frame_sync_detector_soft.vhd \
  ../rtl/rx/haifuraiya_demod_regs.vhd \
  ../rtl/rx/haifuraiya_rx_top.vhd \
  ../rtl/rx/haifuraiya_rx_axi.vhd ]

# NOTE: adjust paths above to the real tree if they differ -- the sim
# runner's safe_add_files list is the authority; keep them identical.

set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top haifuraiya_rx_axi [current_fileset]

# elaboration-time ROM reads resolve in the synth run dir: stage the hex
set hook [file normalize ./pre_synth_stage.tcl]
set fh [open $hook w]
puts $fh "file copy -force [file normalize ./lut16q_hex.txt] ./"
close $fh
set_property STEPS.SYNTH_DESIGN.TCL.PRE $hook [get_runs synth_1]

# constrain the single clock so timing analysis has a ruler
set xdc [file normalize ./synth_full.xdc]
set fx [open $xdc w]
puts $fx "create_clock -period 10.000 -name aclk \[get_ports aclk\]"
close $fx
add_files -fileset constrs_1 $xdc

launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1
file mkdir reports
report_utilization    -file reports/full_util.rpt
report_timing_summary -file reports/full_timing.rpt -delay_type max -max_paths 10
puts "FULL SYNTHESIS DONE -- read reports/full_util.rpt and full_timing.rpt"
puts [exec grep -A6 "Design Timing Summary" reports/full_timing.rpt]
