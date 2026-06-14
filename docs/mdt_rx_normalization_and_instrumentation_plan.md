# Haifuraiya RX — per-channel normalization + frame-sync instrumentation

*Design, build plan, and bring-up workflow. One rebuild that gives full
visibility AND every knob needed to tune live afterward.*

---

## 1. Why this exists (the architectural finding)

The MDT carries **64 independent uplinks**, each from a different station at a
different power level — blasting loud to barely-there — and **there is no
per-channel AGC**.

The ADRV9002's AGC is **wideband**: it sees the whole ~10 MHz / 20 Msps composite
as one signal, measures total energy, and sets *one* gain for the entire band.
It has no concept of the 64 channels (channelization happens downstream in
fabric), and it tends to be driven by the loudest channel, pushing the faint
ones further down. So after the channelizer, per-channel amplitudes differ by
whatever they differed by on the air.

The demod chain came from **pluto_msk**, which ran on a Pluto with the radio's
AGC normalizing its *single* channel to a consistent level. Two design decisions
bake that assumption in:

- **The soft quantizer** (`frame_sync_detector_soft.vhd`) uses fixed thresholds
  ±500 / ±1400 / ±2800, calibrated for a ±3340 nominal soft range. The author's
  own comment: *"Adjust for hardware deployment based on observed rx_data_soft
  distribution."* Never done.
- **The Costas lock detector** compares an amplitude-dependent discriminant
  against a fixed threshold (`SYM_LOCK_THRESHOLD`, currently 8).

Both are amplitude-dependent. **Without per-channel normalization, no single
quantizer threshold and no single Costas threshold can be correct across the
power range.** A loud channel sails over the lock threshold and rails the
quantizer; a faint one never reaches either. This is why "Costas locks but frame
sync doesn't" behaves as a moving target with `output_shift` — we've been
chasing one global scale for a problem that is per-channel.

**Fix:** normalize each channel's I/Q to a consistent amplitude *before the
demod*. Normalizing the I/Q (not just the soft) fixes the Costas discriminant
and the quantizer in one move. Drive it **feed-forward** from the per-channel
power the channelizer already measures — no closed loop, no settling, no
stability concern.

---

## 2. Architecture

```
channelizer ──► per-channel POWER detector (already exists, full precision)
     │                         │
     │ target-chan I/Q         │ power(ch)
     ▼                         ▼
  ┌─────────────────────────────────┐
  │  GAIN NODE  (new, in rx_top)     │   gain = manual reg   (mode=0)
  │  I' = I·gain                     │        = f(power)     (mode=1, feed-fwd)
  │  Q' = Q·gain                     │
  └─────────────────────────────────┘
     │ normalized I'/Q'
     ▼
   msk_demodulator ──► soft ──► quantizer ──► frame_sync_detector_soft
```

- **Single channel today** (`TARGET_CHANNEL=0`). The gain node is the manual +
  auto block for one channel.
- **64-channel future:** per-channel gain becomes one more per-channel context
  alongside NCO phase and loop-filter state in the Option-B TDM redesign. The
  block built now is the prototype, not throwaway.

### Manual first, auto by a mode bit — and why

Every automated gain law needs a **setpoint** — the input amplitude that makes
the soft land in the quantizer window — and that setpoint lives on the far side
of the demod's internal gain, which is **unmeasured until we lock once**.
Automating toward an unknown setpoint, against a demod that has never locked,
multiplies unknowns. So:

1. **Manual mode** holds gain fixed and known → find the first lock → *read off*
   the operating point (the gain, the resulting power, the soft distribution).
2. That operating point **is** the auto setpoint / curve. Populate it (live).
3. **Flip the mode bit to auto** and confirm it converges to the same gain.

Manual is the instrument that produces the number automation needs. The mode bit
means the migration is a `devmem`, never a rebuild. Live-tunable manual gain is
the immediate must-have: change levels and characterize without rebuilding.

---

## 3. Build contents

### 3a. Gain node (`haifuraiya_rx_top.vhd`)

Site it on the demuxed target-channel I/Q (`chan_i_reg` / `chan_q_reg`), ahead of
the slice into the demod. Suggested fixed-point gain `U8.10` (range ~0.001–256,
covers ≈ ±48 dB), one DSP per rail:

```vhdl
-- gain_apply : Q-format multiply, then round/saturate back to 16-bit
prod_i <= signed(chan_i_reg) * signed('0' & gain_eff);   -- 16 x 18 -> 34
prod_q <= signed(chan_q_reg) * signed('0' & gain_eff);
gi     <= round_sat(prod_i, 10);                          -- >>10, saturate to 16
gq     <= round_sat(prod_q, 10);
```

`gain_eff` is selected by mode (see 3b). Feed `gi`/`gq` (not the raw regs) into
the existing `rx_i_to_demod` / `rx_q_to_demod` slice.

### 3b. New demod registers (`haifuraiya_demod_regs.vhd`)

Free offsets after `SYM_LOCK_THRESHOLD` (0x028):

| offset | name | R/W | meaning |
|---|---|---|---|
| 0x02C | `GAIN_MODE` | RW | bit0: 0=manual, 1=auto |
| 0x030 | `GAIN_MANUAL` | RW | U8.10 gain used in manual mode |
| 0x034 | `GAIN_TARGET` | RW | auto setpoint (target normalized amplitude / power) |
| 0x038 | `GAIN_CURRENT` | RO | the gain actually applied this cycle (both modes) |

`GAIN_CURRENT` readback is what lets you (a) verify auto converges to the manual
value you found, and (b) harvest the power→gain pairs that define the curve.

**Auto compute (feed-forward):** `gain = GAIN_TARGET / sqrt(power(ch))`, using the
existing per-channel power register. Implement the reciprocal-sqrt as a small
**AXI-writable LUT** (power index → gain) so the curve is populated *live from
characterization data* — no rebuild to reshape it. (A coarse piecewise curve is
fine to start; refine from logged points.)

### 3c. Debug ports to route out (the `open` → port work)

Same pattern as the existing `dbg_tgt_i/q` taps: connect each `open` to a named
signal in `rx_top`, add a matching `out` port, pass it through `rx_axi`,
repackage the IP, then probe in the BD. Widths confirmed from the submodule
entities:

| signal | source | width | notes |
|---|---|---|---|
| `dbg_fs_state` | fsync `debug_state` | 3 | HUNTING/LOCKED/VERIFYING |
| `dbg_fs_corr` | fsync `debug_correlation` (signed) | 32 | cast to slv |
| `dbg_fs_corr_peak` | fsync `debug_corr_peak` (signed) | 32 | cast to slv; vs 38000 |
| `dbg_fs_soft_q` | fsync `debug_soft_quantized` | 3 | quantizer OUT |
| `dbg_soft_corr` | `rx_data_soft_corr` (signed) | 16 | quantizer IN (cast) |
| `dbg_sym_valid` | `rx_dvalid` | 1 | symbol strobe / slow-ILA qualifier |
| `dbg_cst_iq_delta` | demod `dbg_acc_iq_delta_f1` | 32 | lock discriminant vs thr(8) |
| `dbg_cst_acc_i` / `_q` | demod `dbg_acc_i_f1` / `_q_f1` | 32 each | raw accum behind discriminant |
| `dbg_f1_err` / `dbg_f2_err` | demod `f1_error` / `f2_error` | 32 each | loop phase error = tracking quality |
| `dbg_lpf_acc_f1` / `_f2` | demod `lpf_accum_f1` / `_f2` (ACC_W) | 32 each | integrator = settled freq offset |
| `dbg_cst_locktime_f1`/`_f2` | demod `cst_lock_time_f1`/`_f2` | 16 each | how the 128-count plays out (count question) |
| `dbg_cst_unlock_f1`/`_f2` | demod `cst_unlock_f1`/`_f2` | 1 each | dropouts |
| `dbg_gain_cur` | gain node applied gain | 18 | also in GAIN_CURRENT reg |

### 3d. Two ILA blocks (different clocks, different jobs)

The Costas loop updates at the channel-sample rate (~625 ksps); the soft /
correlation / frame signals at the symbol rate. One capture mode can't serve
both — so two cores.

**`ila_rx_fast`** — free-run fabric clock (fine timing; qualify on `rx_svalid`
for a longer sample-rate window when watching loop settling):

| probe | signal | w |
|---|---|---|
| 0/1 | `dbg_tgt_i` / `dbg_tgt_q` | 16/16 |
| 2 | `dbg_sym_valid` | 1 |
| 3 | `dbg_cst_iq_delta` | 32 |
| 4/5 | `dbg_cst_acc_i` / `_q` | 32/32 |
| 6/7 | `dbg_f1_err` / `dbg_f2_err` | 32/32 |
| 8/9 | `dbg_lpf_acc_f1` / `_f2` | 32/32 |
| 10/11 | `dbg_cst_locktime_f1` / `_f2` | 16/16 |
| 12/13 | `cst_lock_f1` / `cst_lock_f2` | 1/1 |
| 14/15 | `dbg_cst_unlock_f1` / `_f2` | 1/1 |

**`ila_rx_slow`** — capture qualified on `dbg_sym_valid` (one sample/symbol →
4096 deep ≈ 2 frames; bump to 8192 for margin, BRAM is not the constraint):

| probe | signal | w |
|---|---|---|
| 0 | `dbg_soft_corr` (quantizer in) | 16 |
| 1 | `dbg_fs_soft_q` (quantizer out) | 3 |
| 2 | `dbg_fs_corr` | 32 |
| 3 | `dbg_fs_corr_peak` | 32 |
| 4 | `dbg_fs_state` | 3 |
| 5 | `frame_sync_locked` | 1 |
| 6 | `frames_received` | 32 |
| 7 | `dbg_gain_cur` | 18 |

`system_bd.tcl`: two `create_bd_cell ... ila` blocks, set `C_NUM_OF_PROBES` /
`C_PROBEn_WIDTH`, `CONFIG.C_EN_STRG_QUAL {1}` on the slow one, `ad_connect` each
probe. Update the `puts "INFO:"` lines.

---

## 4. Bring-up & tuning workflow (the documented procedure)

All steps after the build are **live — no rebuild**.

1. **Manual sweep.** `GAIN_MODE=0`. Sweep `GAIN_MANUAL` while watching
   `ila_rx_slow`: drive `dbg_soft_corr` (quantizer input) until its swing fills
   the ±2800 buckets without saturating into all-strong, and `dbg_fs_soft_q`
   shows real gradation (not stuck at 011 "uncertain" or pinned at the extremes).
2. **First lock.** As the soft lands in range, `dbg_fs_corr_peak` should climb
   toward the sim's ~50001 and cross 38000 → `frame_sync_locked` asserts,
   `frames_received` climbs. Confirm on Bouro / `devmem 0x84A80044`.
3. **Read the operating point.** Log `GAIN_CURRENT`, the channel power register,
   and `dbg_cst_iq_delta`. That gain + power pair is one point on the auto curve.
   Vary Paul's TX level (or an attenuator) and repeat to get several points.
4. **Set the Costas threshold honestly.** With the discriminant now normalized,
   read `dbg_cst_iq_delta` at lock and set `SYM_LOCK_THRESHOLD` (0x028) to a real
   fraction of it — not a rubber stamp. Watch `cst_unlock_*` for false drops.
5. **Populate the auto curve.** Write the logged power→gain points into the LUT.
6. **Flip to auto.** `GAIN_MODE=1`. Confirm `GAIN_CURRENT` converges to the gain
   you found manually at each level, and lock holds as the level varies.

### Reading the captures

- `dbg_fs_corr_peak` ≥ ~38k with clean `dbg_fs_soft_q` → working; tune Costas thr.
- peak 25–35k, soft gradation present but weak → nudge gain up.
- soft pinned at 011 (all uncertain) → gain too low.
- soft all 000/111 (all strong) → gain too high (or genuinely hard-limiting).
- `dbg_cst_iq_delta` ≫ threshold while faint channels won't lock → confirms the
  normalization argument; the threshold was never the fix, the gain spread was.

---

## 5. Live knobs after this build (no rebuild for any of these)

`GAIN_MODE`, `GAIN_MANUAL`, `GAIN_TARGET`, the auto LUT, `OUTPUT_SHIFT`
(0x84A70014), `SYM_LOCK_COUNT`/`THRESHOLD` (0x024/0x028), `rx_invert` (0x84A80004),
`FREQ_WORD_F1/F2`. The frame-sync `HUNTING`/`LOCKED` thresholds stay generics for
now — once quantization is normalized they should sit back in their calibrated
range; promote them to registers only if the captures say they need it.

---

## 6. 64-channel notes (forward-looking, not this build)

- Gain becomes per-channel state in the TDM demod; the feed-forward law is
  evaluated per channel from each channel's power register.
- Feed-forward (vs a loop) matters more here: stations key up/down, and
  feed-forward responds instantly without per-channel loop settling.
- One quantizer and one Costas threshold then serve all 64 channels, because the
  gain node has removed the amplitude spread before the demod ever sees it.

## 7. Deferred warts (TODO, not blocking)

- `frame_count` (channelizer) vs `frames_received`/`demod_frames` (demod) — the
  "frames" name collision. Rename pass.
- Per-register descriptions in Bouro and the headers.
