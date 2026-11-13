# The tier-3 digital downconverter white paper

_Status 2026-11-12: paper only. Nothing in this document has been simulated
or built. Every number is arithmetic from the stated inputs and is labelled;
the inputs that still need the EV12AQ600 datasheet are listed in §7. The
bench comes next (§8), then the VHDL._

## 0. Why this block exists, in one paragraph

Tier 2 proved out the serial link. The receiver gets its 20 MSps I/Q stream
through Teledyne's ESIstream (the converter serial-interface standard) and
the GTY transceivers, bit-exact to tier 1. Tier 3 puts in the real analog to
digital converter (ADC), the EV12AQ600 on its FMC evaluation module, at the
far end of that link. The ADC does not produce 20 MSps I/Q; it produces
1.25 G real samples per second of a 580–600 MHz intermediate frequency
(IF). The digital downconverter (DDC) is the block that turns the 1.25 Gsps
of real samples into 20 MSps I/Q data (complex). It replaces the tier-2 
reassembler at the same point in the design. Importantly, 
**the receiver never learns the ADC exists**. Everything upstream of its
20 MSps input is the tier under test.

```
tier 2:  pacer -> packer -> ESIstream TX -> GTY -> (loopback) -> GTY -> ESIstream RX -> reassembler    -> FIFO -> receiver
tier 3:  antenna -> EV12AQ600 ---------------------------------> GTY -> ESIstream RX -> downconverter -> FIFO -> receiver
```

## 1. The contract

**Input** (from `rx_esistream`, in the `rx_clk` domain, 156.25 MHz): two
lanes × four 14-bit ESIstream frames per clock. In Teledyne's own
`aq600/src_top`, the ADC sample is the **low 12 bits of each 14-bit
frame** (`frame_out(i)(j)(11 downto 0)`; verified in the package). So the
DDC sees **eight 12-bit real samples per clock = 1.25 GSps**, which is one
core of the EV12AQ600 in 4-channel mode at f_CLK = 5 GHz (f_CLK / 4). Cross-
check: 1.25 GSps × 16 bits per frame = 20 Gb/s = 2 lanes × 10 Gb/s, the
line rate the tier-2 link already runs. Same transceiver configuration,
same reference frequency (SSO = f_CLK / 32 = 156.25 MHz). **This is why
f_CLK is pinned at 5 GHz**: it is the one value that keeps the validated
link settings.

**Output** (to the existing `rx_clk → aclk` asynchronous FIFO, then the
receiver): 32-bit `{Q[15:0], I[15:0]}` AXI-Stream beats at **20.000 MSps**
(one beat per 5 `aclk` at 100 MHz, which is what the pacer produces in
tier 1 and the reassembler in tier 2). The receiver's 2:1 halfband
decimator, its per-channel equalizer (`channel_eq`, a fixed table that
flattens that halfband's edge droop) and everything after them stay as
they are. Delivering 10 MSps and bypassing the halfband was considered
and rejected: the halfband is hardwired inside `haifuraiya_channelizer_axi`
and the equalizer assumes it, so a bypass is a receiver change plus a
re-derived table plus a re-grade.

**Rate ratio:** 1.25 G / 20 M = **62.5** — not an integer. Internally the
DDC decimates by 25 and then resamples by 2/5 (§3); that is the DDC's
private business.

## 2. The numbers (arithmetic from f_S = 1.25 GSps and the 5.65–5.67 GHz band)

| quantity | value | how |
|---|---|---|
| Nyquist zone of 5.66 GHz | **10** | 5.66 / 0.625 = 9.06 → tenth zone (9 × 0.625 = 5.625 < 5.66 < 6.25) |
| IF of the band centre | **590 MHz** | 5 × 1.25 − 5.66 = 0.59 (even zone: subtract from the nearest multiple above) |
| IF of the band | **580–600 MHz, spectrally inverted** | 6.25 − 5.67 = 0.58; 6.25 − 5.65 = 0.60. The upper RF edge lands at the lower IF edge |
| NCO frequency | 590 MHz = **59/125** of f_S | gcd(590, 1250) = 10. The oscillator repeats every 125 samples exactly — a 125-entry table, no phase-accumulator truncation |
| NCO direction | multiply by **e^{+j2π(59/125)n}** | RF at 5.66 GHz + δ lands at IF 590 MHz − δ; a positive rotation moves its negative-frequency image, −(590 − δ), to **+δ**: upright baseband. (A negative rotation would leave it inverted.) |
| NCO per-clock step (8 samples) | 8 × 59 = 472 ≡ **97** (mod 125) | one accumulator per clock, modulo 125 |
| NCO lane offsets (lane j = 0..7) | 59 j mod 125 = **0, 59, 118, 52, 111, 45, 104, 38** | each of the eight parallel samples reads the table at accumulator + offset |

ESISTREAM_NOTES §5 said "660 MHz, non-inverted"; that was the zone-9
arithmetic (5.66 − 4 × 1.25 = 0.66), and 0.66 GHz is above f_S / 2 = 0.625
GHz, so it folds. Corrected there in the same commit as this file.

## 3. Architecture: three stages, all in programmable logic

Everything runs in `rx_clk` (156.25 MHz, the ADC's clock through the
transceiver), eight samples wide where the rate demands it, with valid
strobes once the rate drops below one sample per clock.

```
8 x 12-bit real @ 1.25 GSps
   |
   v
[1] complex mixer: 8 parallel (real x e^{+j theta}) -> 8 x complex, 16-bit I and Q (rounded)
   |
   v
[2] CIC decimator R = 25, N = 4, parallel integrators (8 in / clock), combs at 50 MSps
   |   -> complex @ 50 MSps  (0.32 samples per clock; valid strobe)
   v
[3] rational resampler 2/5: 2-phase polyphase FIR designed at 100 MSps
    (passband 0-5 MHz with inverse-CIC droop compensation, stopband >= 15 MHz)
   |   -> complex @ 20 MSps  (0.128 samples per clock)
   v
[4] requantize: programmable right shift + round + saturate -> {Q[15:0], I[15:0]}
   |
   v
existing rx_clk -> aclk asynchronous FIFO -> receiver
```

**Stage 1, mixer.** Eight real samples times eight complex table values
per clock: a real times a complex is two real multiplies, so 16 (12 × 16
bit), 16 DSP58s (the Versal DSP slice). The
table is 125 × (cos, sin) × 16 bit = 4,000 bits: one block RAM or
distributed memory, read at eight addresses per clock (eight copies of a
tiny ROM is the simplest).

**Stage 2, CIC (cascaded integrator–comb) decimator by 25.** The standard
multiplier-free first stage. The integrators run at the full 1.25 GSps,
which with eight samples per clock means **parallel integrators**: per
stage, the running sum across the eight lanes (7 adders, a prefix sum)
plus the carry-over from the previous clock (8 adders), 15 adders of ~35
bits; four stages for I and four for Q, about 120 adders. The combs run
after the decimation at 50 MSps (one sample per 3.125 clocks, valid
strobe) and are trivial. The decimator picks every 25th sample: index
n = 25 m + 24 lands in lane (25 m + 24) mod 8 of word (25 m + 24) div 8 —
a counter; since 25 > 8 there is at most one output per clock.

Why R = 25 and not 125 or 62.5: a CIC is a cascade of boxcars, so its
passband droops and its alias rejection near the output band edge is poor
when the output rate is close to the signal bandwidth. At 50 MSps the
±5 MHz band is a fifth of the output rate, and the numbers are good:

| CIC R = 25, N = 4 | value (arithmetic, `sin(πfR/f_S) / (R sin(πf/f_S))` to the 4th) |
|---|---|
| droop at 5 MHz (band edge) | **−0.57 dB** (compensated in stage 3) |
| droop at 10 MHz | −2.3 dB (outside the band; falls in stage 3's transition) |
| worst alias into the band (from 45 MHz) | **−76.8 dB** |
| from 55 MHz | −83.8 dB |
| from 95 MHz | −102.5 dB |
| N = 3 would give at 45 MHz | −57.6 dB (not enough margin over a 12-bit ADC) |
| N = 5 would give | −96.0 dB (more adders for nothing) |
| register growth | N log₂ R = 18.6 bits: 16-bit mixer output → 35-bit integrators |

Decimating all the way to 10 MSps in one CIC (R = 125) would put the band
edge at the output Nyquist frequency: −15.7 dB droop and zero alias
rejection there. That is the reason the ratio is split.

**Stage 3, 2/5 rational resampler with droop compensation.** 50 MSps →
20 MSps is interpolate-by-2, decimate-by-5. As a polyphase structure it is
one FIR filter designed at 100 MSps and split into two phases: output
sample m sits at input time 2.5 m, so even outputs use the integer-delay
phase and odd outputs the half-sample-delay phase, and the input advances
by 2, 3, 2, 3, … samples. The prototype filter: passband 0–5 MHz shaped as
the inverse of the CIC droop (+0.57 dB at the edge), stopband from 15 MHz
(everything that would alias into ±5 MHz after the ÷5 and every image
from the ×2), ≥ 80 dB. Kaiser estimate for 80 dB over a 10 MHz transition
at 100 MSps: **~50 taps**, 25 per phase. At 20 MSps output that is 20 M ×
50 complex-by-real MACs = 1 G MAC/s: 50 DSP58s written plainly, or about
7 time-shared at 156.25 MHz. Either fits (the VC1902 has 1,968).

For comparison, a single-stage filter doing the whole job at 1.25 GSps
would need ~630 taps evaluated eight times per clock — thousands of
multipliers. The three-stage split is what makes this a small block.

**Stage 4, requantize.** The CIC gain (25⁴ = 390,625) and the filter gain
come out through a programmable right shift with rounding and saturation
into 16 bits, the same mechanism the channelizer uses for its 40 → 16 bit
output. The shift is a register, set once at bring-up.

## 4. Registers (DDC block, AXI-Lite, same style as `esi_link_hw`)

Proposed; final when the VHDL exists.

| offset | name | contents |
|---|---|---|
| 0x00 | ID | `0x44444331` "DDC1" |
| 0x04 | CONTROL | bit 0 ENABLE, bit 1 STATS_CLEAR (pulse), bit 2 NCO_DIR (0 = +j, the default; 1 = −j, for a non-inverting zone later), bits 7:4 OUT_SHIFT |
| 0x08 | NCO_STEP | per-clock step modulo 125 (97 for 590 MHz); writable so a different band centre needs no rebuild |
| 0x0C | STATUS | bit 0 running, bit 1 output saturated (sticky), bit 2 FIFO overflow (sticky) |
| 0x10 | SAMPLES_IN | 1.25 GSps samples accepted (counts in units of 8) |
| 0x14 | SAMPLES_OUT | 20 MSps beats produced |
| 0x18 | IN_POWER | short-term mean of x² at the input (ADC drive level) |
| 0x1C | OUT_POWER | the same at the output |

Read by dōgu's `opv_play` like the link block; shown by Bouro like any
other registers. Nothing else configures it.

## 5. Resources (estimate)

| part | DSP58 | adders / LUT-ish | memory |
|---|---|---|---|
| mixer | 16 | — | 8 small ROMs |
| CIC ×2 (I, Q) | 0 | ~120 × 35-bit adders | — |
| resampler | ≤ 50 | — | coefficient ROM, 50 × 18 bit |
| requantize, registers, counters | 0 | small | — |
| **total** | **≤ 70 of 1,968** | small | small |

## 6. What the DDC does to the signal (estimates)

- **Resolution.** The ADC's effective bits at 5.6 GHz are about 7.5 (the
  datasheet's 4-channel-mode table, as cited in the 2026-11-01 mail to
  Teledyne). Decimation by 62.5 adds 10 log₁₀(62.5) = 18 dB ≈ 3 bits if
  the quantization noise is white: **~10.5 effective bits** into the
  receiver. The receiver was designed for 16-bit I/Q from the ADRV9002 and
  grades at 0–0.56 % BER on the recorded stimulus; whether ~10.5 bits
  changes the grade class is a bench question (§8), not a paper one.
- **Timing offset.** The 20 MSps clock is now f_CLK / 250 from the EVM's
  LMX2592, locked to the EVM's reference (100, 20 or 10 MHz; Marc,
  2026-09-11). Its ppm error appears as the receiver's SYM_CLK_OFFSET,
  exactly as tier 2's −11.39 ppm did. The symbol-timing loop absorbs it.
- **Frequency offset.** The NCO is exact (59/125), so the carrier error is
  the LMX2592 reference's ppm times 5.66 GHz: 1 ppm = 5.66 kHz, which the
  receiver's carrier loop sees as CFO. The recorded tier-2 CFO was 498 Hz.
  A 1 ppm reference would put us at ~6 kHz; what the loop tolerates is
  another bench question. (If it is too much, NCO_STEP is a register.)

## 7. Open — needs the EV12AQ600 datasheet or the EVM in hand

1. **Signedness and bit position of the 12-bit sample** inside the 14-bit
   frame (the package reads bits 11:0; whether that is two's complement or
   offset binary, and what bits 13:12 carry, is in the datasheet's
   ESIstream frame description).
2. **Sample order in time** across the four frames of a lane and across the
   two lanes BSL0/BSL1 (which frame of which lane is the earliest sample).
   The NCO lane offsets in §2 assume lane 0 frame 0 is sample 8k and
   lane 1 frame 3 is sample 8k + 7; the datasheet decides.
3. Whether 4-channel mode at 5 GHz is exactly f_CLK / 4 per core at the
   output (the rate cross-check in §1 says it must be; confirm).
4. The EVM's reference oscillator accuracy (for §6, frequency offset).
5. Channel B's analog specifications versus channel A's (assumed equal;
   ESISTREAM_NOTES §5).

## 8. The bench plan (next deliverable)

A golden model first, in Python (`tools/ddc_model.py`, next to
`which_phase.py`): a **fixed-point** model of stages 1–4, bit-exact to the
VHDL by construction — the same integer arithmetic, the same rounding, the
same coefficient quantization. Then `sim/ddc/tb_ddc.vhd` under nvc and
GHDL, fed from files the model writes, checking the VHDL output against
the model's **to the bit**, as the channelizer bench does.

Stimuli, each a labelled pass criterion:

1. **One tone** at 5.66 GHz + δ (δ = +1 MHz): one output tone at +δ (not
   −δ: this is the inversion check), amplitude as the model predicts.
2. **Two edge tones** at ±5 MHz: amplitude within ±0.1 dB of the centre
   (droop compensation works).
3. **Alias tone** at IF 545 MHz (45 MHz from the carrier, the CIC's worst
   case): ≥ 70 dB below a same-amplitude in-band tone at the output.
4. **The recorded Opulent Voice stimulus**: the 25-frame 20 MSps I/Q
   capture, interpolated to 1.25 GSps, upconverted to 590 MHz inverted,
   quantized to 12 bits — the ADC's view of it. DDC output versus the
   original 20 MSps stream: error power reported in dB (a number to
   record, not a pass/fail), then into the existing receiver bench:
   **24/24 frames, BER in the same class as tier 1** is the pass. Bit-exact
   agreement with tier 1 is **not** expected and not the criterion: the
   path is different (12-bit quantization, two filters).

Then the system bench `tb_haifuraiya_vck190_esi` gains a tier-3 generate:
Teledyne's TX emulator replaced by a file-driven ADC stand-in producing
stimulus 4 at the lane level, through the real `rx_esistream`, into the
DDC. That is the simulation that corresponds to the hardware.

## 9. Considered and rejected

- **AI Engines.** Versal's pitch for exactly this kind of filter. A new
  toolchain (Vitis, a different programming model, a runtime), opaque to
  a reader of the VHDL, for a block that is ≤ 70 DSP58s in plain VHDL and
  can be checked sample-for-sample. Not now, and nothing here prevents it
  later.
- **Single-stage decimating FIR** at 1.25 GSps: ~630 taps × 8 lanes.
- **CIC all the way** (R = 125): band edge at output Nyquist; see §3.
- **Bypassing the receiver's halfband**: a receiver change; see §1.
- **A different f_CLK** to make the ratio an integer (6.4 GHz gives
  1.6 G / 20 M = 80): changes the validated link settings and the SSO.
  5 GHz is Teledyne's validated configuration and the link's.
