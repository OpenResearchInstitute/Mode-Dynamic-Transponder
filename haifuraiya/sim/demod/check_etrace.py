#!/usr/bin/env python3
"""Diff the wrapper engine's trajectory against golden_engine.txt.
Golden: k pos wlen y1r y1i y2r y2i   Trace: k poshi poslo y1r y1i y2r y2i"""
gold = {}
for line in open("../engine/golden_engine.txt"):
    v = [int(x) for x in line.split()]
    gold[v[0]] = (v[1], v[3], v[4], v[5], v[6])
n = ok = 0
first = None
for line in open("engine_trace.txt"):
    v = [int(x) for x in line.split()]
    k = v[0]
    if k not in gold:
        continue
    n += 1
    d = ((v[1] << 24) | v[2], v[3], v[4], v[5], v[6])
    if d == gold[k]:
        ok += 1
    elif first is None:
        first = (k, gold[k], d)
print(f"wrapper engine vs golden: {ok}/{n} symbols exact")
if first:
    k, g, d = first
    print(f"FIRST DIVERGENCE at symbol {k}:")
    print(f"  golden : pos={g[0]} Y1=({g[1]},{g[2]}) Y2=({g[3]},{g[4]})")
    print(f"  wrapper: pos={d[0]} Y1=({d[1]},{d[2]}) Y2=({d[3]},{d[4]})")
    print("pos differs  -> the TED/PI trajectory itself diverges (hold bug)")
    print("pos same, Y differs -> the ring served wrong sample data")
else:
    print("engine trajectory IDENTICAL -> the divergence is in the")
    print("wrapper's mlse4 feeding or the shim, not the engine")
