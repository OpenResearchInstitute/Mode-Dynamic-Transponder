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
    def __init__(self, sps_nom, freq_offset=0.0, raw_decision=False):
        self.sps = float(sps_nom)
        self.foff = float(freq_offset)
        self.el = 0.5
        self.alpha_t = 0.06
        self.beta_t = 0.0025
        # EXPERIMENT 1 (2026-07-15): raw integer-window decision correlations.
        # Measured: the Catmull-Rom interpolating correlator loses ~3.6 dB of
        # detection SNR vs a raw-sample correlator (9.06 vs 12.62 dB coherent
        # at Eb/N0=10, ideal 13.01). raw_decision=True uses raw windows for
        # the on-time (decision) correlations; the TED early/late arms keep
        # the interpolator, where sub-sample offsets are required and SNR is
        # less critical. This is also the hardware-natural structure.
        self.raw_decision = bool(raw_decision)
        # EXPERIMENT 2: post-lock gain scheduling. After settle_syms symbols
        # the timing PI and Costas gains are scaled by gain_sched (loops keep
        # acquisition agility, then quiet down to reduce noise-driven jitter,
        # which measurement shows sets an SNR-independent BER floor ~3e-2).
        # gain_sched = 1.0 reproduces the baseline exactly.
        self.settle_syms = 2000
        self.gain_sched = 1.0
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

    def corr_at_raw(self, s, base):
        """Tone correlations over one symbol using RAW integer samples in
        [ceil(base), floor(base+sps)], phase-continuous absolute LO."""
        n0 = int(np.ceil(base))
        n1 = int(np.floor(base + self.sps))
        n = np.arange(n0, min(n1 + 1, len(s)))
        v = s[n]
        return (np.sum(v * np.exp(1j * self.inc1 * n)),
                np.sum(v * np.exp(1j * self.inc2 * n)))

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
        at, bt = self.alpha_t, self.beta_t
        while pos + self.sps + EL + 2.0 < n:
            if len(Y1o) == self.settle_syms and self.gain_sched != 1.0:
                at = self.alpha_t * self.gain_sched
                bt = self.beta_t * self.gain_sched
            if self.raw_decision:
                Y1, Y2 = self.corr_at_raw(s, pos)
            else:
                Y1, Y2 = self.corr_at(s, pos)
            Y1e, Y2e = self.corr_at(s, pos - EL)
            Y1l, Y2l = self.corr_at(s, pos + EL)
            t1 = abs(Y1)**2 > abs(Y2)**2
            ya = Y1 if t1 else Y2
            dy = (Y1l - Y1e) if t1 else (Y2l - Y2e)
            err = (ya.real*dy.real + ya.imag*dy.imag) / (abs(ya)**2 + 1e-9)
            freq += bt * err
            freq = min(max(freq, -0.05), 0.05)
            adj = at * err + freq
            adj = min(max(adj, -2.0), 2.0)
            Y1o.append(Y1)
            Y2o.append(Y2)
            pos += self.sps + adj
        return np.array(Y1o), np.array(Y2o)

    @staticmethod
    def combine(Y1, Y2, settle=None, sched=1.0):
        """Decision-switched Costas (Hodgart) + Massey 2T combine + differential
        boxplus. Returns both parity streams dec0, dec1."""
        nsym = len(Y1)
        X = np.zeros(nsym)
        Yv = np.zeros(nsym)
        pll_a, pll_b = 0.01, 2e-4
        theta, freq = 0.0, 0.0
        for k in range(nsym):
            if settle is not None and k == settle:
                pll_a *= sched; pll_b *= sched
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
    e = np.abs(w).sum(axis=1)
    c = (w @ pat) / (e + 1e-9)
    # energy floor (the fabric's MIN_SYNC_ENERGY doctrine, scale-free):
    # junk soft in acquisition/silence regions is weak; require real energy
    # before a correlation may count as sync.
    c = np.where(e > 0.5 * np.median(e), c, 0.0)
    frames = []
    # demod_sync_lock doctrine (as in fabric): sync search opens only after
    # the demodulator has settled. The preamble is >= 2168 symbols; opening
    # at 1000 skips acquisition junk while preceding the first frame sync.
    pos, locked = min(1000, max(0, len(c) - 1)), False
    while pos + SYNC_BITS + ENCODED_BITS <= len(soft):
        if not locked:
            hi = min(pos + 2 * FRAME_SYMBOLS, len(c))
            if hi <= pos:
                break
            # first-above-threshold (not argmax): a degraded-but-valid
            # early frame must not lose the hunt to a stronger later one.
            # Junk peaks are already fenced by the sync-lock start and the
            # energy floor.
            above = np.nonzero(c[pos:hi] >= 0.85)[0]
            if len(above) == 0:
                pos = hi
                continue
            k = pos + int(above[0])
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


# ============================================================ MLSE receiver
# Session 3-4 redesign: coherent 2T matched-filter bank + 4-state MLSE with
# per-survivor phase. Constants DERIVED from measured phase-step tables
# (see demod_phase0 README): unification gamma = 172.15 deg (= pi minus one
# sample of tone phase at the pos grid), bank signs (+,-,-,+), state sign
# flips when the new bit is 0. Measured: 100.000% clean detection;
# ~1.1-1.5 dB total implementation loss vs coherent MSK theory at
# Eb/N0 6..10 dB with genie timing (old combine: ~3e-2 floor).
GAMMA_UNIFY_DEG = 172.15

def vbank_unified(Y1, Y2):
    """Coherent 2T MF bank on unified arms. Rows: V11, V00, V10, V01."""
    n = len(Y1)
    Q = Y2 * np.exp(1j*np.radians(GAMMA_UNIFY_DEG)) \
           * np.where(np.arange(n) % 2 == 0, 1.0, -1.0)
    return np.stack([Y1[:-1] + Y1[1:],
                     Q[:-1]  - Q[1:],
                     Y1[:-1] - Q[1:],
                     Q[:-1]  + Y1[1:]])

_MLSE_PAIR = {(1,1):0, (0,0):1, (1,0):2, (0,1):3}

def mlse4_psp(V, g_phase=0.05, th_init=(0.0, np.pi/4, np.pi/2, 3*np.pi/4)):
    """4-state MSK MLSE, per-survivor phase, soft output (ACS margins).
    State = (axis sign, previous bit). Same ACS+traceback pattern as the
    K=7 viterbi_tailbiting, four states, free-running."""
    nw = V.shape[1]; NS = 4
    cur = np.zeros(NS); th = np.array(th_init, dtype=float)
    pred = np.zeros((nw, NS), dtype=np.int8)
    marg = np.zeros((nw, NS))
    for t in range(nw):
        nxt = np.empty(NS); nth = np.empty(NS)
        npd = np.zeros(NS, dtype=np.int8); nmg = np.zeros(NS)
        for st2 in range(NS):
            s2 = 1.0 if (st2 >> 1) == 0 else -1.0
            bnew = st2 & 1
            s = s2 if bnew == 1 else -s2      # flip when new bit is 0
            cands = []
            for pb in (0, 1):
                stp = ((0 if s > 0 else 1) << 1) | pb
                v = V[_MLSE_PAIR[(pb, bnew)], t] * np.exp(-1j*th[stp])
                cands.append((cur[stp] + s*v.real, stp, v))
            (m0,p0,v0),(m1,p1,v1) = cands
            if m0 >= m1: w,pw,vw,l = m0,p0,v0,m1
            else:        w,pw,vw,l = m1,p1,v1,m0
            nxt[st2] = w; npd[st2] = pw; nmg[st2] = w - l
            nth[st2] = th[pw] + g_phase*(np.angle(s*vw) if abs(vw) > 0 else 0.0)
        cur = nxt - nxt.max(); th = nth
        pred[t] = npd; marg[t] = nmg
    soft = np.zeros(nw)
    st = int(np.argmax(cur))
    for t in range(nw - 1, -1, -1):
        bnew = st & 1
        soft[t] = marg[t, st] if bnew == 1 else -marg[t, st]
        st = int(pred[t, st])
    return soft


def track_mlse(s, alpha_t=0.06, beta_t=0.0025, el=0.5, sps_nom=None,
               acq_syms=1000, acq_boost=3.0, pos0=None):
    """Timing loop with V-bank winner early-late TED (session 5).
    Same 3x correlation cost and PI structure as the legacy loop; the
    error signal is pattern-independent (the V-bank winner always holds
    full 2T energy). Gates passed: interop 10/10; 8 dB 18/18 (legacy TED
    2/18); mission threshold ~4.5 dB held at the frame level."""
    m = CoherentModel(sps_nom if sps_nom else 625000.0/54200.0)
    g = np.exp(1j*np.radians(GAMMA_UNIFY_DEG))
    EL = el
    pos = EL + 1.0 + (pos0 if pos0 is not None else 0.0)
    freq = 0.0
    Y1o, Y2o = [], []
    prev = None
    n = len(s); k = 0
    while pos + m.sps + EL + 2.0 < n:
        y1e, y2e = m.corr_at(s, pos - EL)
        y1c, y2c = m.corr_at(s, pos)
        y1l, y2l = m.corr_at(s, pos + EL)
        Y1o.append(y1c); Y2o.append(y2c)
        if prev is not None:
            (p1e,p2e,p1c,p2c,p1l,p2l,kp) = prev
            qp = g*(1.0 if kp % 2 == 0 else -1.0)
            qc = g*(1.0 if k % 2 == 0 else -1.0)
            def _bank(a1p, a2p, a1c, a2c):
                Qp, Qc = a2p*qp, a2c*qc
                return np.abs(np.array([a1p+a1c, Qp-Qc, a1p-Qc, Qp+a1c]))
            Ae = _bank(p1e,p2e,y1e,y2e)
            Ac = _bank(p1c,p2c,y1c,y2c)
            Al = _bank(p1l,p2l,y1l,y2l)
            w = int(np.argmax(Ac))
            err = (Al[w] - Ae[w]) / (Ac[w] + 1e-9)
            gear = acq_boost if k < acq_syms else 1.0   # acquisition gear
            freq = min(max(freq + gear*beta_t*err, -0.05), 0.05)
            adj  = min(max(gear*alpha_t*err + freq, -2.0), 2.0)
        else:
            adj = 0.0
        prev = (y1e,y2e,y1c,y2c,y1l,y2l,k)
        pos += m.sps + adj
        k += 1
    return np.array(Y1o), np.array(Y2o)

def demod_mlse(x):
    """Full new-receiver chain: track_mlse -> vbank_unified -> mlse4_psp
    -> extract_frames (both polarities, best wins)."""
    Y1, Y2 = track_mlse(x)
    soft = mlse4_psp(vbank_unified(Y1, Y2))
    best = (None, -1)
    for pol in (1.0, -1.0):
        fr = extract_frames(pol*soft)
        gd = sum(1 for _, mt, by in fr if by is not None)
        if gd > best[1]:
            best = (fr, gd)
    return best[0]


def coarse_acquire(s, sps_nom=None, n_off=8, k0=200, k1=420):
    """Preamble-aided coarse timing: search n_off grid offsets across one
    symbol; metric = sum of V-bank winner magnitudes over preamble symbols
    k0..k1. Returns the best starting offset in [0, sps). Fabric-honest:
    this is what the preamble is for."""
    m = CoherentModel(sps_nom if sps_nom else 625000.0/54200.0)
    g = np.exp(1j*np.radians(GAMMA_UNIFY_DEG))
    best = (None, -1.0)
    for off in np.arange(n_off)/n_off*m.sps:
        tot = 0.0
        prev = None
        for k in range(k0, k1):
            pos = 1.0 + off + k*m.sps
            if pos + m.sps + 2 >= len(s): break
            y1, y2 = m.corr_at(s, pos)
            if prev is not None:
                p1, p2, kp = prev
                Qp = p2*g*(1.0 if kp % 2 == 0 else -1.0)
                Qc = y2*g*(1.0 if k % 2 == 0 else -1.0)
                tot += max(abs(p1+y1), abs(Qp-Qc), abs(p1-Qc), abs(Qp+y1))
            prev = (y1, y2, k)
        if tot > best[1]:
            best = (off, tot)
    return best[0]
