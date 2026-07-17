"""
channel_eq_model.py -- golden model for channel_eq.vhd (per-channel halfband-droop EQ).

Pure-Python equivalent of docs/channel_eq.py apply_eq_fixed(), numpy-free so it
runs anywhere Vivado's python does. Gain table is loaded from the SHIPPED source
(rtl/resampler/channel_gain_pkg.vhd) so the model tracks what synthesizes; a
provenance check (gen_channel_eq_vectors.py) confirms it equals docs/channel_eq.py.

  corrected = sat16( (sample * gain + 2^15) >> 16 ),  gain Q2.16, per TDEST.
"""
import os, re
EQ_SHIFT = 16
NYQUIST_BIN = 32
SAMPLE_BITS = 16
_HERE = os.path.dirname(os.path.abspath(__file__))

def _resolve(env, *cands):
    p = os.environ.get(env)
    if p and os.path.exists(p): return p
    for c in cands:
        c = os.path.join(_HERE, c)
        if os.path.exists(c): return c
    raise FileNotFoundError(f"{env}: none of {cands} under {_HERE}")

def load_gain_pkg(path):
    txt = open(path).read()
    d = dict(re.findall(r'(\d+)\s*=>\s*to_signed\(\s*(-?\d+)\s*,\s*18\)', txt))
    assert len(d) >= 64, f"parsed {len(d)} gains from {path}"
    return [int(d[str(k)]) for k in range(64)]

PKG_PATH = _resolve("CEQ_PKG", "channel_gain_pkg.vhd",
                    "../../rtl/resampler/channel_gain_pkg.vhd")
CH_EQ_GAIN = load_gain_pkg(PKG_PATH)
_LIM = (1 << (SAMPLE_BITS - 1)) - 1     # +32767

def apply_eq(x, ch):
    g = CH_EQ_GAIN[ch]
    y = (x * g + (1 << (EQ_SHIFT - 1))) >> EQ_SHIFT    # round-half-up, arith shift
    return max(-_LIM - 1, min(_LIM, y))                 # saturate to int16
