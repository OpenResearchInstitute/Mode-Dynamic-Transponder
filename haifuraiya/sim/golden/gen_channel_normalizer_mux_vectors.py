#!/usr/bin/env python3
"""gen_channel_normalizer_mux_vectors.py -- analytic gate + golden vector emit.

House rule (docs/VERIFICATION_ARCHITECTURE.md): run the ANALYTIC oracle against
the model and exit nonzero WITHOUT WRITING VECTORS if it fails. Numpy-free.

  ORACLE 1 (analytic, here)
      G1 unity-gain identity
      G2 round-half-up
      G3 saturation clamps, never wraps
      G4 power estimate saturates (I=Q=MIN_NEG must not wrap POWER_W)
      G5 squelch hold retains that CHANNEL's gain
      G6 freeze hold
      G7 gain_lut(0) is small and safe
      G8 tau is denominated in SAMPLES (regression for the 160x free-running bug)
      G9 CHANNEL ISOLATION -- the oracle that only exists for the muxed form.
         Channel k's envelope, exponent and gain must be a function of channel
         k's history ALONE. A hot channel next door must not move it. This is
         the whole point of a per-channel state table, and it is exactly what a
         mis-indexed RAM silently destroys.
     G10 SIMULTANEOUS DIVERGENCE -- two channels driven at different powers in
         the same interleaved stream must converge to DIFFERENT gains. G9 alone
         passes if every channel is frozen; G10 alone passes if the state is
         global. Together they pin it.

  ORACLE 2 (bit-exact, in the TB): out_chan/out_i/out_q vs the vectors below.
      Because out = round_sat(in * gain[chan]) and in, chan and gain[chan] all
      vary across the stream, bit-exact out transitively proves the per-channel
      envelope, the leading-one exponent, the dwell, the LUT and the saturation.
      It does NOT prove the last-known-good-gain cache -- state that never
      reaches `out` is invisible to a bit-exact oracle. That is what G5/G6 are
      for, and it is measured: mutating the squelch cache leaves Oracle 2 at
      0 mismatches.

Emit convention (PINNED -- the source of silent mismatches):
  in[n] is multiplied by the gain computed from that same beat's power, and
  emerges on out 3 clocks later with out_valid and out_chan.
  Expected lines exist ONLY for cycles with in_valid=1, in stream order.
  A latency offset here reads as "every sample wrong" -- the halfband trap.

Files: vectors/cnm_input.txt     "chan i q valid"     one line per clock
       vectors/cnm_expected.txt  "chan out_i out_q"   one line per in_valid=1
       vectors/cnm_lut.txt       "gain"               32 lines, Q6.10
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from channel_normalizer_mux_model import (ChannelNormalizerMux, build_lut,
                                          round_sat, saturated, power_sat,
                                          GAIN_FRAC, MAX_POS, MIN_NEG,
                                          POW_MAX, UNITY, leading_one, GAIN_W)

# must match tb_channel_normalizer_mux.vhd exactly
N_CH          = 64
ATTACK_SHIFT  = 4
RELEASE_SHIFT = 6
# squelch_thr sits at exponent 15, so the first TRACKED octave is 16 (see G12).
# PROVISIONAL: the flight value must be derived from the MEASURED per-channel
# channelizer noise floor with no signal, at the OUTPUT_SHIFT you intend to fly.
SQUELCH_THR   = 49_152
# TARGET_AMP = 16384 (2^14) overflows LUT[16] by EXACTLY ONE CODE (65536 vs
# 65535) and so strands a whole octave -- 6 dB of gain range. Picking the power
# of two is the wrong choice here. 16000 is -6.2 dBFS and reaches exponent 16.
TARGET_AMP    = 16000
SAFE_FLOOR_EXP = 16
P_STEADY      = 76_660_593      # MEASURED: mean I^2+Q^2, chan0_iq.txt samples 5000+
A_STEADY      = 9403            # MEASURED: peak |Q|, same capture

LUT = build_lut(TARGET_AMP, SAFE_FLOOR_EXP)


def _settle(dut, chan, amp, beats):
    """Drive one channel `beats` times, spaced by idle cycles.

    The state RAM write-back lands 2 clocks after the read, so the same channel
    must not appear within 3 clocks. Back-to-back beats on one channel would
    read state one beat stale and the envelope would converge measurably slower
    (~30% at attack_shift=4). The channelizer emits each channel once per
    64-beat frame, so real streams are never back-to-back. The model must be
    driven the same way or it mints vectors for a stream that cannot occur.
    """
    for _ in range(beats):
        dut.step(1, chan, amp, 0)
        dut.step(0, 0, 0, 0)
        dut.step(0, 0, 0, 0)


# ---------------------------------------------------------------------------
def gate_unity_identity():
    for v in list(range(-2000, 2001, 7)) + [MAX_POS, MIN_NEG, 0, 1, -1]:
        assert round_sat(v * UNITY) == v, "unity gain is not an identity at %d" % v


def gate_round_half_up():
    half = 1 << (GAIN_FRAC - 1)
    assert round_sat(half) == 1
    assert round_sat(-half) == 0, "half-UP, not away-from-zero"
    assert round_sat(half - 1) == 0
    assert round_sat(3 * half) == 2


def gate_saturation_clamps():
    big = 60 * UNITY
    assert round_sat(30000 * big) == MAX_POS
    assert round_sat(-30000 * big) == MIN_NEG
    assert saturated(30000 * big) and saturated(-30000 * big)
    assert not saturated(100 * UNITY)
    prev = None
    for v in range(1000, 30000, 137):
        r = round_sat(v * big)
        assert prev is None or r >= prev, "saturation folded back at %d" % v
        prev = r


def gate_power_saturates():
    """I = Q = MIN_NEG gives 2^31 exactly, one code past POWER_W. Must clamp."""
    assert power_sat(MIN_NEG, MIN_NEG) == POW_MAX, "power estimate wrapped"
    assert power_sat(MAX_POS, MAX_POS) < POW_MAX
    assert power_sat(0, 0) == 0


def gate_squelch_hold_per_channel():
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=SQUELCH_THR)
    _settle(dut, 7, A_STEADY, 3000)
    g, e = dut.gain[7], dut.env[7]
    assert dut.hold[7] == 0
    _settle(dut, 7, 0, 500)                       # station on channel 7 goes away
    assert dut.hold[7] == 1, "squelch must assert hold on that channel"
    assert dut.gain[7] == g, "gain must be RETAINED under squelch (%d vs %d)" % (dut.gain[7], g)
    assert dut.env[7] == e, "env must be RETAINED under squelch"


def gate_freeze_hold():
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=SQUELCH_THR)
    _settle(dut, 3, A_STEADY, 3000)
    g = dut.gain[3]
    dut.freeze = 1
    _settle(dut, 3, A_STEADY // 8, 2000)          # deep fade while frozen
    assert dut.hold[3] == 1 and dut.gain[3] == g, "freeze must retain gain"


def gate_lut_zero_is_safe():
    # lut(0) is what a channel gets after the squelch hangover CLEARS it, and
    # what it holds during the first samples of attack while env is still ~0.
    # It must never let a dead channel amplify noise to full scale.
    assert LUT[0] <= UNITY, "gain_lut(0) must be a small, safe gain"


def gate_lut_fits_gain_w():
    """No LUT entry may overflow GAIN_W.

    gain = TARGET / sqrt(power) grows without bound as power falls, so the
    reciprocal-sqrt curve WILL overflow Q6.10 if the safe floor is set too low.
    MEASURED: TARGET=16384 with a floor at exponent 16 needs 65536 -- exactly
    one code past the 16-bit ceiling. Silent truncation there would invert the
    gain law for the weakest channels.
    """
    from channel_normalizer_mux_model import GAIN_W
    m = max(LUT)
    assert m < 2**GAIN_W, "LUT entry %d overflows GAIN_W=%d" % (m, GAIN_W)


def gate_safe_floor_matches_squelch():
    """The safe floor and the squelch threshold are ONE constant, not two.

    Entries below the squelch exponent are unreachable: a channel whose power
    sits there is quiet, so it is held or cleared and its gain never applies.
    Setting the floor anywhere else either strands usable LUT entries (floor too
    high -> gain range lost) or promises boost to channels that are squelched
    off (floor too low -> dead code). They must be derived from each other.
    """
    sq_exp = leading_one(SQUELCH_THR)
    first_tracked = sq_exp + 1          # first octave strictly above the floor
    assert SAFE_FLOOR_EXP == first_tracked, \
        "safe_floor_exp=%d but squelch_thr=%d sits at exponent %d (first tracked octave %d)" \
        % (SAFE_FLOOR_EXP, SQUELCH_THR, sq_exp, first_tracked)


def gate_gain_range_covers_the_system_spread():
    """The normalizer is the ONLY gain control in the Haifuraiya chain.

    Haifuraiya (ZCU102 + ADRV9002) uses NO RF AGC, and must not: 64 stations
    share one ADC, so an RF AGC would see only the composite and one loud
    station keying up would desense the other 63. RF gain can only set total
    ADC headroom. Per-station gain control is possible only AFTER the
    channelizer, per channel. Nothing upstream helps this block.

    REQUIREMENT: the full near-far spread. WP1 sec 5.3 -> 40 dB.

    WITNESS (kb5mu bench, 2026-07-06): a PlutoSDR + AD9361 fast-attack AGC
    railed at gain index 73 and the last 34 dB of the sweep ran OPEN LOOP.
    That is a DIFFERENT receiver architecture, so 34 dB is not the requirement
    -- it is a measured lower bound proving at least 34 dB of swing occurs on a
    real link. Haifuraiya, with no RF AGC at all, sees the whole spread.

    Cross-check on the same bench: the 3-bit soft quantizer's MEASURED hardware
    thresholds (92/276/460) discriminate over only 20*log10(460/92) = 14.0 dB.
    Fixed thresholds cannot span 40 dB no matter where they are placed. This
    block is what makes a 3-bit soft path possible at all.
    """
    import math
    lo, hi = SAFE_FLOOR_EXP, 30
    rng = 20*math.log10(LUT[lo]) - 20*math.log10(LUT[hi])
    assert rng >= 40.0, \
        "LUT spans only %.1f dB; the system near-far spread is 40 dB (WP1 sec 5.3)" % rng
    return rng


def gate_tau_in_samples():
    """Regression for the 160x bug. tau is counted in BEATS of this channel."""
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=0)
    # target must be 90% of the power ACTUALLY DRIVEN, not of P_STEADY.
    # P_STEADY is the MEAN of I^2+Q^2 over a modulated signal; driving
    # I=A_STEADY, Q=0 presents A_STEADY^2, which is larger. Comparing against
    # the wrong number makes the envelope look ~35% faster than 2.3*tau.
    p_drive = power_sat(A_STEADY, 0)
    target = int(0.9 * p_drive)
    beats = 0
    while dut.env[0] < target:
        dut.step(1, 0, A_STEADY, 0)      # one beat of channel 0 ...
        dut.step(0, 0, 0, 0)             # ... spaced by idle clocks, so the
        dut.step(0, 0, 0, 0)             # write-back lands before the next read
        beats += 1
        assert beats < 100000, "envelope never reached 90%"
    expect = 2.3 * (1 << ATTACK_SHIFT)
    assert 0.8 * expect <= beats <= 1.3 * expect, \
        "90%% took %d beats, expected ~%.0f" % (beats, expect)
    return beats


def gate_channel_isolation():
    """Channel k's state is a function of channel k's history alone.

    Drive channel 5 hot, every other channel silent, all interleaved in one
    stream. Channel 5 must adapt; nothing else may move. A RAM indexed by a
    constant, or by the wrong pipeline stage's chan, dies here.
    """
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=0)
    for _ in range(200):
        for c in range(N_CH):
            amp = A_STEADY if c == 5 else 0
            dut.step(1, c, amp, 0)
    assert dut.env[5] > 0, "hot channel never adapted"
    for c in range(N_CH):
        if c != 5:
            assert dut.env[c] == 0, "CROSSTALK: channel %d env moved (%d)" % (c, dut.env[c])
            assert dut.gain[c] == LUT[0], \
                "CROSSTALK: channel %d gain moved (%d)" % (c, dut.gain[c])


def gate_simultaneous_divergence():
    """Two channels at different powers, same stream, must reach different gains.

    Isolation alone would pass on a block that never adapts anything. This pins
    the other side: the table really does hold N independent trackers.
    """
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=0)
    hi, lo = A_STEADY, A_STEADY // 8            # 18 dB apart -> >= 3 octaves
    for _ in range(400):
        dut.step(1, 11, hi, 0)
        dut.step(1, 12, lo, 0)
    assert dut.env[11] > dut.env[12], "envelopes did not separate"
    assert dut.gain[11] != dut.gain[12], \
        "SHARED STATE: both channels landed on gain %d" % dut.gain[11]
    assert dut.expr[11] > dut.expr[12], "exponents did not separate"


def run_analytic_oracle():
    gate_unity_identity()
    gate_round_half_up()
    gate_saturation_clamps()
    gate_power_saturates()
    gate_squelch_hold_per_channel()
    gate_freeze_hold()
    gate_lut_zero_is_safe()
    gate_lut_fits_gain_w()
    gate_safe_floor_matches_squelch()
    rng = gate_gain_range_covers_the_system_spread()
    b = gate_tau_in_samples()
    gate_channel_isolation()
    gate_simultaneous_divergence()
    print("ANALYTIC ORACLE PASS")
    print("  G1..G4  unity identity, round-half-up, saturation clamp, power clamp")
    print("  G5..G7  squelch hold (per channel), freeze hold, safe lut(0)")
    print("  G8      tau in SAMPLES: 90%% at %d beats (attack_shift=%d, expect ~%.0f)"
          % (b, ATTACK_SHIFT, 2.3 * (1 << ATTACK_SHIFT)))
    print("  G9      channel isolation: 63 quiet channels unmoved by a hot neighbour")
    print("  G10     simultaneous divergence: two channels, two gains, one stream")
    print("  G11     no LUT entry overflows GAIN_W (max %d)" % max(LUT))
    print("  G12     safe_floor_exp == first octave above squelch_thr")
    print("  G13     LUT gain range = %.1f dB  (>= 40 dB system near-far spread)" % rng)
    print("          witness: kb5mu 2026-07-06, Pluto/AD9361 AGC railed, 34 dB open loop")
    print("          witness: 3-bit soft thresholds 92/276/460 discriminate over 14.0 dB")


# ---------------------------------------------------------------------------
def xorshift32(seed):
    x = seed
    while True:
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        yield x


def build_stimulus():
    """Frame-structured: 64 beats per frame, TDEST 0..63, as the channelizer emits.

    Channel amplitude plan, chosen so several channels sit in DIFFERENT power
    octaves at once and at least one saturates against its LUT gain:
        ch 5      : full-scale-ish  (exercises gain_sat)
        ch 10     : the measured operating point, 9403
        ch 20     : 18 dB down
        ch 30     : below squelch (hold path)
        ch 40     : bursts on and off (squelch hold -> return at same level)
        ch 50     : settles WEAK (gain ~16x), then a loud station keys up on it.
                    This is the only way the clamp is ever exercised: a settled
                    channel cannot saturate, because gain = TARGET/sqrt(power)
                    lands the output at TARGET by construction. Saturation is a
                    TRANSIENT phenomenon -- the old gain applied to a new, much
                    louder sample, before the envelope catches up.
        others    : silent
    """
    rng = xorshift32(0x1BADD00D)
    rows = []

    def amp_for(chan, frame):
        if chan == 5:
            return 32000
        if chan == 10:
            return A_STEADY
        if chan == 20:
            return A_STEADY // 8
        if chan == 30:
            return 12                     # far below squelch_thr
        if chan == 40:
            # on for 120 frames, off for 60, back on at the SAME level
            if frame < 120:
                return A_STEADY // 2
            if frame < 180:
                return 0
            return A_STEADY // 2
        if chan == 50:
            # weak for a long time (envelope settles, gain climbs), then a loud
            # station keys up. The first beats clip against the stale gain.
            return 1100 if frame < 200 else 32000
        return 0

    N_FRAMES = 260
    for f in range(N_FRAMES):
        for c in range(N_CH):
            a = amp_for(c, f)
            if a == 0:
                i = q = 0
            else:
                r = next(rng)
                i = ((r & 0xFFFF) - 32768) * a // 32768
                q = (((r >> 16) & 0xFFFF) - 32768) * a // 32768
            rows.append((c, i, q, 1))
        # an AXIS bubble between frames: nothing may move
        if f % 40 == 39:
            for _ in range(3):
                rows.append((0, 0, 0, 0))
    return rows


def emit(rows, outdir):
    dut = ChannelNormalizerMux(LUT, N_CH, gain_mode=1, attack_shift=ATTACK_SHIFT,
                               release_shift=RELEASE_SHIFT, squelch_thr=SQUELCH_THR)
    expected = []
    n_sat = 0
    for (c, i, q, v) in rows:
        r = dut.step(v, c, i, q)
        if r["out_valid"]:
            expected.append((r["out_chan"], r["out_i"], r["out_q"]))
            n_sat += r["sat"]
    for _ in range(6):                     # drain the 3-deep pipeline
        r = dut.step(0, 0, 0, 0)
        if r["out_valid"]:
            expected.append((r["out_chan"], r["out_i"], r["out_q"]))
            n_sat += r["sat"]

    n_v = sum(rw[3] for rw in rows)
    assert len(expected) == n_v, \
        "emit convention broken: %d expected vs %d in_valid beats" % (len(expected), n_v)

    # the stream must actually exercise what we claim
    assert n_sat > 0, "no saturation events; the clamp would go untested"
    octaves = set(dut.expr[c] for c in (5, 10, 20))
    assert len(octaves) >= 2, "channels never occupied different power octaves: %s" % octaves
    assert dut.hold[30] == 1, "the below-squelch channel never entered hold"
    assert dut.hold[40] == 0, "the burst channel should be tracking again at the end"

    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "cnm_input.txt"), "w") as f:
        for (c, i, q, v) in rows:
            f.write("%d %d %d %d\n" % (c, i, q, v))
    with open(os.path.join(outdir, "cnm_expected.txt"), "w") as f:
        for (c, i, q) in expected:
            f.write("%d %d %d\n" % (c, i, q))
    with open(os.path.join(outdir, "cnm_lut.txt"), "w") as f:
        for g in LUT:
            f.write("%d\n" % g)

    print("wrote %d input lines, %d expected lines, 32 lut entries -> %s"
          % (len(rows), len(expected), outdir))
    print("  saturation events: %d" % n_sat)
    print("  final gains: ch5=%d ch10=%d ch20=%d ch30=%d(held) ch40=%d"
          % (dut.gain[5], dut.gain[10], dut.gain[20], dut.gain[30], dut.gain[40]))
    print("  final exponents: ch5=%d ch10=%d ch20=%d"
          % (dut.expr[5], dut.expr[10], dut.expr[20]))


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        run_analytic_oracle()
    except AssertionError as e:
        print("ANALYTIC ORACLE FAIL: %s" % e, file=sys.stderr)
        print("NO VECTORS WRITTEN.", file=sys.stderr)
        sys.exit(1)
    emit(build_stimulus(), os.path.join(here, "vectors"))
    print("OK")
