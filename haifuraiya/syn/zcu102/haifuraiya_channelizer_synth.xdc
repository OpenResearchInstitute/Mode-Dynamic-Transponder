################################################################################
# haifuraiya_channelizer_synth.xdc
#
# Constraints for out-of-context synthesis of haifuraiya_channelizer_top
# on ZCU102 (xczu9eg-ffvb1156-2-e).
#
# Lives at: haifuraiya/syn/zcu102/
#
# These constraints are deliberately minimal: a primary clock at the
# Haifuraiya 100 MHz testbench rate and reasonable input/output delays.
# When this module is later embedded in a full ZCU102 block design with
# the Zynq UltraScale+ PS IP, these constraints will be superseded by
# the parent design's timing context (PS-PL clock from PL_CLK0, etc.).
################################################################################

# HD.CLK_SRC tells OOC synthesis where the clock buffer WILL live in the
# parent design.  Without this, the timing engine can't propagate the
# clock from the OOC port to the leaf clock pins, so all paths report
# "no clock" and WNS comes back as 'inf' (which sounds like timing
# closed brilliantly but actually means timing was never analyzed).
#
# Zynq UltraScale+ uses BUFGCE (not BUFGCTRL, which is Series-7 era);
# BUFGCE_X0Y0 is a conservative placeholder site -- the real buffer
# location is set by the parent block design when this module is
# instantiated inside the Zynq PS block design.
#
# Note: this set_property is intentionally BEFORE create_clock so the
# property is in place when create_clock builds the clock object.
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]

# --- Primary clock ---
# 100 MHz, matching the Haifuraiya testbench and the per-frame budgeting
# work in haifuraiya/sim/. This is provisional; the final clock will be
# whatever we configure PL_CLK0 to emit in the parent design.
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# --- Input delays ---
# Assume sample data and valid arrive ~2 ns after the clock edge at the
# parent design's output flop. Conservative; refine when integrating.
set_input_delay -clock clk -max 2.000 [get_ports {sample_re[*] sample_im[*] sample_valid reset}]
set_input_delay -clock clk -min 0.200 [get_ports {sample_re[*] sample_im[*] sample_valid reset}]

# --- Output delays ---
# Leave ~2 ns of setup margin for whatever consumes the channel stream
# (the AXI-Stream shim in the eventual block design).
set_output_delay -clock clk -max 2.000 [get_ports {channel_re[*] channel_im[*] channel_idx[*] channel_valid channel_last ready frame_dropped}]
set_output_delay -clock clk -min 0.200 [get_ports {channel_re[*] channel_im[*] channel_idx[*] channel_valid channel_last ready frame_dropped}]
