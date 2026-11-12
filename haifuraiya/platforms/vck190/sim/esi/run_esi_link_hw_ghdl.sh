#!/usr/bin/env bash
# run_esi_link_hw_ghdl.sh -- the hardware wrapper (esi_link_hw: registers, snapshot,
# split TX/RX clocks) with a stand-in transceiver, in GHDL -- the same bench as
# run_esi_link_hw_nvc.sh under a second, independent simulator.  GHDL 4.x
# (Ubuntu 24.04 package; on 22.04 the package is 1.0 and too old -- use the
# release tarball from github.com/ghdl/ghdl).
#
# Compiles Teledyne's ESIstream TX/RX (public domain, vendored under
# haifuraiya/third_party/esistream_vck190/), our packer/reassembler/loop
# (platforms/vck190/rtl/esi/), the proven axis_async_fifo, and the bench.
# The one substitution: rx_xpm_async_fifo_sim.vhd stands in for Teledyne's
# XPM FIFO wrapper (nvc has no Xilinx XPM).  xsim on chococat uses the real one.
#
# Usage:  haifuraiya/platforms/vck190/sim/esi/run_esi_link_hw_ghdl.sh [N_SAMPLES]
# Pass = "PASS: tb_esi_link_hw" in the log.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HAI=$(cd "$HERE/../../../.." && pwd)                 # haifuraiya/
ESI="$HAI/third_party/esistream_vck190"
OURS="$HAI/platforms/vck190/rtl/esi"
WORK="$HERE/work_esi_link_hw_ghdl"
N=${1:-2000}

test -f "$ESI/src_pkg/esistream_pkg_64b.vhd" || { echo "ERROR: Teledyne package not found at $ESI (see README_ORI.md)"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

# Teledyne sources use the Synopsys std_logic_arith/unsigned packages:
# --std=08 -fsynopsys.  -frelaxed for the usual Xilinx-style liberties.
# Order matters for the packages.
GHDLFLAGS="--std=08 -fsynopsys -frelaxed --workdir=. --work=work"
ghdl -a $GHDLFLAGS \
    "$ESI/src_pkg/esistream_pkg_64b.vhd" \
    "$ESI/src_common/two_flop_synchronizer.vhd" \
    "$ESI/src_common/ff_synchronizer_array.vhd" \
    "$ESI/src_rx/rx_delay.vhd" \
    "$HERE/rx_xpm_async_fifo_sim.vhd" \
    "$ESI/src_rx/rx_xpm_output_buffer.vhd" \
    "$ESI/src_rx/rx_frame_alignment.vhd" \
    "$ESI/src_rx/rx_lfsr_init.vhd" \
    "$ESI/src_rx/rx_decoding.vhd" \
    "$ESI/src_rx/rx_lane_decoding.vhd" \
    "$ESI/src_rx/rx_control.vhd" \
    "$ESI/src_rx/rx_esistream.vhd" \
    "$ESI/src_tx/tx_lfsr.vhd" \
    "$ESI/src_tx/tx_scrambling.vhd" \
    "$ESI/src_tx/tx_disparity_word_16b.vhd" \
    "$ESI/src_tx/tx_disparity.vhd" \
    "$ESI/src_tx/tx_encoding.vhd" \
    "$ESI/src_tx/tx_esistream.vhd" \
    "$HAI/rtl/rx/axis_async_fifo.vhd" \
    "$OURS/esi_loop_pkg.vhd" \
    "$OURS/esi_sample_packer.vhd" \
    "$OURS/esi_sample_reassembler.vhd" \
    "$OURS/esi_link_loop.vhd" \
    "$OURS/esi_link_hw.vhd" \
    "$HERE/tb_esi_link_hw.vhd"

ghdl -e $GHDLFLAGS tb_esi_link_hw
ghdl -r $GHDLFLAGS tb_esi_link_hw -gN_SAMPLES=$N --stop-time=5ms --ieee-asserts=disable-at-0 2>&1 | tee run.log
grep -q "PASS: tb_esi_link_hw" run.log && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
