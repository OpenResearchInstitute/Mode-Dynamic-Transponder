#!/usr/bin/env python3
"""Diff ring-served data against the stimulus, address by address."""
si, sq = [], []
for line in open("stim_chain.txt"):
    a, b = line.split(); si.append(int(a)-32768); sq.append(int(b)-32768)
bad = ok = 0
first = []
for line in open("ring_trace.txt"):
    n, i, q = (int(x) for x in line.split())
    if i == si[n] and q == sq[n]:
        ok += 1
    else:
        bad += 1
        if len(first) < 10:
            first.append((n, si[n], sq[n], i, q))
print(f"ring service audit: {ok} correct, {bad} wrong")
for n, gi, gq, di, dq in first:
    tag = ""
    # classify: what IS the served value?
    for k in range(max(0,n-3), n+4):
        if di == si[k] and dq == sq[k] and k != n:
            tag = f"  == sample {k} (offset {k-n:+d})"
            break
    if not tag and di == sq[n] and dq == si[n]:
        tag = "  == I/Q swapped"
    print(f"  addr {n}: stim ({gi},{gq})  served ({di},{dq}){tag}")
