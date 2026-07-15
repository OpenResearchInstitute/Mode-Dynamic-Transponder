#!/usr/bin/env python3
"""check_engine.py -- integer-for-integer compare of engine_dump.txt
(from xsim) against golden_engine.txt (from the python model).
Golden columns: k pos wlen y1r y1i y2r y2i
Dump columns:   k pos y1r y1i y2r y2i
Position words compared exactly; Y values compared exactly."""
import sys
gold = {}
for line in open("golden_engine.txt"):
    v = [int(x) for x in line.split()]
    gold[v[0]] = (v[1], v[3], v[4], v[5], v[6])
n = ok = 0
first_bad = None
for line in open("engine_dump.txt"):
    v = [int(x) for x in line.split()]
    k = v[0]
    if k not in gold:
        continue
    n += 1
    g = gold[k]
    d = ((v[1] << 24) | v[2], v[3], v[4], v[5], v[6])
    if g == d:
        ok += 1
    elif first_bad is None:
        first_bad = (k, g, d)
print(f"compared {n} symbols: {ok} exact")
# verbose head for diagnosis
print("first rows side by side (golden | dump):")
dump = {}
for line in open("engine_dump.txt"):
    v = [int(x) for x in line.split()]
    dump[v[0]] = v[1:]
for k in sorted(gold)[:4]:
    g = gold[k]
    d = dump.get(k)
    if d: d = [(d[0] << 24) | d[1]] + list(d[2:])
    print(f"  k={k}: G pos={g[0]} Y1=({g[1]},{g[2]}) Y2=({g[3]},{g[4]})")
    if d:
        print(f"        D pos={d[0]} Y1=({d[1]},{d[2]}) Y2=({d[3]},{d[4]})")
EXPECTED = 5202
if ok == n and n == EXPECTED:
    print(f"BIT-EXACT over all {EXPECTED} symbols. GO.")
    sys.exit(0)
if ok == n and n < EXPECTED:
    print(f"all {n} compared symbols exact, but the run is TRUNCATED "
          f"({n}/{EXPECTED}): the simulation ended early. NO-GO.")
    sys.exit(1)
if first_bad:
    k, g, d = first_bad
    print(f"first mismatch at symbol {k}:")
    print(f"  golden: pos={g[0]} Y1=({g[1]},{g[2]}) Y2=({g[3]},{g[4]})")
    print(f"  dump  : pos={d[0]} Y1=({d[1]},{d[2]}) Y2=({d[3]},{d[4]})")
sys.exit(1)
