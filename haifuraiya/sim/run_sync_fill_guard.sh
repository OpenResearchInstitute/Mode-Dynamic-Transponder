#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# run_sync_fill_guard.sh  -  ghdl runner for the frame-sync fill-guard unit test
# Companion to run_sync_fill_guard_test.tcl (Vivado xsim). Validated with GHDL
# 4.1.0. Full teardown + rebuild from source every run.
#
#   ./run_sync_fill_guard.sh [path/to/frame_sync_detector_soft.vhd]
#
# Default RTL path is the production file, matching the tcl runner.
# Exit 0 = ALL TESTS PASSED ; non-zero = TESTS FAILED (--assert-level=error).
#
# NOTE: -frelaxed is required because the bench uses the house-style
#       'shared variable ... : integer' tally (accepted by xsim; VHDL-2008
#       strict wants a protected type).
#-------------------------------------------------------------------------------
set -e
RTL="${1:-../third_party/pluto_msk/src/frame_sync_detector_soft.vhd}"
TB=./tb_sync_fill_guard.vhd
TOP=tb_sync_fill_guard
WORK=work_fillguard

echo "== teardown =="
rm -rf "$WORK" *.ghw work-obj*.cf
mkdir -p "$WORK"

echo "== analyze ($RTL) =="
ghdl -a --std=08 -frelaxed --workdir="$WORK" "$RTL" "$TB"
echo "== elaborate =="
ghdl -e --std=08 -frelaxed --workdir="$WORK" "$TOP"
echo "== run =="
ghdl -r --std=08 -frelaxed --workdir="$WORK" "$TOP" \
     --stop-time=3ms --assert-level=error --wave="$WORK/$TOP.ghw"
