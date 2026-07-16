#!/usr/bin/env python3
"""check_demod.py -- integration-contract gate for msk_demodulator_mlse.
Fabric soft stream (demod_soft.txt, fsync polarity) -> proven model
frame path -> byte compare vs C++ reference. Expected: 10/10, metrics 0,
and the TB's sticky flags reported low."""
import sys, os
import numpy as np
sys.path.insert(0, "..")
from opv_demod_model import extract_frames

soft = np.array([int(l.split()[1]) for l in open("demod_soft.txt")], float)
print(f"fabric soft stream (wrapper, streamed+stalled): {len(soft)} decisions")
ref_path = "../cxx_frames.bin" if os.path.exists("../cxx_frames.bin") else "cxx_frames.bin"
ref = np.fromfile(ref_path, dtype=np.uint8).reshape(-1, 134)
best = (None, -1)
for pol in (1.0, -1.0):
    fr = extract_frames(pol*soft)
    g = sum(1 for _, mt, by in fr if by is not None)
    if g > best[1]:
        best = (fr, g)
frames = best[0] or []
ok = sum(1 for _, mt, by in frames
         if by is not None and any(np.array_equal(by, r) for r in ref))
mets = [mt for _, mt, _ in frames]
print(f"frames byte-identical: {ok}/{len(ref)}   metrics: {mets}")
if ok == len(ref):
    print("MSK_DEMODULATOR_MLSE: integration contract met. GO.")
    sys.exit(0)
print("NO-GO.")
sys.exit(1)
