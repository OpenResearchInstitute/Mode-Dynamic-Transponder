# WP1 (REVISED) - Per-Channel State Inventory: CORDIC-atan2 Demodulator

**Status:** DRAFT. Supersedes `WP1_per_channel_state_inventory.md`, which inventories
the de Buda dual-Costas demodulator that no longer exists in the RTL.

**Basis:** `msk_demodulator.vhd` as of the single-channel lock milestone (carrier
settles, locks on channel 5 in simulation). Widths taken directly from the RTL
variable declarations. Nothing here is estimated; everything is read from source.

---

## 1. Why this document was rewritten

The existing SOW and WP1 describe a **de Buda dual-Costas** demodulator:
`fir_lowpass_complex` (25-tap complex, 46 DSP), `costas_loop` f1 and f2 (8 DSP each),
`pi_controller` (4 DSP), 77 DSP per instance total.

The demodulator has since been rewritten as a **CORDIC-atan2** design with an
integrated symbol-timing search. It instantiates `cordic_atan2` and contains no
`costas_loop`, no `pi_controller`, and no complex FIR. Therefore:

- The 77 DSP/instance figure is a measurement of a deleted design.
- The 16:1 vs 8:1 time-sharing decision rests on that figure and must be re-derived.
- The WP1 state list (de Buda 2fc NCO accumulator, Costas f1/f2 NCO accumulators,
  carrier PI accumulator, 25-tap FIR delay line) describes state that no longer exists.

**Everything about the scale-up STRATEGY survives.** Time-sharing N cores, carrying the
channel tag inline with the sample, moving per-channel state into channel-indexed
dual-port RAM, and regressing the N-channel core bit-for-bit against a single-channel
golden reference are all architecture-independent and remain correct. Only the NUMBERS
change. This document supplies the corrected numbers for state; DSP must be re-measured
from synthesis (see Section 5).

---

## 2. Persistent per-channel state vs. per-sample scratch

The critical distinction for interleaving cost. A variable is **per-channel state** if
its value must survive from one sample of a channel to the next sample of that same
channel. It is **scratch** if it is written and consumed entirely within the processing
of a single sample, in which case one copy is shared by the core and costs nothing per
channel.

**Scratch (NOT per-channel; shared by the core):**
`d1, d2, car, cai, e64, sd64, co, sn, tone_p, iv, qv` and the intermediate products.
These are assigned before use within one sample's arithmetic.

**Per-channel state (must be swapped):** everything in the table below.

Note `p1`, `p2`, `c1r`, `c1i`, `c2r`, `c2i` ARE per-channel state despite looking like
accumulator scratch: they accumulate across the samples *within* a symbol (reset by
`newsym`, updated by `accum`), so they persist across sample boundaries.

---

## 3. The inventory

| Group | Variable(s) | Width | Count | Bits |
|---|---|---:|---:|---:|
| BUFFER | `bi[]` sample buffer | 16 | 560 | 8,960 |
| BUFFER | `bq[]` sample buffer | 16 | 560 | 8,960 |
| CARRIER | `cph` carrier phase | 32 | 1 | 32 |
| CARRIER | `cfr` carrier frequency | 32 | 1 | 32 |
| CARRIER | `dph` dump phase | 32 | 1 | 32 |
| CARRIER | `p1`, `p2` tone phases | 32 | 2 | 64 |
| SYMBOL | `c1r, c1i` tone-1 accumulators | 48 | 2 | 96 |
| SYMBOL | `c2r, c2i` tone-2 accumulators | 48 | 2 | 96 |
| LOCK | `aif1, aqf1` f1 energy | 64 | 2 | 128 |
| LOCK | `aif2, aqf2` f2 energy | 64 | 2 | 128 |
| LOCK | `iqd1, iqd2` lock metric | 64 | 2 | 128 |
| LOCK | `cf1, cf2` lock counters | 32 | 2 | 64 |
| LOCK | `lkf1, lkf2` lock flags | 1 | 2 | 2 |
| FSM | `st` state | 2 | 1 | 2 |
| FSM | `bc` buffer count | 16 | 1 | 16 |
| FSM | `gpos` global sample position | 32 | 1 | 32 |
| FSM | `skipcnt` | 16 | 1 | 16 |
| FSM | `started` | 1 | 1 | 1 |
| TIMING | `frac` timing fraction | 32 | 1 | 32 |
| TIMING | `boundary_fp` symbol boundary | 32 | 1 | 32 |
| TIMING | `sidx` sample-in-symbol | 16 | 1 | 16 |
| TIMING | `wsym` samples this symbol | 16 | 1 | 16 |
| OUT | `rx_tone_i` | 1 | 1 | 1 |

`bi`/`bq` are declared as VHDL `integer` (32-bit) but carry `rx_i_samples`, which is
`DEMOD_SAMPLE_W = 12` bits. 16 bits is a safe stored width. **If they are stored as
full 32-bit integers, the buffer cost doubles.** Narrowing them at the RAM boundary is
free and should be done.

### Totals

```
bi/bq buffers            17,920 b   (94.9% of per-channel state)
all other persistent        966 b
                        ----------
TOTAL per channel        18,886 b   = 2.31 KiB

x 64 channels           147.5 KiB   ~= 32.8 x RAMB36
   of which bi/bq        31.1 x RAMB36
   all other state        1.68 x RAMB36
```

**SEARCH-only scratch** (`sc, sy, sk, sw, sidxs, sp_fp, stph, sc1r..sc2i, setot, sbest,
ee1, ee2, sbs2`, ~704 b) is live only in `S_SEARCH`. Whether it is per-channel depends
on whether channels are allowed to search concurrently -- see Section 4.

---

## 4. Consequences for the scale-up

### 4.1 The `bi`/`bq` buffers are the whole problem

`BUFLEN = 560` samples of I and Q per channel is **95% of the per-channel state**, and
at 64 channels it is ~31 RAMB36 for the buffers alone. The old de Buda design carried a
25-tap complex FIR delay line; this design carries a 560-sample buffer. That is a
**~22x increase in per-channel memory**, and it is the single most important change
between the old plan and the new reality.

The old SOW's WP5 BRAM tally (described as "expected comfortable") was computed against
the 25-tap delay line and is no longer valid. BRAM may now be a binding constraint
alongside DSP, not a comfortable afterthought.

**Actions:**
- Confirm what `BUFLEN = 560` is actually for. If it is a startup acquisition buffer
  used only to reach `S_RUN` (fill, search timing, find a boundary), then a **shared
  acquisition buffer** used by one channel at a time -- while the other 63 run in
  steady state -- collapses 31 RAMB36 to ~0.5. This is the highest-leverage question
  in the entire scale-up and must be answered before any RTL is written.
- If instead every channel needs a live 560-sample history in `S_RUN`, the buffers are
  irreducible and BRAM enters the part-selection decision.

### 4.2 Staggered acquisition

If channels acquire one (or a few) at a time rather than all 64 simultaneously, both
the `bi`/`bq` buffers and the ~704 b of SEARCH scratch become **shared, not
per-channel**. Steady-state per-channel state then drops to ~966 b, i.e. **~1.7 RAMB36
for all 64 channels** -- trivially cheap.

This is worth designing for deliberately. A "one channel acquires at a time, in
round-robin, while locked channels run" policy is operationally reasonable for a
transponder (stations do not all key up on the same clock edge) and it turns the
dominant memory cost into a rounding error.

### 4.3 DSP must be re-measured

The CORDIC replaces the 46-DSP complex FIR with shift-add stages (LUT/FF, no DSP), but
adds per-symbol complex tone accumulation (`accum`: four multiply-accumulates per
sample) and 48/64-bit arithmetic. Whether the new instance is cheaper or dearer than 77
DSP is **not knowable without synthesis**. Run synthesis on one instance, take the
hierarchical utilization report, and re-derive the core count. Do not carry the 77 DSP
figure forward.

---

## 5. The normalizer makes this easier, not harder

The per-channel normalizer (see `OPV_CHANNEL_NORMALIZER_SPEC.md`) brings every active
channel to a common target RMS `T` regardless of the transmitting station's level. Its
effect on the scale-up is strongly positive, and the interaction is worth stating
explicitly:

**1. Lock thresholds become shared constants.** `symbol_lock_threshold` compares against
`iqd1 = aif1 - aqf1`, which scales with input amplitude squared. Without normalization,
a correct threshold for a strong channel is wrong for a weak one, so the threshold
would have to be **per-channel state** (tuned per station) or the lock metric would need
per-channel normalization. With the normalizer, one constant serves all 64 channels.
The same argument applies to the frame-sync `HUNTING_THRESHOLD` / `LOCKED_THRESHOLD`,
whose soft correlation is likewise linear in amplitude.

**2. It removes per-channel AGC state.** Any AGC placed inside the demod would add gain
and loop state per channel, swapped every sample. The normalizer sits upstream in the
channelizer datapath, where it costs one gain per channel in a small RAM and no
demod-side state at all.

**3. It protects the fixed-point headroom.** `aif1`/`aqf1` are 64-bit accumulators over
`symbol_lock_count` symbols, and the `c1r..c2i` symbol accumulators are 48-bit. Their
headroom is sized for a bounded input amplitude. A near-far spread of 40 dB across
channels either overflows the strong channels or buries the weak ones in quantization
noise. A common `T` is what makes one fixed-point design valid for all 64.

**4. It keeps the interleave bit-exact against the golden reference.** The SOW's
acceptance criterion is that a 16-channel core produce output bit-identical to 16
independent single-channel demods. That criterion is only meaningful if each channel
presents the demod with the same statistics it saw in the single-channel case. The
normalizer is what guarantees that.

**Ordering constraint:** the normalizer must be in place, with `T` calibrated, BEFORE
the interleave regression is meaningful. Calibrating `T` requires a locked demod on a
real signal -- which is exactly the milestone just reached. **Normalizer first, then
interleave.**

**Do not** put the normalizer downstream of the demod, and do not implement it as
per-channel AGC inside the demod core. Both choices would create exactly the
per-channel state the interleave is trying to eliminate.

---

## 6. What must change in the parent SOW

| SOW element | Status | Action |
|---|---|---|
| Title / framing: "de Buda Demodulator" | STALE | Retitle: CORDIC-atan2 demodulator |
| Sec 4: 77 DSP inventory (FIR 46, Costas 8+8, PI 4) | STALE | Re-measure from synthesis |
| Baseline: 16:1 time-sharing, 4 cores, 308 DSP | UNVERIFIED | Re-derive from new DSP figure |
| Sec 2 entry gate: bit-accurate vs `debuda_fixedpoint_model.py` | STALE | No such model for the CORDIC design. Write one, or replace the criterion with a dump-compare golden model as used for the channelizer leaves. |
| Sec 2 entry gate: "both tone loops (f1, f2) acquire lock, verified by ILA" | PARTIAL | Carrier settles and locks **in simulation**. Hardware ILA lock and frame sync are NOT yet demonstrated. Gate not fully met. |
| WP1 state list (2fc NCO, Costas NCOs, PI accum, 25-tap FIR) | STALE | Replaced by Section 3 above |
| WP5 BRAM tally "expected comfortable" | INVALID | Recompute: 31 RAMB36 of `bi`/`bq` at 64 channels unless staggered acquisition is adopted |
| WP3 symmetry-folding the de Buda FIR (reserve lever) | MOOT | The FIR is gone. Remove or replace with a CORDIC-stage-sharing lever. |
| Strategy: tag pipeline, state RAM, bit-exact regression | SOUND | Keep unchanged |

---

## 7. Recommended next actions, in order

1. **Answer the `BUFLEN` question** (Section 4.1). Is the 560-sample buffer needed only
   for acquisition, or continuously in `S_RUN`? This single answer swings the memory
   cost of the entire scale-up by ~30 RAMB36.
2. **Synthesize one CORDIC demod instance** and record DSP / LUT / FF / BRAM. Re-derive
   the cores-per-channel ratio. The 16:1 baseline is currently unsupported.
3. **Land the normalizer and calibrate `T`** against the now-locking single-channel
   demod. This is a prerequisite for a meaningful interleave regression.
4. **Build a bit-exact golden model of the CORDIC demod** (dump-compare against RTL, the
   method used for the five channelizer leaves and `channelizer_top`). This replaces
   `debuda_fixedpoint_model.py` in the entry gate and becomes the regression oracle for
   every subsequent work package.
5. **Then** rewrite the parent SOW against the measured numbers.
