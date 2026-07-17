# OPV Channelizer Output: Per-Channel Normalize-and-Requantize Block

Status: DRAFT for review. Strict ASCII. Open Research Institute, Haifuraiya / MDT.

## 1. Purpose: the amplitude contract

This block replaces the single global OUTPUT_SHIFT on the channelizer output
with a per-channel normalizer. It defines and enforces ONE contract for the
whole receive chain downstream of the channelizer:

    Every ACTIVE channel leaves this block at the same target RMS, T,
    regardless of that channel's received power.

T is the amplitude reference the rest of the design is tuned against. Frame-sync
hunt/verify thresholds, the soft-bit quantizer thresholds (QUANT_THR_1..3),
symbol-lock, and any other fixed decision level are calibrated to T. The block
delivers the world; the thresholds are tuned to that world. This is the inverse
of today's situation, where each threshold implicitly fights an unknown,
per-channel, near-far-dependent input scale.

T is a single calibrated constant. Its numeric value is NOT required to build or
verify this block; it is set once from simulation and then hardware (see Sec 9).
The block is correct for any T within the gain range of Sec 5.

## 2. Why (the problem this fixes)

The ADRV9002 AGC acts on the entire 10 MHz RF band: one gain for all 64 channels.
Channelizing breaks the relationship between each channel and that single AGC
value. Stations differ in PA, distance, and capability, so per-channel received
power spans tens of dB. A single OUTPUT_SHIFT cannot place 64 differently-scaled
channels into one 16-bit window: a shift that protects the strongest channel
buries the weak ones far below every fixed threshold; a shift that lifts the weak
clips the strong (catastrophic for constant-envelope MSK). The demod symbol
metric is linear in sample amplitude, so a channel arriving tens of dB low
produces soft values that collapse into the bottom quantizer bin (uniform
erasure), starving the Viterbi of soft-decision gain and dropping the sync
correlation peak below the hunt threshold. Consistent amplitude is therefore a
precondition for the fixed thresholds to work at all.

## 3. Domain model: three channel states

Each channel is in one of three states. The gain policy is defined per state.

    EMPTY     : power below the activity threshold. Noise only.
                Gain places the measured noise floor at a fixed LOW level
                (NOISE_DBFS, e.g. -36 dBFS): NOT unity, NOT T. Unity saturates
                (the 40-bit noise floor exceeds 16-bit full scale); normalizing
                to T manufactures false activity and rail-slams the sync
                correlator. Floor placement keeps empty channels quiet and at a
                consistent level. (Corrects an earlier "hold at unity" rule that
                the reference model showed saturates across the 40->16 step.)

    ACQUIRING : power just crossed the activity threshold.
                Gain set FEEDFORWARD from the fast-EMA power estimate, so
                samples are at T before sync detection needs them. The fast
                EMA (alpha1 = 2^-6, ~100 us at 625 kSps) settles in ~0.3-0.5 ms,
                about 30 symbols of the 40 ms (~2168-symbol) preamble.

    ACTIVE    : a burst is being demodulated.
                Gain FROZEN (or slew-limited very slowly). Constant-envelope
                MSK carries no amplitude information to track; holding steady
                keeps the carrier and timing recovery undisturbed.

State is derived from the per-channel EMA power estimate versus the activity
threshold, plus the frame-sync lock status for the ACTIVE freeze.

## 4. Datapath and ordering

Order is load-bearing. The only irreversible step (40->16) is last and
per-channel; everything that needs full dynamic range happens before it.

    channelizer output (complex, ACCUM_WIDTH = 40, per channel, with TDEST)
      |
      v
    [1] MEASURE per-channel power on the 40-bit samples (existing EMA detector).
      |    This tap sees TRUE received power (droop-corrected, pre-gain) and
      |    feeds both the normalizer and the CHANNEL_POWER telemetry.
      v
    [2] GATE: compare estimate to activity threshold -> {EMPTY | ACTIVE-ish}.
      v
    [3] COMPUTE per-channel gain (shared, time-multiplexed; Sec 5):
      |    active: gain[ch] = f(T / P_measured[ch]) * droop[ch]
      |    empty : gain[ch] = droop[ch] (unity normalize) or held
      v
    [4] APPLY gain on the 40-bit samples (I and Q identically: real scalar,
      |    phase untouched -> safe for the coherent demod).
      v
    [5] SATURATE and REQUANTIZE to 16-bit (round-half-up, clamp +/-32767).
      v
    output (complex 16-bit I/Q, TDEST, TUSER = applied gain, valid)

Measure before you cut; cut once; cut per-channel. With this in place the global
OUTPUT_SHIFT is subsumed by per-channel gain and is removed as a required knob
(an optional fixed coarse prescale may remain only to bound gain word width).

## 5. Gain representation and dynamic range (MUST size now)

Requirement R1 (range, both directions): gain must ATTENUATE the strongest
channel down to T and BOOST a far channel up to T. Provision for at least a
60 dB total span (recommend headroom to ~72 dB) so T and the near-far depth we
choose to rescue digitally are not foreclosed by datapath width.

Requirement R2 (precision): gain quantization must not itself scatter channels
around T. Hold delivered level within about +/-0.1 dB of T, i.e. gain fine step
< ~1 percent.

Recommended structure (keeps the multiplier small): per-channel COARSE power-of-2
shift + FINE fixed-point multiply.

    coarse s[ch] : signed shift, ~6.02 dB per step, covers the wide near-far span
    fine  m[ch]  : Qx.16 multiply (~0.5 .. ~2.0), covers < 1 step plus the
                   static halfband droop correction folded in

    scaled = shift(sample * m[ch], base - s[ch])
    out    = sat16(round_half_up(scaled))
    applied_gain[ch] = m[ch] * 2^(s[ch] - base)     # exported in TUSER

This reuses the channel_eq datapath (one multiplier + a per-channel gain word);
the change is that the gain word becomes {s[ch], m[ch]} in a writable RAM instead
of a static ROM, and it is produced by the normalization controller (Sec 6), not
hardcoded. The static droop correction (current channel_gain_pkg values) folds
into m[ch]: gain[ch] = droop[ch] * normalize[ch].

Requirement R3 (saturate-last): saturation is the only place clipping is allowed,
and it happens after gain. Report a per-channel saturation-event flag/count for
telemetry so a mis-set T or an over-boosted channel is observable.

## 6. Control interface (AXI-Lite, live-tunable)

All decision values are live-tunable over AXI with no rebuild, matching the
existing demod register convention. Reset defaults are placeholders (Sec 9),
not final calibration.

    OFFSET  NAME              DIR  NOTES
    ------  ----------------  ---  ------------------------------------------
    (tbd)   NORM_TARGET_T     RW   target power (T^2) the EMA estimate is
                                   normalized to. Power form matches the EMA;
                                   gain ~ sqrt(T_power / P_measured).
    (tbd)   NORM_ACT_THRESH   RW   activity threshold (power) over noise floor;
                                   below -> EMPTY (held), above -> normalize.
    (tbd)   NORM_MAX_GAIN     RW   max boost clamp (bounds noise amplification
                                   on marginal channels and gain word range).
    (tbd)   NORM_HOLD_MODE    RW   ACTIVE-state gain policy: freeze on lock vs
                                   slew-limit; slew rate.
    (existing) POWER_ALPHA1/2 RW   EMA alphas (fast tracker / slow smoother).
    (existing) per-channel droop table -> now writable RAM (folds into m[ch]).

Removed/retired: the single global OUTPUT_SHIFT as a required control (subsumed).

The normalization CONTROLLER is one shared, time-multiplexed compute block behind
the gain RAM. Update load is 64 channels * 25 Hz (40 ms frame) = 1600 gain
updates/sec, so a single divide-or-log unit has enormous headroom; do NOT build
64 dividers. A leading-zero-count log approximation (gain exponent =
(log2 T_power - log2 P) / 2, small mantissa LUT) needs no divider or CORDIC; an
iterative divide is also fine at this rate.

## 7. Data interface

    Input  : complex, signed(39:0) I and Q, TDEST(5:0) channel index, valid.
    Output : complex, signed(15:0) I and Q, TDEST(5:0), valid,
             TUSER = applied_gain[ch] for this sample's channel.

TUSER carries the applied per-channel gain out WITH the samples. Because a
channelizer frame presents all 64 channels together, per-channel gain in TUSER
(alongside TDEST) is the natural home and must be delivered so telemetry can undo
it (Sec 8). Exact TUSER width/format follows the gain representation of Sec 5.

## 8. Telemetry accounting (restores the AGC relationship)

Channelizing severed the band-wide AGC <-> per-channel relationship. It is
rebuilt in bookkeeping, valid only because the applied gain rides out in TUSER
and power is measured PRE-gain:

    P_abs[ch] = measured_level[ch] - digital_gain[ch] - ADRV9002_AGC_gain + cal

measured_level[ch] : from the pre-gain EMA tap (CHANNEL_POWER).
digital_gain[ch]   : applied_gain[ch] from TUSER.
ADRV9002_AGC_gain  : the band-wide radio AGC value.
cal                : one-time system calibration constant.

## 9. Deferred parameters (we do NOT need these now)

These are calibration values, set from evidence, not needed to build or verify
the block. Each has a defensible placeholder default and a pinning method.

    PARAM            PLACEHOLDER        PINNED FROM
    ---------------  -----------------  -------------------------------------
    NORM_TARGET_T    ~ -12 dBFS16       matched-filter peak-to-RMS and the
                     (headroom guess)   soft-decision dynamic range of the
                                        demod actually in use (opv_demod_clean
                                        path), first in sim, then hardware.
    NORM_ACT_THRESH  a few dB over      measured per-channel noise floor
                     noise floor        (empty-channel EMA reading).
    NORM_MAX_GAIN    ~ +48 dB           observed real near-far spread; bounded
                                        by the honest limit in Sec 10.
    NORM_NOISE_DBFS  ~ -36 dBFS16       where EMPTY channels' noise floor is
                                        placed; low enough to read as "quiet" to
                                        every downstream threshold, high enough
                                        to avoid underflow. Set with T.

Pinning method for T when ready: drive the demod in use with a clean OPV burst at
a known channel-sample RMS, observe the matched-filter peak-to-RMS and the
soft-value distribution against the (also-under-review) quantizer thresholds, and
choose T for good headroom (clean-symbol peak does not clip; clean symbols reach
the top confidence bin; noise-marginal symbols spread across bins rather than
collapsing to erasure). Do this in sim first, confirm on hardware. Until then the
placeholder stands and the block is fully functional and testable.

## 10. Honest boundary (what this does NOT fix)

Per-channel digital normalization fixes requantization pain, delivers one
consistent amplitude to every fixed threshold, and restores the telemetry math.
It does NOT restore SNR lost at the ADC. If a strong station forced the band-wide
AGC to back off, the weak channels were digitized with fewer real bits before any
DSP ran; that SNR is gone and no digital gain recovers it. Digital gain scales
signal and noise together. The residual near-far problem lives at RF
(channel-selective preselection) or in the protocol (power control / ranging so
stations arrive within a window). This block is the requantization-and-bookkeeping
fix, not a near-far fix.

## 11. Verification plan (dual-oracle, L5 slot)

Golden model + bit-exact TB, matching the halfband/FFT/filterbank pattern.

    ORACLE 2 (bit-exact): output I/Q, TDEST, and TUSER gain bit-exact to a
      fixed-point model of measure -> gate -> gain -> saturate, across a
      near-far scene and a set of TARGET_T / ACT_THRESH / MAX_GAIN settings.

    ORACLE 1 (analytic, in-hardware):
      a. Contract: every ACTIVE channel's delivered RMS equals T within the
         gain-quantization bound (R2), independent of input level.
      b. Gating: EMPTY channels are not boosted (delivered noise stays at the
         held gain; no amplification to T).
      c. Saturate-last: a deliberately over-target channel clamps at +/-32767
         and asserts the saturation flag; no wraparound.
      d. Passthrough: when input RMS already equals T and droop is unity, gain
         is unity and output equals input>>requant (identity check).
      e. Telemetry: measured_level - digital_gain reconstructs the true
         pre-gain level within tolerance.

T's numeric value is a TB generic, so the same suite proves correctness for any
T and is re-run once T is pinned.

## 12. Relationship to existing RTL

    channel_eq.vhd        : reuse the multiply+saturate datapath; widen the gain
                            word to {coarse shift, fine multiply} for full range.
    channel_gain_pkg.vhd  : static droop ROM -> writable gain RAM; droop folds
                            into the fine multiply as one factor of gain[ch].
    EMA power detector    : existing; provides the pre-gain per-channel estimate
                            for both normalization and CHANNEL_POWER telemetry.
    OUTPUT_SHIFT          : subsumed by per-channel gain; retire as a required
                            control (optional fixed prescale only).
    normalization ctrl    : NEW shared block; walks 64 power estimates, computes
                            gain, writes the gain RAM (1600 updates/sec).
