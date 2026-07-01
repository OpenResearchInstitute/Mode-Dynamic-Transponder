# WP2 Companion: Per-Channel State Inventory (Time-Shared Power Detector)

**Revised** using the actual `power_detector.vhd` and `lowpass_ema.vhd` sources.
It supersedes the earlier version, whose "2 x 31-bit accumulator" estimate was wrong:
the EMA carries a wide, high-precision feedback register that must be saved per
channel. Sizing is still tiny, but the per-channel word is ~2.5x larger than
estimated, and there is a bit-exactness trap to avoid.

**Purpose:** the concrete state list for collapsing 64 parallel `power_detector`
instances into one time-shared datapath plus a per-channel state RAM, preserving the
per-channel AGC and the `CHANNEL_POWER[0..63]` register window exactly.

---

## What these blocks actually do

- **`power_detector`** (per channel today): squares I and Q (16x16 each), sums to a
  31-bit magnitude-squared `dsum = I^2 + Q^2`, then passes it through a two-stage EMA
  cascade. It also supports I-only / Q-only `dsum` selection for diagnostics.
- **`lowpass_ema`**: a fractional exponential moving average, `average = alpha*data +
  (1-alpha)*average_prev`, with `alpha` a u0.18 fixed-point coefficient (`ALPHA_W=18`).
  Internally it forms a 51-bit product (`PROD_W`), applies saturation with guard bits
  (`EXTRA_W=4`), and truncates the output back to the data width. Two of these in
  series give a sharper low-pass (more smoothing / steeper rolloff) than one stage,
  which is what sets the AGC time constant.

The key structural fact for time-sharing: the running average is carried in the
**51-bit `mult_sum` feedback register**, not in the 31-bit `average` output. The
output is a truncated view of the internal state.

---

## Why time-sharing is safe (AGC unchanged)

Each channel produces one sample per frame, so a parallel detector updates once per
frame per channel. A shared detector visiting each channel once per frame updates at
the identical rate. Same alpha, same two-stage response, same time constant, same
squelch behavior. Purely a resource change. It taps the CONTINUOUS pre-demod
channelized stream, never the gated post-frame-sync bursts, so the level estimate
survives quiet channels.

---

## Table A - Persistent per-channel state -> state RAM

Widths are now measured (m) from the submodule sources for the MDT build
(`power_detector` DATA_W=16, so each `lowpass_ema` is instantiated with DATA_W=31,
ALPHA_W=18, PROD_W=51).

| Signal | Width (bits) | Depth | Notes |
|---|---|---|---|
| `mult_sum` stage 1 (`u_ema_1` feedback) | 51 (m, PROD_W) | 64 | high-precision running average, stage 1 |
| `mult_sum` stage 2 (`u_ema_2` feedback) | 51 (m, PROD_W) | 64 | high-precision running average, stage 2 |
| `average` stage 2 (power output) | 31 (m, 2*DATA_W-1) | 64 | value read out to CHANNEL_POWER / AGC |
| `average` stage 1 (optional) | 31 (m) | 64 | stage-2 input; regenerated per sample, save only if the pipeline needs it held |

Essential per channel: 51 + 51 + 31 = **133 bits**.
Conservative (save both stage averages for clean readout): **164 bits**.

`mult_data`, `data_signed`, and the per-sample `dsum`/`di_sq`/`dq_sq` do NOT need
saving; they are recomputed from the incoming sample (see Table B).

**Bit-exactness trap:** do not save only the 31-bit `average` and reload it as the
feedback term. The feedback path uses the full 51-bit `mult_sum`; reconstructing it
from the truncated 31-bit output loses precision and the shared detector will slowly
diverge from the parallel reference in regression. Save `mult_sum` at full width.

---

## Table B - In-flight / per-sample (NOT stored per channel)

| Signal | Width (bits) | Notes |
|---|---|---|
| `di_sq`, `dq_sq` | 31 each (m, 2*DATA_W-1) | I^2, Q^2 |
| `dsum` = I^2 + Q^2 | 31 (m) | magnitude-squared, recomputed each sample |
| `mult_data` (each stage) | 51 (m, PROD_W) | data*alpha; from current sample, not persistent |
| channel index (from TDEST) | 6 used | RAM address; flows with the sample |

---

## Global configuration (shared, unchanged, NOT per-channel)

| Register | Width | Notes |
|---|---|---|
| `alpha1` (stage-1 coefficient) | 18 (m, ALPHA_W, u0.18) | same for all channels |
| `alpha2` (stage-2 coefficient) | 18 (m, ALPHA_W, u0.18) | same for all channels |
| `output_shift` | 5 (m) | output scaling |
| `dsum` mode (I+Q / I-only / Q-only) | 2 (m) | diagnostic select; preserve as global |

If per-channel alpha is ever wanted, it becomes an added RAM column; today it is
global and costs nothing here.

---

## Datapath (one shared unit)

```
channelizer TDM (I, Q, ch k)
   -> di_sq = I*I ; dq_sq = Q*Q ; dsum = di_sq + dq_sq        (2 DSP, 31b)
   -> read {mult_sum_1, mult_sum_2, average_2} at addr k       (state RAM)
   -> EMA stage 1 (alpha1): update mult_sum_1, form average_1  (~3 DSP)
   -> EMA stage 2 (alpha2): input = average_1, update mult_sum_2, form average_2 (~3 DSP)
   -> write {mult_sum_1', mult_sum_2', average_2'} at addr k
   -> average_2' ->  CHANNEL_POWER[k] register window
                 ->  per-channel AGC normalize (at demod core input)
                 ->  per-channel activity / squelch compare (vs global threshold)
```

- **DSP:** ~6 to 8 for the single shared unit (2 for squaring, ~3 per EMA stage),
  matching one parallel detector, replacing the ~460 DSP of the 64 parallel copies
  (measured 6-8 DSP each in the hierarchical report). Largest, lowest-effort DSP
  reclaim in the plan.
- **Register-map compatibility:** the shared unit writes the same `stat_channel_power`
  window (64 x 31 bits). Software sees no change to `CHANNEL_POWER[0..63]`.

---

## Timing and hazards

- Aggregate load: 64 x 625 kSps = 40 Msps, ~2.5 clocks per channel-sample at 100 MHz.
  A one-per-clock read-modify-write pipeline sustains this with large margin.
- Hazard-free: channels arrive round-robin, consecutive samples are different
  channels, and a channel reappears only every ~160 clocks, far longer than the short
  RMW pipeline. No channel is mid-update when its next sample lands, so a plain
  dual-port RAM (1 read + 1 write per clock) suffices. No feedback loop across
  channels, unlike the demod.

---

## RAM sizing summary (feeds the WP5 BRAM tally)

| Scope | Persistent bits | Notes |
|---|---|---|
| Per channel | 133 (164 conservative) | two 51-bit feedback regs + 31-bit output |
| All 64 channels | ~8,500 to ~10,500 (~1.0 to 1.3 KB) | one RAM, 64 deep x ~133-164 wide |

Still tiny: one RAMB18 (18 Kbit) covers it with room, or distributed LUTRAM. The
correction from the earlier estimate (~4 Kbit -> ~10 Kbit) does not change the
conclusion; it remains a rounding error against the 912-tile budget.

---

## Width provenance

- **Measured (m)** from `power_detector.vhd`: DATA_W (16 in the MDT build), squares
  `di_sq`/`dq_sq`/`dsum` at 2*DATA_W-1 = 31 bits, two-stage EMA cascade, I/Q/I+Q dsum
  select, output `power_squared` = 31 bits.
- **Measured (m)** from `lowpass_ema.vhd`: ALPHA_W=18 (u0.18), PROD_W = DATA_W(31) + 2
  + ALPHA_W(18) = 51, saturation with EXTRA_W=4 guard bits, feedback carried in the
  registered `mult_sum` (PROD_W=51), output `average` truncated to DATA_W=31.
- No remaining estimates: the two files resolve every width the earlier sheet had
  flagged.

---

## WP2 implementation checklist

1. One squaring unit (`di_sq`, `dq_sq`, `dsum`) fed by the channelizer TDM stream,
   honoring the global I/Q/I+Q select.
2. State RAM, 64 deep x ~133-164 wide, addressed by TDEST/channel index.
3. Two-stage EMA as a read-modify-write over that RAM, using global `alpha1`/`alpha2`;
   store and restore the full 51-bit `mult_sum` per stage per channel (not the
   truncated output).
4. Route `average_2` to the `CHANNEL_POWER` window, the per-channel AGC normalize, and
   the activity/squelch compare.
5. Regress bit-exact: per-channel power and the `CHANNEL_POWER` window must match the
   64-parallel version on identical stimulus; the 51-bit-feedback save/restore is the
   thing most likely to break this, so test it first.
6. Record actual LUTRAM/BRAM into the WP5 tally.

---

## One-line summary

The shared power detector is one square-plus-two-EMA datapath over a 64-entry RAM
holding each channel's two 51-bit EMA feedback registers and 31-bit output; it
reclaims ~450 DSP and preserves the CHANNEL_POWER window and per-channel AGC exactly,
provided the full-precision feedback state is saved per channel rather than the
truncated output.
