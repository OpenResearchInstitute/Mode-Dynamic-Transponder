#!/usr/bin/env python3
"""diag_soft.py -- pinpoint where a bad decode comes from, using known truth.

Runs the float model front end on a channel IQ capture, re-encodes the
KNOWN-GOOD payloads (from the C++ reference's raw output, cxx_frames.bin) to
get the expected on-air coded bits, and compares the resolved soft stream
sign-by-sign at every frame position. Reports:
  - per-frame sign-disagreement count and rate
  - the disagreement positions' periodicity (histogram mod 2/4/8/16/32/67)
  - soft-magnitude statistics at agreeing vs disagreeing positions
  - environment versions (python, numpy)
A ~12.5% uniform disagreement with a clean mod-8 signature means a
byte/bit-order class bug; random scatter means a signal/loop issue; zero
disagreement with a bad decode means the fault is in the decoder tail.

Usage: python3 diag_soft.py [chan5_iq.cs16] [cxx_frames.bin]
"""
import sys
import numpy as np
from opv_demod_model import (CoherentModel, SYMBOL_RATE, SYNC_BITS,
                             ENCODED_BITS, FRAME_SYMBOLS, frame_decode)
from opv_encode_model import encode_frame

iq_path  = sys.argv[1] if len(sys.argv) > 1 else "chan5_iq.cs16"
ref_path = sys.argv[2] if len(sys.argv) > 2 else "cxx_frames.bin"

print(f"python {sys.version.split()[0]}, numpy {np.__version__}")

d = np.fromfile(iq_path, dtype=np.int16).astype(np.float64)
s = d[0::2] + 1j * d[1::2]
m = CoherentModel(625000.0 / SYMBOL_RATE)
Y1, Y2 = m.track_correlations(s)
dec0, dec1 = m.combine(Y1, Y2)
soft = m.resolve(dec0, dec1)
print(f"symbols: {len(soft)}")

refs = np.fromfile(ref_path, dtype=np.uint8)
assert len(refs) % 134 == 0, "cxx_frames.bin must be whole 134-byte frames"
payloads = refs.reshape(-1, 134)
print(f"reference payload frames: {len(payloads)}")

# locate each frame's sync by correlation (positions should be on the
# FRAME_SYMBOLS grid); then compare payload soft signs against re-encoded truth
pat = np.array([1.0 if b == 0 else -1.0 for b in
                [(0x02B8DB >> (SYNC_BITS-1-i)) & 1 for i in range(SYNC_BITS)]])
w = np.lib.stride_tricks.sliding_window_view(soft, SYNC_BITS)
c = (w @ pat) / (np.abs(w).sum(axis=1) + 1e-9)

hits = np.nonzero(c[:3 * FRAME_SYMBOLS] > 0.9)[0]
assert len(hits), "no sync found in the first 3 frame periods"
k = int(hits[0])
print(f"first sync at symbol {k} (corr {c[k]:+.3f})")

all_bad_pos = []
mags_ok, mags_bad = [], []
for f, payload in enumerate(payloads):
    kk = k + f * FRAME_SYMBOLS
    if kk + SYNC_BITS + ENCODED_BITS > len(soft):
        break
    # allow +/-2 symbol drift per frame
    lo, hi = max(kk - 2, 0), min(kk + 3, len(c))
    kk = lo + int(np.argmax(c[lo:hi]))
    seg = soft[kk + SYNC_BITS: kk + SYNC_BITS + ENCODED_BITS]
    onair = encode_frame(payload)[SYNC_BITS:]
    # convention: bit 1 -> negative soft
    rx_bits = (seg < 0).astype(np.uint8)
    bad = np.nonzero(rx_bits != onair)[0]
    metric, by = frame_decode(seg)
    ok = np.array_equal(by, payload) if by is not None else False
    print(f"frame {f+1:2d} @sym {kk:6d} corr {c[kk]:+.3f}: "
          f"{len(bad):4d}/{ENCODED_BITS} sign disagreements "
          f"({100.0*len(bad)/ENCODED_BITS:5.2f}%)  "
          f"decode metric {metric:5d} bytes_ok={ok}")
    all_bad_pos.append(bad)
    mags_ok.append(np.abs(seg[rx_bits == onair]))
    mags_bad.append(np.abs(seg[bad]))

bad = np.concatenate(all_bad_pos) if all_bad_pos else np.array([], dtype=int)
if len(bad):
    print("\ndisagreement periodicity (fraction of errors in each residue):")
    for mod in (2, 4, 8, 16, 32, 67):
        h = np.bincount(bad % mod, minlength=mod) / len(bad)
        peak = int(np.argmax(h))
        flat = 1.0 / mod
        print(f"  mod {mod:3d}: peak residue {peak:3d} holds {100*h[peak]:5.1f}% "
              f"(uniform would be {100*flat:4.1f}%)")
    mo = np.concatenate(mags_ok); mb = np.concatenate(mags_bad)
    print(f"\n|soft| at agreeing positions   : mean {mo.mean():9.1f}")
    print(f"|soft| at disagreeing positions: mean {mb.mean():9.1f}"
          f"  ({'weak/boundary symbols' if mb.mean() < 0.3*mo.mean() else 'FULL-STRENGTH wrong symbols - systematic'})")
else:
    print("\nno sign disagreements: front end and truth agree; if decode still"
          "\nfails, the fault is in the decoder tail on this platform.")
