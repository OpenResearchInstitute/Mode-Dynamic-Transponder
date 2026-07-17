# Where we are, what exists, and what to do next

Written 2026-07-10. This replaces the shorthand I was using. Nothing below
assumes you have anything except what is in this repo.

---

## The quantizer bug (FIXED 2026-07-10)

`FUNCTION quantize` in `rtl/.../frame_sync_detector_soft.vhd` was **asymmetric**.
It was a correctness bug, independent of signal level, and it does not depend on
the normalizer or on anything else in flight.

### Why it is wrong

`opv_demod.hpp` (`ViterbiDecoder::decode`) forms the branch metrics as

```
expected 0  ->  bm = sg
expected 1  ->  bm = SOFT_MAX - sg          SOFT_MAX = 7
```

Lower metric wins, so `sg < 3.5` favours a '0' and `sg > 3.5` favours a '1'.
For the map to mean anything it must satisfy `q(-s) = 7 - q(s)`.

And `FrameDecoder::decode_soft3()` -- the entry point the ZCU102 uses -- takes
the fabric's 3-bit codes with **no rescale and no sign flip**. There is nothing
downstream that can correct an asymmetric map.

The shipped function:

| soft region     | fabric emits | should be |
|-----------------|--------------|-----------|
| `< -thr3`       | 7            | 7         |
| `[-thr3,-thr2)` | 5            | **6**     |
| `[-thr2,-thr1)` | 4            | **5**     |
| `[-thr1, 0)`    | 3            | **4**     |
| `[0, thr1)`     | 3            | 3         |
| `[thr1, thr2)`  | 2            | 2         |
| `[thr2, thr3)`  | 1            | 1         |
| `>= thr3`       | 0            | 0         |

Code 6 is never emitted. The 3<->4 boundary sits at `soft = -thr1` instead of
at `soft = 0`, so **every soft value in `[-thr1, 0)` is decoded with the wrong
sign** and every decision carries a `+thr1` offset.

Measured on real OPV frames through the real `msk_demodulator`, at input
amplitude 56 (defaults 500/1400/2800):

```
current quantizer:  code3 = 66.5%   code4 = 13.1%     (5x imbalance)
fixed   quantizer:  code3 = 30.9%   code4 = 35.6%     (balanced, as it must be)
```

and against the reference decoder, over five input amplitudes:

```
fixed   quantizer agrees with opv_demod.hpp on  99.5% - 100% of symbols
current quantizer agrees on                     68% - 75%
```

### Why it has not shown up

While the soft path rails, only codes 0 and 7 are used -- the only two the
fabric gets right. `SOFT_SHIFT` is hardcoded at 21 and the shipped thresholds
are 500/1400/2800, so at normal signal levels ~87% of symbols rail. The bug is
hidden by the railing. **The normalizer's whole purpose is to unrail the soft
path.** Landing it without this fix walks the demod into the defect.

### How to fix it

Open `rtl/.../frame_sync_detector_soft.vhd`, find `FUNCTION quantize` (around
line 371), and replace the seven `IF/ELSIF` lines with these eight:

```vhdl
IF    soft <= -thr3 THEN RETURN "111";   -- 7
ELSIF soft <= -thr2 THEN RETURN "110";   -- 6  (was 5; 6 was unreachable)
ELSIF soft <= -thr1 THEN RETURN "101";   -- 5  (was 4)
ELSIF soft <=  0    THEN RETURN "100";   -- 4  (was 3 -- WRONG SIGN)
ELSIF soft <   thr1 THEN RETURN "011";   -- 3
ELSIF soft <   thr2 THEN RETURN "010";   -- 2
ELSIF soft <   thr3 THEN RETURN "001";   -- 1
ELSE                     RETURN "000";   -- 0
END IF;
```

Three changes: `<` became `<=` on the negative half; `soft < thr1` became
`soft <= 0`; the negative codes shifted up by one so 6 exists.

There is also `quantize_fix.patch` if you prefer. Verified to apply with
`git apply --check` and `patch -p1 --dry-run`. From a directory where the file
sits at `rtl/frame_sync_detector_soft.vhd`:

```
git apply --check --stat quantize_fix.patch    # look at the reported path
git apply quantize_fix.patch                   # or: patch -p1 < quantize_fix.patch
```

If the path does not match your tree, try `-p2`, or just make the edit by hand.
It is eight lines.

### How to check it took

```
source run_soft_quantizer.tcl
```

`tb_soft_quantizer.vhd` is **self-contained**. It carries both the current and
the fixed function inside itself, needs no RTL, no vectors, no python. It runs
before you touch a single source file.

Expect:

```
Q5 ok (negative control): CURRENT violates q(-s)=7-q(s) on 921 of 1601 points
Q5 ok (negative control): CURRENT never emits code 6
Q5 ok (negative control): CURRENT's 3<->4 boundary is at soft = -92, not 0
Q1 PASS  Q2 PASS  Q3 PASS  Q4 PASS  Q6 PASS
COMPAT PASS: outside +/-thr3 the fix changes NOTHING.
SOFT QUANTIZER TB PASSED
```

`COMPAT PASS` matters: outside `+/-thr3` the two functions are identical, so any
capture whose soft path was railed decodes **bit-for-bit unchanged**. If a
regression you already have starts failing after this edit, something else moved.

---

## Where the normalizer stands

`rtl/channelizer/channel_normalizer_mux.vhd` was REWRITTEN on 2026-07-10. It is
now stateless: three registers, two multiplies, no per-channel state. The earlier
version -- `attack_shift`, `release_shift`, `squelch_hang`, `freeze`, a dwell
counter, a 32-entry AXI-writable LUT, six per-channel state RAMs -- is superseded
and deleted. See `NORMALIZER_REGISTERS.md` for what `GAIN_MODE`, `GAIN_TARGET`
and `SQUELCH_THR` mean and how to choose them.

    gain = GAIN_TARGET / sqrt( max(channel_power, SQUELCH_THR) )
    out  = saturate( round( in * gain ) )

| file | what it is | in the datapath? |
|---|---|---|
| `rtl/channelizer/channel_normalizer_mux.vhd` | the block. VHDL-93 and 2008 clean. 8 oracles, 7 mutants caught. | after the bypass patch, yes |
| `sim/tb_channel_normalizer_mux.vhd` + `run_channel_normalizer_mux.tcl` | its bench. No golden vectors, no python. | n/a |
| `normalizer_bypass_insert.patch` | inserts it into `rtl/axi/haifuraiya_channelizer_axi.vhd` with `gain_mode='0'` | the step to do |
| `sim/tb_soft_quantizer.vhd` + `run_soft_quantizer.tcl` | proved the quantize() fix | n/a |
| `sim/tb_demod_soft_scale.vhd` + `run_demod_soft_scale.tcl` | diagnostic: soft vs input amplitude | n/a |
| `sim/tb_chan_axi_equiv.vhd` | dumps `m_axis_chans` so two builds can be diffed | n/a |

**STALE FILE IN THE SOURCE LIST.** `run_haifuraiya_channelizer_axi_test.tcl`
line 84 lists `../rtl/rx/channel_normalizer.vhd`. That is the OLD single-channel
block. It compiles but is instantiated nowhere -- `haifuraiya_rx_top` does its
manual gain with an inline multiply. Delete it, or two normalizers live in the
tree with confusingly similar names.

## What is still NOT wired

After the bypass patch, `gain_mode`, `gain_target` and `squelch_thr` are
CONSTANTS inside `haifuraiya_channelizer_axi.vhd`, and `power` is tied off. The
block is in the datapath and doing nothing. That is the point of the step.

To turn it on, three things, none of them done:

1. **`power`** must be driven with `stat_channel_power` for the CURRENT
   `eq_chan` -- a 64:1 mux of 31 bits, roughly 650 LUTs. The power detectors
   keep tapping the un-normalized `eq_re`/`eq_im`: sense before, correct after.
2. **`GAIN_MODE`, `GAIN_TARGET`, `SQUELCH_THR`** become AXI-Lite registers.
   Which map they live in (`axi_lite_regs` or `haifuraiya_demod_regs`) is a
   decision, not a file.
3. **`SQUELCH_THR`** needs the measured per-channel noise floor. Read
   `CHANNEL_POWER[1..63]` from Bouro with no transmitter, antenna terminated.
   Skip channel 0 (LO leakage DC spike). Channels 28-31 and 33-36 read up to
   +2.67 dB high -- that is `channel_eq`'s droop correction, not noise.
   Then `SQUELCH_THR ~= 4 x floor`, subject to the constraint in
   `NORMALIZER_REGISTERS.md`.

## Suggested order

**1. Fix `quantize()`.** DONE 2026-07-10.

**2. Insert the normalizer IN BYPASS and prove nothing changed.**
   Apply `normalizer_bypass_insert.patch`, add
   `../rtl/channelizer/channel_normalizer_mux.vhd` to the channelizer test's
   source list, re-run that test. `m_axis_chans` must be byte-identical.
   Verified in GHDL: 768 beats, tdata/tdest/tlast, byte-for-byte, with four
   mutations proving the check has teeth.

**3. Run the diagnostic, if you want to see the problem for yourself.**
   `source run_demod_soft_scale.tcl` at AMP = 900, 450, 225, 112, 56, then
   `python3 golden/analyze_soft_scale.py soft_*.txt`. Optional. It changes
   nothing; it only shows you that `mean|rx_data_soft|` is linear in input
   amplitude, which is why the normalizer exists.

**4. Wire the controls** (see above) and flip `gain_mode` to `'1'`.

**5. Only then, thresholds.**
   `QUANT_THR_1/2/3` must be `S/3.5`, `2S/3.5`, `3S/3.5` (ratio **1:2:3**),
   where `S = mean|rx_data_soft|` at the normalized level. That ratio is forced
   by `n = (-soft/scale)*3.5 + 3.5` in `FrameDecoder::decode()`; it is not a
   tuning choice. The three ratios currently in the tree -- 1:2.8:5.6
   (`demod_regs` defaults), 1:3:5 (hardware calibrated), 1:2:3 (what the C++
   requires) -- are not the same quantizer.

   Do NOT set these before step 4. Nothing stabilizes the level yet.

## Also worth knowing

- `reg_rx_invert` in `haifuraiya_demod_regs.vhd` defaults to `'1'`. Bring-up
  confirmed straight polarity (`rx_invert = 0`). Software must write 0 every
  boot, or the default should change.

- `SOFT_SHIFT` is not a generic. It is hardcoded as `shift_right(d1-d2, 21)` in
  `msk_demodulator.vhd`, with the comment "scaled so strong symbols ~83% of
  rail". Keeping it at 21 is right for now.

- `SPS_FP = 755719` in `msk_demodulator.vhd` is hardcoded for 625 ksps. The
  standalone 134-byte bench runs at 61.44 MHz and is a different branch and a
  different demodulator. It cannot exercise this file, and its freq words
  (0xFFF18BF2 / 0x000E740E) are 98x off for this one. The correct words for
  625 ksps are already the `haifuraiya_demod_regs` defaults:
  `0xFA732DF5` / `0x058CD20B`.
