#!/usr/bin/env python3
"""Compare mac_trace.txt (xsim) against mac_trace_golden.txt line by line.
Columns: addr xr xi a1r_before_this_accumulate."""
g = [tuple(int(x) for x in l.split()) for l in open("mac_trace_golden.txt")]
d = [tuple(int(x) for x in l.split()) for l in open("mac_trace.txt")]
n = min(len(g), len(d))
for i in range(n):
    if g[i] != d[i]:
        print(f"FIRST DIVERGENCE at trace line {i}:")
        for j in range(max(0,i-2), min(n,i+3)):
            mark = " <== " if j == i else "     "
            print(f"  line {j}: golden {g[j]}   dump {d[j]}{mark}")
        raise SystemExit(1)
print(f"first {n} MAC cycles IDENTICAL"
      + ("" if len(d)>=len(g) else f" (dump shorter: {len(d)} vs {len(g)})"))
