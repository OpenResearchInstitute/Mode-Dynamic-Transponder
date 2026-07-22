#!/bin/bash
#
# run_cfo_sweep.sh -- WP2 step 3: CFO acquisition sweep to the measured edge
#
# For each offset point: regenerate a SHORT stimulus (preamble + 1 frame,
# ~85 ms sim), run the main bench in batch Vivado, harvest the verdict
# from the console log, append to the curve CSV, archive the soft dump.
#
# Run from sim/ on keroppi:   ./run_cfo_sweep.sh
# Expect ~10-20 min/point; the full list is an overnight batch.
# Curve lands in cfo_sweep_results.csv; per-point soft dumps in sweep_dumps/.
#
# Point list: control + anchors + the approach to R/4 = 13550 (the
# line-identification ambiguity ceiling, Morelli & Mengali 1998/1999)
# + two points past it (expected FAIL -- the edge must be measured
# from both sides or it is not measured).

set -u
OFFSETS="0 2000 -2000 5000 -5000 8000 -8000 10000 -10000 12000 -12000 13000 -13000 13550 -13550 14000 -14000 15000 -15000"
CSV=cfo_sweep_results.csv
LOG_GLOB="haifuraiya_axi_sim_project/haifuraiya_chan_axi_sim.sim/sim_1/behav/xsim/simulate.log"

mkdir -p sweep_dumps
[ -f "$CSV" ] || echo "offset_hz,fsync_locked,afc_state,afc_est_hz,frame_metric_hint,log" > "$CSV"

# Sweep runner: BOUNDED run instead of `run all`. The tb ends at a
# terminal wait and never stops the simulator (measured 2026-07-22:
# fourteen zombie xsimk kernels from the week's GUI sessions, one at
# 260 CPU-hours) -- `run all` in batch would therefore hang forever at
# point one. The --frames 1 stimulus concludes by ~90 ms, so run a
# fixed 100 ms and exit; vivado takes its xsimk down with it.
sed -e 's/^run all$/run 100 ms\nexit/' \
    run_haifuraiya_channelizer_axi_test.tcl > run_sweep_point.tcl
grep -q '^exit' run_sweep_point.tcl || { echo "runner patch failed"; exit 1; }

for OFF in $OFFSETS; do
    echo "=============================================="
    echo "SWEEP POINT: ${OFF} Hz   $(date -u +%H:%M:%S)"
    python3 opv_stim.py --out opv_chan_stim.txt --fc 781250 \
        --carrier-offset "$OFF" --amp 9000 --frames 1 --preamble \
        | grep 'center=' || { echo "stimgen FAILED"; exit 1; }

    vivado -mode batch -source run_sweep_point.tcl \
        > "sweep_dumps/vivado_${OFF}.log" 2>&1

    LOG=$(ls $LOG_GLOB 2>/dev/null | head -1)
    if [ -z "$LOG" ]; then
        echo "$OFF,NO_LOG,,,," >> "$CSV"; continue
    fi
    # harvest the tb's own printed verdicts
    STATE=$(grep -o 'CFO_STATE = [0-9]' "$LOG" | tail -1 | grep -o '[0-9]$')
    EST=$(grep -o 'CFO_ESTIMATE (applied, Hz) = -\?[0-9]*' "$LOG" | tail -1 | grep -o '\-\?[0-9]*$')
    FSYNC=$(grep -c 'frame_sync_locked = 1\|MILESTONE 4' "$LOG")
    cp soft_raw.txt "sweep_dumps/soft_raw_${OFF}.txt" 2>/dev/null || true
    cp "$LOG" "sweep_dumps/simulate_${OFF}.log"
    echo "$OFF,$FSYNC,${STATE:-?},${EST:-?},see_dump,simulate_${OFF}.log" >> "$CSV"
    echo "  -> state=${STATE:-?} est=${EST:-?} fsync_hits=$FSYNC"
done
echo "=============================================="
echo "Sweep complete. Curve: $CSV   Dumps: sweep_dumps/"
