#!/usr/bin/env python3
"""Per-step trace compare: step_trace.txt (xsim) vs step_trace_golden.txt.
Columns: t m0 m1 m2 m3 th0 th1 th2 th3."""
g = [tuple(int(x) for x in l.split()) for l in open("step_trace_golden.txt")]
d = [tuple(int(x) for x in l.split()) for l in open("step_trace.txt")]
n = min(len(g), len(d))
names = ["t","m0","m1","m2","m3","th0","th1","th2","th3"]
for i in range(n):
    if g[i] != d[i]:
        bad = [names[j] for j in range(9) if g[i][j] != d[i][j]]
        print(f"FIRST DIVERGENCE at step {i}, fields {bad}:")
        for j in range(max(0,i-1), min(n,i+2)):
            m = " <== " if j == i else "     "
            print(f"  {j}: G {g[j]}")
            print(f"     D {d[j]}{m}")
        raise SystemExit(1)
print(f"first {n} steps IDENTICAL")
