#!/usr/bin/env python3
"""
gen_polyphase_vectors.py -- golden-vector generator for tb_polyphase_filterbank.

Single source of truth for the polyphase filterbank proof. Pattern as before:
  1. ANALYTIC oracle (this file, against polyphase_model, itself proven bit-exact
     to the RTL by dump-compare):
       - CHANNEL-0 LOWPASS = COMMUTATOR DIRECTION (the reversal-adjacent check).
         Channel 0 is the sum of all N branch outputs (DFT bin 0). With the
         correct BACKWARD commutator it is a flat lowpass with strong adjacent
         rejection; the forward-commutator bug drooped ~11 dB in band and leaked
         adjacents at ~-4 dB. We drive tones through the model and assert:
         flat in ch0, deep rejection by ch1/ch2. A wrong commutator fails here.
       - DC gain: sum of prototype coeffs (Q1.14) is ~unity; constant in ->
         bin0 = c * sum(coeffs).
     If the MODEL fails, abort and emit nothing.
  2. BIT-EXACT feed: emit poly_input.txt / poly_expected.txt / poly_dcbin.txt on
     the RTL FRAME CONTRACT so tb_polyphase_filterbank proves RTL == model.

FRAME CONTRACT (measured, dump-compare vs RTL, M=16):
  Frame f (f=0,1,2,...) is emitted every M input samples; its newest sample is
  x[M*(f+1)-1] (i.e. the M-th, 2M-th, ... sample). NO fill/garbage frame -- the
  very first outputs_valid is real. outputs_valid is 4 clocks after that sample.
  branch_outputs packs branch k in bits ((k+1)*W-1 downto k*W), W=40, LSB=branch0.

Files (./vectors next to this script):
  poly_input.txt     one int16 sample per line
  poly_expected.txt  branch outputs, N lines/frame (branch 0..N-1), NF frames
  poly_dcbin.txt     sum of the N branches per frame (channel 0), NF lines
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
os.makedirs(_VEC, exist_ok=True)

import math
import polyphase_model as pm

N, T, M = pm.N, pm.T, 16
COEFF_SUM = sum(pm.COEFFS)                     # shipped (.vhd package) sum

# --- PROVENANCE: the .hex (design intent / notebook export) must equal the
# --- .vhd package (what synthesizes). Drift here means hardware != golden source.
def provenance_check():
    hexc = pm.load_hex_coeffs(pm.HEX_PATH)
    pkgc = pm.COEFFS
    drift = [(i, hexc[i], pkgc[i]) for i in range(min(len(hexc), len(pkgc)))
             if hexc[i] != pkgc[i]]
    if drift:
        print("  *** PROVENANCE DEFECT: .hex and .vhd package disagree ***")
        for i, h, p in drift:
            print(f"      index {i} (branch {i//T}, tap {i%T}): "
                  f".hex {h}  vs  .vhd(ships) {p}")
        print("      -> regenerate BOTH from polyphase_channelizer.ipynb to reconcile.")
        print("      -> model/vectors below track the .vhd (shipped) values.")
    else:
        print("  provenance: .hex == .vhd package (OK)")
    return drift

print("[gen_polyphase_vectors] coefficient provenance:")
_drift = provenance_check()
print()

def bin0_rms(fnorm, ncyc=4000):
    x = [int(round(8000 * math.cos(2 * math.pi * fnorm * n))) for n in range(ncyc)]
    b0, f = [], 0
    while M * (f + 1) - 1 < len(x):
        b0.append(sum(pm.branch_vector(x, M * (f + 1) - 1))); f += 1
    b0 = b0[10:]                                  # drop startup transient
    if not b0:
        return 0.0
    return math.sqrt(sum(v * v for v in b0) / len(b0))

# ---------------------------------------------------------------------------
# 1. ANALYTIC oracle on the MODEL (abort on failure)
# ---------------------------------------------------------------------------
def analytic_checks():
    fails = []
    ref = bin0_rms(0.001)                       # deep in channel 0
    def db(fn): return 20 * math.log10(bin0_rms(fn) / ref + 1e-30)
    inband  = db(0.004)                         # still inside ch0
    edge    = db(0.5 / N)                        # ch0/ch1 crossover
    ch1     = db(1.0 / N)                        # adjacent channel center
    ch2     = db(2.0 / N)                        # second channel center
    print("  channel-0 response (commutator-direction / reversal check):")
    print(f"    in-band  (f=0.004)     = {inband:6.1f} dB (want ~0, flat)")
    print(f"    ch0/ch1 edge           = {edge:6.1f} dB")
    print(f"    ch1 center (adjacent)  = {ch1:6.1f} dB (want <= -30, rejection)")
    print(f"    ch2 center             = {ch2:6.1f} dB (want <= -45)")
    if abs(inband) > 1.0: fails.append(f"ch0 not flat in band ({inband:.1f} dB)")
    if ch1 > -30.0:       fails.append(f"weak adjacent rejection ({ch1:.1f} dB) -> commutator?")
    if ch2 > -45.0:       fails.append(f"weak ch2 rejection ({ch2:.1f} dB)")

    csum = COEFF_SUM
    print(f"  prototype coeff sum = {csum} (Q1.14 unity = {1<<14}, DC gain "
          f"{csum/(1<<14):.4f})")
    c = 1000
    xdc = [c] * (N * T + M * 4)                          # >= 1536 taps of history
    dc_bin0 = sum(pm.branch_vector(xdc, len(xdc) - 1))   # fully-settled frame
    if dc_bin0 != c * csum: fails.append(f"DC bin0 {dc_bin0} != c*csum {c*csum}")
    print(f"  DC: bin0(c={c}) = {dc_bin0} (want {c*csum})")
    return fails

print("[gen_polyphase_vectors] analytic checks on golden model:")
fails = analytic_checks()
if fails:
    print("  MODEL FAILED analytic oracle:", fails); sys.exit(1)
print("  model analytic oracle: PASS\n")

# ---------------------------------------------------------------------------
# 2. Bit-exact vector emission (RTL frame contract)
# ---------------------------------------------------------------------------
import random
random.seed(0xB0A)
NF = 40
nsamp = M * NF
xs = [random.randint(-20000, 20000) for _ in range(nsamp)]

with open(os.path.join(_VEC, "poly_input.txt"), "w") as fi:
    for v in xs: fi.write(f"{v}\n")

with open(os.path.join(_VEC, "poly_expected.txt"), "w") as fe, \
     open(os.path.join(_VEC, "poly_dcbin.txt"), "w") as fd:
    for f in range(NF):
        vec = pm.branch_vector(xs, M * (f + 1) - 1)
        for val in vec: fe.write(f"{val}\n")
        fd.write(f"{sum(vec)}\n")

print(f"[gen_polyphase_vectors] wrote {NF} frames, N={N} branches/frame, "
      f"{nsamp} input samples (frame f newest sample = M*(f+1)-1)")
