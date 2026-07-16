#!/usr/bin/env python3
"""check_chain.py -- THE PHASE 0 FINAL GATE.
Reads the fabric soft stream (chain_soft.txt, from the chained RTL
engine+mlse4), runs the repo's proven model frame path on it, and
compares decoded frames byte-for-byte against the C++ reference decode.
Expected (pre-flight proven): 10/10 byte-identical, all metrics 0."""
import sys, os
import numpy as np
sys.path.insert(0, "..")
from opv_demod_model import extract_frames

soft_map = {}
for line in open("chain_soft.txt"):
    t, s = (int(x) for x in line.split())
    soft_map[t] = s
n = max(soft_map) + 1
soft = np.zeros(n)
for t, s in soft_map.items():
    soft[t] = s
print(f"fabric soft stream: {len(soft_map)} decisions (span {n})")

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
print(f"frames byte-identical to C++ reference: {ok}/{len(ref)}")
print(f"decode metrics: {mets}")
if ok == len(ref):
    print("PHASE 0 COMPLETE: the RTL receiver decodes the reference")
    print("transmission byte-identically. GO.")
    sys.exit(0)
print("NO-GO.")
sys.exit(1)
