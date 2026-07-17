#!/usr/bin/env python3
"""
gen_fft_vectors.py -- golden-vector generator for tb_r2sdf_fft.

Single source of truth for the FFT proof. Two jobs, same pattern as the
halfband generator:
  1. ANALYTIC oracle (this file, against the golden MODEL fft_model.fft_fixed):
       - DC in  -> all energy in bin 0 (bin0 = N*c exactly, off-bins zero).
       - CHANNEL ORDERING (the reversal detector): a +k complex tone peaks at
         bin k, a -k tone peaks at bin (N-k). e.g. +8 -> bin 8, -8 -> bin 56.
       - Parseval: sum|X|^2 ~= N * sum|x|^2 (loose, fixed-point truncation).
     If the MODEL fails any of these it is reversed/broken -> abort, emit nothing.
  2. BIT-EXACT feed: emit fft_input.txt / fft_expected.txt / fft_peaks.txt on the
     RTL FRAME CONTRACT so tb_r2sdf_fft proves RTL == model frame-for-frame.

FRAME CONTRACT (pinned here, measured from r2sdf_fft.vhd):
  - Feed N-sample frames back to back, in_valid high, natural order in.
  - Output: ignore everything until the first out_idx==0 (leading partial),
    then FILL=1 aligned frame is pipeline-fill garbage, then aligned frame
    (FILL+k) == fft_fixed(input frame k), out_idx = natural bin 0..N-1.
  - Two all-zero FLUSH frames are appended to the input so the last real frame
    propagates out while in_valid is still high (the stages advance only on
    in_valid; dropping it stalls the pipeline).

Files (written to ./vectors next to this script):
  fft_input.txt     "re im" per line, (NF + 2 flush) frames, N lines/frame
  fft_expected.txt  "re im" per line, NF frames, natural bin order 0..N-1
  fft_peaks.txt     one int per NF frame: expected peak bin, or -1 to skip
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
os.makedirs(_VEC, exist_ok=True)

from fft_model import fft_fixed, DATA_WIDTH

N   = 64
A   = 1 << 20              # tone amplitude (well inside 40-bit input headroom)
DCC = 1000                # DC level

def tone(cyc):
    """Complex exp at 'cyc' cycles/frame, signed. +cyc = positive frequency."""
    return [(round(A * math.cos(2 * math.pi * cyc * t / N)),
             round(A * math.sin(2 * math.pi * cyc * t / N))) for t in range(N)]

def peak_bin(frame):
    y = fft_fixed(frame)
    mags = [r * r + i * i for (r, i) in y]
    return max(range(N), key=lambda b: mags[b])

# ---------------------------------------------------------------------------
# 1. ANALYTIC oracle on the MODEL (abort on any failure)
# ---------------------------------------------------------------------------
def analytic_checks():
    fails = []

    dc = fft_fixed([(DCC, 0)] * N)
    if dc[0] != (N * DCC, 0): fails.append(f"DC bin0 {dc[0]} != {(N*DCC,0)}")
    if any(dc[b] != (0, 0) for b in range(1, N)): fails.append("DC off-bins nonzero")
    print(f"  DC  -> bin0 = {dc[0]} (want {(N*DCC,0)}), off-bins zero: "
          f"{all(dc[b]==(0,0) for b in range(1,N))}")

    print("  channel ordering (reversal detector):")
    for k in (1, 8, 21, 31):
        pp, pm = peak_bin(tone(+k)), peak_bin(tone(-k))
        ok = (pp == k) and (pm == (N - k) % N)
        print(f"    +{k:2d} -> bin {pp:2d} (want {k:2d}) ; "
              f"-{k:2d} -> bin {pm:2d} (want {(N-k)%N:2d})  {'OK' if ok else 'REVERSED?'}")
        if not ok: fails.append(f"ordering k={k}")

    # Parseval (loose): sum|X|^2 ~= N*sum|x|^2 on a tone frame
    x = tone(8); y = fft_fixed(x)
    ex = sum(r * r + i * i for r, i in x)
    eX = sum(r * r + i * i for r, i in y)
    ratio = eX / (N * ex)
    print(f"  Parseval ratio sum|X|^2 / (N*sum|x|^2) = {ratio:.6f} (want ~1.0)")
    if abs(ratio - 1.0) > 5e-2: fails.append(f"Parseval ratio {ratio:.4f}")
    return fails

print("[gen_fft_vectors] analytic checks on golden model:")
fails = analytic_checks()
if fails:
    print("  MODEL FAILED analytic oracle:", fails); sys.exit(1)
print("  model analytic oracle: PASS\n")

# ---------------------------------------------------------------------------
# 2. Bit-exact vector emission (RTL frame contract)
# ---------------------------------------------------------------------------
import random
random.seed(0xF17)
def rnd():
    return [(random.randint(-A, A), random.randint(-A, A)) for _ in range(N)]

# NF meaningful frames: DC, signed tones (ordering), then random for coverage
frames = [
    ([(DCC, 0)] * N,  0),
    (tone(+8),        8),
    (tone(-8),   (N-8)),
    (tone(+21),      21),
    (tone(-21), (N-21)),
    (tone(+1),        1),
    (tone(-1),   (N-1)),
    (rnd(),          -1),
    (rnd(),          -1),
]
NF = len(frames)
flush = [[(0, 0)] * N, [(0, 0)] * N]        # 2 zero frames to drain the pipeline

with open(os.path.join(_VEC, "fft_input.txt"), "w") as fi:
    for fr, _ in frames:
        for re, im in fr: fi.write(f"{re} {im}\n")
    for fr in flush:
        for re, im in fr: fi.write(f"{re} {im}\n")

with open(os.path.join(_VEC, "fft_expected.txt"), "w") as fe, \
     open(os.path.join(_VEC, "fft_peaks.txt"), "w") as fp:
    for fr, pk in frames:
        for re, im in fft_fixed(fr): fe.write(f"{re} {im}\n")
        fp.write(f"{pk}\n")

print(f"[gen_fft_vectors] wrote {NF} real frames (+2 flush), N={N}, "
      f"peaks encode +k->k / -k->N-k ordering")
