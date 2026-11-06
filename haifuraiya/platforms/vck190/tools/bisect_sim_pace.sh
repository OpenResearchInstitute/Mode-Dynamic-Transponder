#!/usr/bin/env bash
# bisect_sim_pace.sh -- which commit made the tier-1 simulation slow?
#
# For each commit given, checks it out in a scratch git worktree, runs the
# tier-1 VCK190 simulation (run_mdt_vck190_sim.tcl, Vivado batch mode) on ONE
# fixed stimulus, lets it simulate for a fixed number of minutes after the
# first channel sample appears, and records the pace in simulated
# milliseconds per wall hour.  Then kills it and moves to the next commit.
# Output: a table, one line per commit, in $OUT.
#
# Pace is measured from channel_iq.txt (one line per target-channel sample at
# 625 kSps = 1.6 us of simulated time per line), which the bench has written
# since before any of the suspect commits.  Elaboration time is excluded: the
# clock starts when the file gets its first line.
#
# Usage (from a shell with Vivado 2022.2 on PATH, i.e. settings64.sh sourced):
#   haifuraiya/platforms/vck190/tools/bisect_sim_pace.sh MINUTES COMMIT [COMMIT...]
# e.g.
#   haifuraiya/platforms/vck190/tools/bisect_sim_pace.sh 10 8980e58 6945229 3e4c7ed 5eacf1d c2bf05f
#
# Prerequisites:
#   - haifuraiya/sim/opv_chan_stim.txt exists in the MAIN tree (the 3-frame
#     stimulus); it is copied into the worktree so every point uses the same
#     one regardless of what that commit's opv_stim.py would generate.
#   - Nothing else of yours is using /tmp/mdt_bisect.
# The main tree and any simulation running from it are not touched.
set -u
MIN=${1:?minutes per point}; shift
test $# -ge 1 || { echo "usage: $0 MINUTES COMMIT..."; exit 1; }
command -v vivado >/dev/null || { echo "ERROR: vivado not on PATH (source settings64.sh)"; exit 1; }

REPO=$(git rev-parse --show-toplevel) || { echo "ERROR: run from inside the repo"; exit 1; }
STIM=$REPO/haifuraiya/sim/opv_chan_stim.txt
test -f "$STIM" || { echo "ERROR: $STIM missing (generate the 3-frame stimulus first)"; exit 1; }
WT=/tmp/mdt_bisect
OUT=$REPO/haifuraiya/platforms/vck190/sim/logs/bisect_sim_pace_$(date +%Y%m%d_%H%M).txt
mkdir -p "$(dirname "$OUT")"
SIMDIR=haifuraiya/platforms/vck190/sim
XSIM=$SIMDIR/mdt_vck190_sim_project/mdt_vck190_sim.sim/sim_1/behav/xsim
US_PER_LINE=1.6          # channel_iq.txt: one line per 1/625000 s

# worktree: create once, then force-checkout each commit.  A worktree does
# NOT carry the submodules (lowpass_ema, power_detector): init them from the
# main repo's object store; if that cannot, copy the main tree's checkouts
# (neither submodule has moved in the window we bisect).
if [ ! -d "$WT" ]; then
    git -C "$REPO" worktree add --detach "$WT" "$1" || exit 1
fi
init_submodules() {
    git -C "$WT" submodule update --init --recursive >/dev/null 2>&1
    for sm in lowpass_ema power_detector; do
        if [ ! -f "$WT/haifuraiya/third_party/$sm/src/$sm.vhd" ]; then
            rm -rf "$WT/haifuraiya/third_party/$sm"
            cp -r "$REPO/haifuraiya/third_party/$sm" "$WT/haifuraiya/third_party/$sm"
        fi
    done
}

{
echo "# bisect_sim_pace  $(date)  minutes/point=$MIN  stimulus md5 $(md5sum < "$STIM" | cut -c1-8)"
echo "# commit    subject                                   lines@t0  lines@t1   sim_ms   ms/hour"
} | tee "$OUT"

for C in "$@"; do
    git -C "$WT" checkout --force --detach "$C" >/dev/null 2>&1 || { echo "$C  CHECKOUT FAILED" | tee -a "$OUT"; continue; }
    init_submodules
    SUBJ=$(git -C "$WT" log -1 --format=%s | cut -c1-40)
    cp "$STIM" "$WT/haifuraiya/sim/opv_chan_stim.txt"
    rm -rf "$WT/$SIMDIR/mdt_vck190_sim_project"
    ( cd "$WT/$SIMDIR" && setsid vivado -mode batch -nojournal -log "bisect_$C.log" \
          -source run_mdt_vck190_sim.tcl >/dev/null 2>&1 ) &
    VPID=$!
    F="$WT/$XSIM/channel_iq.txt"

    # wait (up to 30 min) for the first channel sample -- elaboration excluded.
    # Stop waiting at once if Vivado has already exited (runner error).
    W=0
    until [ -s "$F" ] || [ $W -ge 1800 ] || ! kill -0 "$VPID" 2>/dev/null; do sleep 5; W=$((W+5)); done
    if [ ! -s "$F" ]; then
        ERR=$(grep -m1 "^\*\*\* ERROR\|^ERROR\|incomplete" "$WT/$SIMDIR/bisect_$C.log" 2>/dev/null | cut -c1-70)
        printf "%-9s %-40s  NO OUTPUT after %d s: %s (see %s/%s/bisect_%s.log)\n" "$C" "$SUBJ" "$W" "${ERR:-no error line; elaboration not finished?}" "$WT" "$SIMDIR" "$C" | tee -a "$OUT"
    else
        L0=$(wc -l < "$F"); T0=$(date +%s)
        sleep $((MIN*60))
        L1=$(wc -l < "$F"); T1=$(date +%s)
        SIM_MS=$(awk -v a=$L0 -v b=$L1 -v u=$US_PER_LINE 'BEGIN{printf "%.2f",(b-a)*u/1000}')
        RATE=$(awk -v a=$L0 -v b=$L1 -v u=$US_PER_LINE -v s=$((T1-T0)) 'BEGIN{printf "%.1f",(b-a)*u/1000*3600/s}')
        printf "%-9s %-40s %9d %9d %8s %9s\n" "$C" "$SUBJ" "$L0" "$L1" "$SIM_MS" "$RATE" | tee -a "$OUT"
    fi

    # stop this point: the vivado process group (setsid) and any xsimk it left
    kill -- -"$(ps -o pgid= -p "$VPID" 2>/dev/null | tr -d ' ')" 2>/dev/null
    for P in $(pgrep -f xsimk); do
        case "$(readlink /proc/$P/cwd 2>/dev/null)" in "$WT"/*) kill "$P" 2>/dev/null;; esac
    done
    sleep 5
done

echo "# done $(date)" | tee -a "$OUT"
echo "table: $OUT"
echo "worktree left at $WT (git worktree remove $WT when finished with it)"
