#!/usr/bin/env python3
"""check_system_soft.py -- Route B verdict for the FULL SYSTEM bench.
Reads the demod's raw softs captured by tb_haifuraiya_channelizer_axi
(soft_raw.txt; accepts 1 or 2 columns per line), runs the proven model
frame path (both polarities), and prints frame count, decode metrics,
and the decoded payload text. PASS = frames present, metrics near zero,
and the payload reads as the opv_stim message.

usage: python3 check_system_soft.py [soft_raw.txt]
(run from a directory where ../opv_demod_model.py or opv_demod_model.py
is importable -- same convention as the other checkers)"""
import sys, os
import numpy as np
for p in ("..", "."):
    if os.path.exists(os.path.join(p, "opv_demod_model.py")):
        sys.path.insert(0, p); break
from opv_demod_model import extract_frames

path = sys.argv[1] if len(sys.argv) > 1 else "soft_raw.txt"
soft = []
for line in open(path):
    parts = line.split()
    if not parts: continue
    soft.append(int(parts[-1]))          # last column = the soft value
soft = np.array(soft, float)
print(f"system soft stream: {len(soft)} decisions from {path}")

best = (None, -1)
for pol in (1.0, -1.0):
    fr = extract_frames(pol*soft)
    g = sum(1 for _, mt, by in fr if by is not None)
    if g > best[1]:
        best = (fr, g)
frames = best[0] or []
good = [(mt, by) for _, mt, by in frames if by is not None]
print(f"frames recovered: {len(good)}")
print(f"decode metrics:   {[mt for _, mt, _ in frames]}")
for i, (mt, by) in enumerate(good[:4]):
    txt = bytes(by).decode("ascii", "replace")
    txt = "".join(ch if 32 <= ord(ch) < 127 else "." for ch in txt)
    print(f"  frame {i} (metric {mt}): {txt[:64]}")
if good and all(mt == 0 for mt, _ in good):
    print("SYSTEM ROUTE-B VERDICT: frames clean. GO.")
elif good:
    print("SYSTEM ROUTE-B VERDICT: frames recovered with nonzero metrics"
          " -- fine WITH noise stimulus; investigate if stimulus was clean.")
else:
    print("NO FRAMES -- check soft polarity/scale, fsync seam, or"
          " capture window (did the sim run long enough for lock?)")
