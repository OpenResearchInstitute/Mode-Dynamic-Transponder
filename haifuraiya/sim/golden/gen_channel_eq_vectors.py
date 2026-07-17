#!/usr/bin/env python3
"""
gen_channel_eq_vectors.py -- golden-vector generator for tb_channel_eq.

ANALYTIC oracle (on the model, which is bit-exact to docs/channel_eq.py):
  - PROVENANCE: the RTL gain package == docs/channel_eq.py CH_EQ_GAIN (parsed,
    numpy-free). Drift here means the shipped ROM disagrees with the named model.
  - UNITY identity  : every unity channel (gain == 65536) passes samples through
    unchanged: apply_eq(x, ch) == x.
  - EDGE boost      : ch31/33 (gain 89074 = 1.359x) boost mid samples by that
    ratio (within rounding).
  - SATURATION      : full-scale samples on a boosted channel clamp to +/-32767,
    they do not wrap.
Abort (emit nothing) if the model fails any of these.

BIT-EXACT feed: eq_input.txt "chan i q" ; eq_expected.txt "chan out_i out_q".
channel_eq is a stateless 3-stage pipeline (gain by in_chan), in-order out; the
TB drives one triple per clock and checks outputs in order, cross-checking
out_chan against the gain that was applied.
"""
import sys, os, re, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
os.makedirs(_VEC, exist_ok=True)

import channel_eq_model as m

UNITY = 1 << m.EQ_SHIFT          # 65536
LIM   = (1 << 15) - 1            # 32767

# ---- PROVENANCE: parse docs/channel_eq.py CH_EQ_GAIN (numpy-free) and compare
def channel_eq_py_gains():
    for cand in ("channel_eq.py",
                 "../../../docs/channel_eq.py",
                 "../../docs/channel_eq.py"):
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), cand)
        if os.path.exists(p):
            txt = open(p).read()
            body = re.search(r'CH_EQ_GAIN\s*=\s*np\.array\(\[(.*?)\]', txt, re.S)
            if body:
                nums = [int(n) for n in re.findall(r'-?\d+', body.group(1))]
                if len(nums) >= 64:
                    return nums[:64]
    return None

def analytic_checks():
    fails = []
    py = channel_eq_py_gains()
    if py is None:
        print("  provenance: docs/channel_eq.py not found next to golden/, "
              "skipping py-vs-pkg diff (pkg is the shipped source)")
    else:
        drift = [(k, py[k], m.CH_EQ_GAIN[k]) for k in range(64)
                 if py[k] != m.CH_EQ_GAIN[k]]
        if drift:
            print("  *** PROVENANCE DEFECT: channel_eq.py vs shipped pkg ***")
            for k, a, b in drift:
                print(f"      ch{k}: channel_eq.py {a} vs pkg {b}")
            fails.append("gain-table provenance")
        else:
            print("  provenance: channel_eq.py CH_EQ_GAIN == shipped pkg (OK)")

    unity_ch = [k for k in range(64) if m.CH_EQ_GAIN[k] == UNITY]
    ident_ok = all(m.apply_eq(x, ch) == x
                   for ch in unity_ch for x in (-32768, -1, 0, 1, 12345, 32767))
    print(f"  unity identity: {len(unity_ch)} channels, pass-through {ident_ok}")
    if not ident_ok: fails.append("unity identity")

    for ch in (31, 33):
        got = m.apply_eq(10000, ch)
        want = round(10000 * m.CH_EQ_GAIN[ch] / UNITY)
        print(f"  edge boost ch{ch}: apply_eq(10000)={got} (want ~{want}, "
              f"gain {m.CH_EQ_GAIN[ch]/UNITY:.4f}x)")
        if abs(got - want) > 1: fails.append(f"edge boost ch{ch}")

    sat_hi = m.apply_eq(32767, 31); sat_lo = m.apply_eq(-32768, 31)
    print(f"  saturation ch31: apply_eq(+32767)={sat_hi}, apply_eq(-32768)={sat_lo}")
    if sat_hi != LIM or sat_lo != -LIM - 1: fails.append("saturation clamp")
    return fails

print("[gen_channel_eq_vectors] analytic checks on golden model:")
fails = analytic_checks()
if fails:
    print("  MODEL/PROVENANCE FAILED:", fails); sys.exit(1)
print("  analytic oracle: PASS\n")

# ---- BIT-EXACT vectors ----
random.seed(0xEA)
# per-channel sample set: edges + rounding + saturation-provoking + random
def samples_for(ch):
    base = [0, 1, -1, 2, -2, 100, -100, 32767, -32768, 16384, -16384,
            12345, -12345, 24000, -24000, 25000, -25000, 30000, -30000]
    base += [random.randint(-32768, 32767) for _ in range(6)]
    return base

with open(os.path.join(_VEC, "eq_input.txt"), "w") as fi, \
     open(os.path.join(_VEC, "eq_expected.txt"), "w") as fe:
    n = 0
    for ch in range(64):
        si = samples_for(ch); sq = samples_for(ch)
        random.shuffle(sq)
        for i, q in zip(si, sq):
            fi.write(f"{ch} {i} {q}\n")
            fe.write(f"{ch} {m.apply_eq(i, ch)} {m.apply_eq(q, ch)}\n")
            n += 1

print(f"[gen_channel_eq_vectors] wrote {n} samples across 64 channels "
      f"(edges, rounding, saturation, random)")
