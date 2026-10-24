#!/bin/bash
# Runner for the pacer unit bench (vendor-neutral, nvc).  From this directory:
#   ./run_axis_sample_pacer_nvc.sh
set -e
cd "$(dirname "$0")"
mkdir -p work_pacer && cd work_pacer
nvc --std=2008 -a ../../rtl/axis_sample_pacer.vhd ../tb_axis_sample_pacer.vhd
nvc --std=2008 -e tb_axis_sample_pacer
nvc --std=2008 -r tb_axis_sample_pacer --ieee-warnings=off
