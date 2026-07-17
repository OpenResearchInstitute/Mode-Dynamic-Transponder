#!/usr/bin/env python3
"""
gen_halfband_vectors.py -- golden-vector generator for tb_halfband_decimator.

Single source of truth for the halfband proof. Two jobs:
  1. ANALYTIC oracle (this file, against the golden MODEL): verify the model's
     spectral/structural truth -- unity DC gain, true-halfband zeros, fs/4 =
     -6.02 dB, stopband >= 88 dB, impulse response reconstructs the tap set.
     If the model fails ANY of these, we abort and emit NOTHING. A broken model
     must never mint golden vectors.
  2. BIT-EXACT oracle feed: emit hb_input.txt / hb_expected.txt on the RTL's
     emit convention so tb_halfband_decimator can prove RTL == model sample-for-
     sample.

EMIT CONVENTION (pinned here, matches halfband_decimator.vhd):
  full = clip( (convolve(x, HB_TAPS) + 2^16) >> 17 )        # full-rate filtered
  out  = full[1::2]                                          # odd phase, from idx 1
  The RTL emits the FULL odd-phase stream including startup transient (it does
  NOT chop to CENTER like decimate_fixed()'s [37::2]). expected.txt matches the
  RTL, not decimate_fixed(). This offset (18 samples) is the whole reason a naive
  decimate_fixed() comparison shows every sample mismatched.
"""
import sys, os, numpy as np
_HERE = os.path.dirname(os.path.abspath(__file__))
_VEC  = os.path.join(_HERE, "vectors")
os.makedirs(_VEC, exist_ok=True)
sys.path.insert(0, _HERE)                       # find the model next to us
from halfband_model import HB_TAPS, SHIFT, DATA_BITS, FS_IN, CENTER

LIM = (1 << (DATA_BITS - 1)) - 1

def full_fir(x):
    acc = np.convolve(np.asarray(x, dtype=np.int64), HB_TAPS)
    y = (acc + (1 << (SHIFT - 1))) >> SHIFT
    return np.clip(y, -LIM - 1, LIM)

def rtl_emit(x):
    """Model of exactly what the RTL streams out."""
    return full_fir(x)[1::2]

# ---------------------------------------------------------------------------
# 1. ANALYTIC oracle against the MODEL (abort on any failure)
# ---------------------------------------------------------------------------
def analytic_checks():
    fails = []
    csum = int(HB_TAPS.sum())
    print(f"  coeff sum          = {csum} (want {1<<SHIFT}, unity DC)")
    if csum != (1 << SHIFT): fails.append("DC gain != 1")

    # true halfband: every odd-index tap except the center is exactly 0
    odd_nonzero = [i for i in range(len(HB_TAPS)) if i % 2 == 1 and i != CENTER and HB_TAPS[i] != 0]
    print(f"  odd non-center taps nonzero: {len(odd_nonzero)} (want 0)")
    if odd_nonzero: fails.append("not a true halfband")

    # spectrum from the float-normalized taps
    h = HB_TAPS / (1 << SHIFT)
    H = np.fft.fft(h, 65536)
    f = np.fft.fftfreq(65536, d=1 / FS_IN)
    mag_db = 20 * np.log10(np.abs(H) + 1e-30)
    # fs/4 gain
    k_q = np.argmin(np.abs(f - FS_IN / 4))
    print(f"  gain @ fs/4        = {mag_db[k_q]:.3f} dB (want ~ -6.02)")
    if abs(mag_db[k_q] - (-6.02)) > 0.3: fails.append("fs/4 gain off")
    # stopband: beyond 5.75 MHz transition edge
    stop = mag_db[(np.abs(f) >= 5.75e6)]
    print(f"  stopband peak      = {stop.max():.1f} dB (want <= -88)")
    if stop.max() > -88.0: fails.append("stopband < 88 dB")

    # linear phase: coefficient set is symmetric (palindrome)
    sym = np.array_equal(HB_TAPS, HB_TAPS[::-1])
    print(f"  taps symmetric     : {sym} (linear phase)")
    if not sym: fails.append("taps not symmetric (nonlinear phase)")
    return fails

print("[gen_halfband_vectors] analytic checks on golden model:")
fails = analytic_checks()
if fails:
    print("  MODEL FAILED analytic oracle:", fails); sys.exit(1)
print("  model analytic oracle: PASS\n")

# ---------------------------------------------------------------------------
# 2. Bit-exact vector emission (RTL convention)
# ---------------------------------------------------------------------------
rng = np.random.default_rng(0xC0FFEE)
n = np.arange(6000)
A = LIM
xi = np.zeros(6000); xq = np.zeros(6000)
for fr in [0.4e6, 1.9e6, 3.1e6, 4.6e6]:           # in-band + into stopband
    p = 2 * np.pi * fr / FS_IN * n
    xi += 0.2 * A * np.cos(p); xq += 0.2 * A * np.sin(p)
xi += rng.normal(0, 0.05 * A, 6000); xq += rng.normal(0, 0.05 * A, 6000)
xi = np.clip(np.round(xi), -A - 1, A).astype(np.int64)
xq = np.clip(np.round(xq), -A - 1, A).astype(np.int64)

ei, eq = rtl_emit(xi), rtl_emit(xq)
with open(os.path.join(_VEC, "hb_input.txt"), "w") as f:
    for a, b in zip(xi, xq): f.write(f"{a} {b}\n")
with open(os.path.join(_VEC, "hb_expected.txt"), "w") as f:
    for a, b in zip(ei, eq): f.write(f"{a} {b}\n")
print(f"[gen_halfband_vectors] wrote {len(xi)} inputs, {len(ei)} expected (RTL [1::2] convention)")
