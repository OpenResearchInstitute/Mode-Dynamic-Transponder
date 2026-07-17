"""
polyphase_model.py -- fixed-point golden model for polyphase_filterbank_parallel.

Built from the RTL recipe, proven bit-exact to the RTL by dump-compare.

  xbuf[0]=newest; branch_k(n) = wrap40( sum_i coeff[k*T+i] * xbuf[k + N*i] )
  coeffs branch-major Q1.14 int16, backward commutator, no shift.
  Frame f newest sample = M*(f+1)-1; no fill frame.

COEFFICIENT SOURCE: the model loads ALL_COEFFS from the compiled-in VHDL package
(haifuraiya_coeffs_pkg.vhd), because THAT is what synthesizes into hardware. The
separate .hex file is design-intent/tooling truth; a provenance check
(gen_polyphase_vectors.py) compares the two and flags drift. They currently
disagree at 2 taps (see COEFF_PROVENANCE_NOTE).
"""
import os, re
N = 64; T = 24; ACCUM_W = 40
_HERE = os.path.dirname(os.path.abspath(__file__))

def _s16(v): return v - 0x10000 if v & 0x8000 else v

def load_pkg_coeffs(path):
    txt = open(path).read()
    vals = [_s16(int(m, 16)) for m in re.findall(r'x"([0-9A-Fa-f]{4})"', txt)]
    assert len(vals) == N * T, f"pkg has {len(vals)} coeffs, want {N*T}"
    return vals

def load_hex_coeffs(path):
    out = []
    for ln in open(path):
        ln = ln.strip()
        if ln: out.append(_s16(int(ln, 16)))
    return out

def _resolve(name, env, *cands):
    p = os.environ.get(env)
    if p and os.path.exists(p): return p
    for c in cands:
        c = os.path.join(_HERE, c)
        if os.path.exists(c): return c
    raise FileNotFoundError(f"{name}: none of {cands} found under {_HERE}")

PKG_PATH = _resolve("coeff pkg", "HB_PKG",
                    "haifuraiya_coeffs_pkg.vhd",
                    "../../rtl/channelizer/haifuraiya_coeffs_pkg.vhd")
HEX_PATH = _resolve("coeff hex", "HB_HEX",
                    "haifuraiya_coeffs.hex",
                    "../../rtl/coeffs/haifuraiya_coeffs.hex")
COEFFS = load_pkg_coeffs(PKG_PATH)          # what SHIPS (synthesized)

def wrap(x, w=ACCUM_W):
    m = (1 << w) - 1; x &= m
    return x - (1 << w) if x & (1 << (w - 1)) else x

def branch_vector(x, n):
    out = []
    for k in range(N):
        acc = 0
        for i in range(T):
            p = k + N * i
            xs = x[n - p] if (n - p) >= 0 else 0
            acc += xs * COEFFS[k * T + i]
        out.append(wrap(acc))
    return out
