#!/usr/bin/env python3
"""Integer-for-integer compare of mlse_dump.txt against mlse_golden.txt.
Columns (both): t soft best_state th0 th1 th2 th3."""
import sys
gold = {}
for line in open("mlse_golden.txt"):
    v = [int(x) for x in line.split()]
    gold[v[0]] = tuple(v[1:])
n = ok = 0
first_bad = None
dump = {}
for line in open("mlse_dump.txt"):
    v = [int(x) for x in line.split()]
    dump[v[0]] = tuple(v[1:])
    if v[0] not in gold:
        continue
    n += 1
    if gold[v[0]] == tuple(v[1:]):
        ok += 1
    elif first_bad is None:
        first_bad = v[0]
print(f"compared {n} decisions: {ok} exact")
print("first rows (golden | dump):")
for k in sorted(gold)[:3]:
    print(f"  t={k}: G {gold[k]}")
    if k in dump: print(f"        D {dump[k]}")
EXPECTED = 5138
if ok == n == EXPECTED:
    print(f"BIT-EXACT over all {EXPECTED} decisions. GO.")
    sys.exit(0)
if first_bad is not None:
    k = first_bad
    print(f"first mismatch at t={k}:")
    print(f"  golden: {gold[k]}")
    print(f"  dump  : {dump[k]}")
elif n < EXPECTED:
    print(f"TRUNCATED: {n}/{EXPECTED}. NO-GO.")
sys.exit(1)
