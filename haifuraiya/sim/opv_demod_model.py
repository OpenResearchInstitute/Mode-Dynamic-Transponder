#!/usr/bin/env python3
"""opv_demod_model.py -- Phase 0a: FLOAT Python transliteration of the
opv-cxx-demod CoherentMSKDemodulator, channelized mode (track_correlations).

Scope matches the future VHDL demodulator: complex channel IQ in (625 ksps,
~11.5314 sps), resolved soft symbol stream out. The decoder tail
(quantize / deinterleave / WAVA Viterbi / derandomize) is included ONLY to
validate the model end-to-end against the C++ binary's decoded bytes; in
hardware those stages are frame_sync_detector_soft + opv-decode on the A53.

Transliterated function-for-function from src/opv_demod.hpp (untouched
reference). Constants are the reference's defaults:
  FREQ_DEV 13550, SYMBOL_RATE 54200, MF_M floor 12 (adaptive max(12, round(sps))),
  Catmull-Rom cubic interpolation, EL 0.5, alpha_t 0.06, beta_t 0.0025,
  timing clamps +/-0.05 (freq) and +/-2.0 (adj), Hodgart Costas a=0.01 b=2e-4,
  G1 0x67 (171 oct), G2 0x76 (133 oct), WAVA_W 48, CCSDS LFSR seed 0xFF.

Phase 0b (next): quantize this model to fixed point, node by node, with dump
hooks -- the widths chosen there become the VHDL bus widths.
"""
import numpy as np

FREQ_DEV     = 13550.0
SYMBOL_RATE  = 54200.0
SYNC_WORD    = 0x02B8DB
SYNC_BITS    = 24
FRAME_BYTES  = 134
FRAME_BITS   = FRAME_BYTES * 8          # 1072
ENCODED_BITS = FRAME_BITS * 2           # 2144
FRAME_SYMBOLS = SYNC_BITS + ENCODED_BITS  # 2168
SOFT_MAX     = 7
G1_MASK, G2_MASK = 0x67, 0x76
NUM_STATES   = 64
WAVA_W       = 48
WRAP_BITS    = FRAME_BITS + 2 * WAVA_W  # 1168
MF_M_FLOOR   = 12

# ---------------------------------------------------------------- front end --
class CoherentModel:
    def __init__(self, sps_nom, freq_offset=0.0):
        self.sps = float(sps_nom)
        self.foff = float(freq_offset)
        self.el = 0.5
        self.alpha_t = 0.06
        self.beta_t = 0.0025
        self._recompute()

    def _recompute(self):
        fs = self.sps * SYMBOL_RATE
        self.inc1 = 2*np.pi * (-FREQ_DEV + self.foff) / fs
        self.inc2 = 2*np.pi * (+FREQ_DEV + self.foff) / fs
        self.M = max(MF_M_FLOOR, int(round(self.sps)))
        self.step = self.sps / self.M
        j = np.arange(self.M)
        self.wpow1 = np.exp(1j * self.inc1 * self.step * j)
        self.wpow2 = np.exp(1j * self.inc2 * self.step * j)

    @staticmethod
    def _interp_cubic(s, idx):
        """Catmull-Rom on complex array s at fractional positions idx (vector)."""
        idx = np.clip(idx, 1.0, len(s) - 3.0)
        i = idx.astype(np.int64)
        f = idx - i
        a, b, c, d = s[i-1], s[i], s[i+1], s[i+2]
        return b + 0.5*f*(c - a + f*(2.0*a - 5.0*b + 4.0*c - d
                                     + f*(3.0*(b - c) + d - a)))

    def corr_at(self, s, base):
        """Tone correlations over one symbol at absolute fractional pos base."""
        pos = base + np.arange(self.M) * self.step
        v = self._interp_cubic(s, pos)
        s1 = np.sum(v * self.wpow1)
        s2 = np.sum(v * self.wpow2)
        lo1 = np.exp(1j * self.inc1 * base)
        lo2 = np.exp(1j * self.inc2 * base)
        return lo1 * s1, lo2 * s2

    def track_correlations(self, s):
        """PI timing loop, ML-gradient TED on the dominant tone."""
        EL = self.el
        pos, freq = EL + 1.0, 0.0
        Y1o, Y2o = [], []
        n = len(s)
        while pos + self.sps + EL + 2.0 < n:
            Y1, Y2 = self.corr_at(s, pos)
            Y1e, Y2e = self.corr_at(s, pos - EL)
            Y1l, Y2l = self.corr_at(s, pos + EL)
            t1 = abs(Y1)**2 > abs(Y2)**2
            ya = Y1 if t1 else Y2
            dy = (Y1l - Y1e) if t1 else (Y2l - Y2e)
            err = (ya.real*dy.real + ya.imag*dy.imag) / (abs(ya)**2 + 1e-9)
            freq += self.beta_t * err
            freq = min(max(freq, -0.05), 0.05)
            adj = self.alpha_t * err + freq
            adj = min(max(adj, -2.0), 2.0)
            Y1o.append(Y1)
            Y2o.append(Y2)
            pos += self.sps + adj
        return np.array(Y1o), np.array(Y2o)

    @staticmethod
    def combine(Y1, Y2):
        """Decision-switched Costas (Hodgart) + Massey 2T combine + differential
        boxplus. Returns both parity streams dec0, dec1."""
        nsym = len(Y1)
        X = np.zeros(nsym)
        Yv = np.zeros(nsym)
        pll_a, pll_b = 0.01, 2e-4
        theta, freq = 0.0, 0.0
        for k in range(nsym):
            rot = np.cos(theta) - 1j*np.sin(theta)
            y1, y2 = Y1[k]*rot, Y2[k]*rot
            X[k], Yv[k] = y1.imag, y2.imag
            act = y2 if (abs(y2)**2 > abs(y1)**2) else y1
            m = abs(act) + 1e-9
            err = -(act.real * (-1.0 if act.imag < 0 else 1.0)) / m
            freq += pll_b * err
            theta += pll_a * err + freq
        decs = []
        for parity in (0, 1):
            enc = np.zeros(nsym)
            i = np.arange(nsym - 1)
            sgn = np.where(((i + parity) & 1) == 0, 1.0, -1.0)
            enc[:-1] = (X[:-1] + X[1:]) - sgn * (Yv[:-1] + Yv[1:])
            dec = np.zeros(nsym)
            a, b = enc[1:], enc[:-1]
            s = np.where((a < 0) != (b < 0), -1.0, 1.0)
            dec[1:] = s * np.minimum(np.abs(a), np.abs(b))
            decs.append(dec)
        return decs[0], decs[1]

    @staticmethod
    def resolve(dec0, dec1):
        """Parity + polarity resolution, DECODE-VERIFIED.

        The single-best-|sync correlation| rule (as in the C++ reference) is
        degenerate on this signal: the WRONG parity also yields a +1.000
        normalized sync correlation, one symbol offset, so the pick collapses
        to float dust and platform luck (found 2026-07-15: identical code
        chose dec0 on one machine and dec1 on another; the dec1 stream has
        perfect syncs and garbage payload, decode metric ~2000).

        Robust rule: for each parity, take the best sync peak (polarity from
        its sign), tail-decode the first full frame after it, and pick the
        hypothesis with the LOWER Viterbi metric (~30 vs ~2800 separation).
        """
        pat = np.array([1.0 if ((SYNC_WORD >> (SYNC_BITS-1-i)) & 1) == 0 else -1.0
                        for i in range(SYNC_BITS)])
        best = None
        for p, d in enumerate((dec0, dec1)):
            d = np.array(d)
            if len(d) < SYNC_BITS + ENCODED_BITS:
                continue
            w = np.lib.stride_tricks.sliding_window_view(d, SYNC_BITS)
            c = (w @ pat) / (np.abs(w).sum(axis=1) + 1e-9)
            k = int(np.argmax(np.abs(c)))
            pol = 1.0 if c[k] >= 0 else -1.0
            seg = pol * d[k + SYNC_BITS: k + SYNC_BITS + ENCODED_BITS]
            if len(seg) < ENCODED_BITS:
                continue
            metric, _ = frame_decode(seg)
            if metric < 0:
                continue
            if best is None or metric < best[0]:
                best = (metric, p, pol)
        if best is None:                      # no decodable frame: fall back
            return np.array(dec0)
        _, bp, bs = best
        return bs * np.array(dec0 if bp == 0 else dec1)

# ------------------------------------------------------- decoder validation --
def deinterleave_addr(idx):
    pos = (idx % 32) * 67 + (idx // 32)
    return (pos // 8) * 8 + (7 - pos % 8)

DEINT = np.array([deinterleave_addr(i) for i in range(ENCODED_BITS)])

def _parity(x):
    return bin(x).count("1") & 1

_PRED0 = np.zeros(NUM_STATES, dtype=int)
_PRED1 = np.zeros(NUM_STATES, dtype=int)
_PAT0 = np.zeros(NUM_STATES, dtype=int)
_PAT1 = np.zeros(NUM_STATES, dtype=int)
for _s in range(NUM_STATES):
    _p0, _in = _s // 2, _s % 2
    _f0, _f1 = (_in << 6) | _p0, (_in << 6) | (_p0 + 32)
    _PAT0[_s] = (_parity(_f0 & G1_MASK) << 1) | _parity(_f0 & G2_MASK)
    _PAT1[_s] = (_parity(_f1 & G1_MASK) << 1) | _parity(_f1 & G2_MASK)
    _PRED0[_s], _PRED1[_s] = _p0, _p0 + 32

def viterbi_tailbiting(soft_qs):
    """WAVA tail-biting Viterbi, transliterated. soft_qs: 2144 ints 0..7
    (deinterleaved). Returns (metric, bits[1072])."""
    cur = np.zeros(NUM_STATES, dtype=np.int64)
    wdec = np.zeros((WRAP_BITS, NUM_STATES), dtype=np.uint8)
    for t in range(WRAP_BITS):
        src = t - WAVA_W
        if src < 0:
            src += FRAME_BITS
        elif src >= FRAME_BITS:
            src -= FRAME_BITS
        sg1, sg2 = soft_qs[src*2], soft_qs[src*2 + 1]
        bm = np.array([sg1 + sg2, sg1 + (SOFT_MAX - sg2),
                       (SOFT_MAX - sg1) + sg2,
                       (SOFT_MAX - sg1) + (SOFT_MAX - sg2)], dtype=np.int64)
        m0 = cur[_PRED0] + bm[_PAT0]
        m1 = cur[_PRED1] + bm[_PAT1]
        take1 = m1 < m0
        wdec[t] = take1
        cur = np.where(take1, m1, m0)
    best = int(np.argmin(cur))
    full = np.zeros(WRAP_BITS, dtype=np.uint8)
    s = best
    for t in range(WRAP_BITS - 1, -1, -1):
        full[t] = s % 2
        s = (s // 2) if wdec[t][s] == 0 else (s // 2 + 32)
    return int(cur[best]), full[WAVA_W:WAVA_W + FRAME_BITS]

def frame_decode(soft2144):
    """FrameDecoder.decode: scale, quantize, deinterleave, viterbi, pack,
    derandomize. Returns (metric, bytes[134])."""
    scale = np.mean(np.abs(soft2144))
    if scale < 1e-10:
        return -1, None
    n = (-soft2144 / scale) * 3.5 + 3.5
    qs = np.clip((n + 0.5).astype(np.int64), 0, SOFT_MAX)
    deint = qs[DEINT]
    metric, bits = viterbi_tailbiting(deint)
    packed = np.zeros(FRAME_BYTES, dtype=np.uint8)
    for i in range(FRAME_BYTES):
        b = 0
        for j in range(8):
            b |= int(bits[FRAME_BITS - 1 - i*8 - j]) << j
        packed[i] = b
    lfsr = 0xFF
    out = np.zeros(FRAME_BYTES, dtype=np.uint8)
    for i in range(FRAME_BYTES):
        r = 0
        for b in range(7, -1, -1):
            r |= ((lfsr >> 7) & 1) << b
            lfsr = ((lfsr << 1) & 0xFF) | (((lfsr >> 7) ^ (lfsr >> 6)
                     ^ (lfsr >> 4) ^ (lfsr >> 2)) & 1)
        out[i] = packed[i] ^ r
    return metric, out

def extract_frames(soft):
    """Batch sync scan on the resolved soft stream. Hunt strictly (0.85),
    hold loosely (0.70) at the expected position once locked -- the same
    two-threshold doctrine as frame_sync_detector_soft and SyncTracker."""
    pat = np.array([1.0 if ((SYNC_WORD >> (SYNC_BITS-1-i)) & 1) == 0 else -1.0
                    for i in range(SYNC_BITS)])
    w = np.lib.stride_tricks.sliding_window_view(soft, SYNC_BITS)
    c = (w @ pat) / (np.abs(w).sum(axis=1) + 1e-9)
    frames = []
    pos, locked = 0, False
    while pos + SYNC_BITS + ENCODED_BITS <= len(soft):
        if not locked:
            hi = min(pos + 2 * FRAME_SYMBOLS, len(c))
            if hi <= pos:
                break
            k = pos + int(np.argmax(c[pos:hi]))
            if c[k] < 0.85:
                pos = hi
                continue
        else:
            lo = max(pos - 4, 0)
            hi = min(pos + 5, len(c))
            k = lo + int(np.argmax(c[lo:hi]))
            if c[k] < 0.70:
                locked = False          # flywheel exhausted immediately (model)
                continue
        payload = soft[k + SYNC_BITS: k + SYNC_BITS + ENCODED_BITS]
        if len(payload) < ENCODED_BITS:
            break
        metric, by = frame_decode(payload)
        frames.append((k, metric, by))
        locked = True
        pos = k + FRAME_SYMBOLS
    return frames

# ----------------------------------------------------------------- run/main --
def demod_file(path, chan_rate=625000.0):
    d = np.fromfile(path, dtype=np.int16).astype(np.float64)
    s = d[0::2] + 1j * d[1::2]
    m = CoherentModel(chan_rate / SYMBOL_RATE)
    Y1, Y2 = m.track_correlations(s)
    dec0, dec1 = m.combine(Y1, Y2)
    soft = m.resolve(dec0, dec1)
    return extract_frames(soft), len(Y1)

if __name__ == "__main__":
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 else "chan5_iq.cs16"
    frames, nsym = demod_file(path)
    print(f"symbols demodulated: {nsym}")
    perfect = sum(1 for _, mt, _ in frames if mt == 0)
    print(f"frames decoded: {len(frames)} ({perfect} perfect)")
    for i, (k, mt, by) in enumerate(frames):
        head = " ".join(f"{b:02X}" for b in by[:16])
        print(f"  frame {i+1:2d} @sym {k:6d} metric {mt:4d}  {head}")
