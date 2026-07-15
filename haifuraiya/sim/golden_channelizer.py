#!/usr/bin/env python3
"""golden_channelizer.py -- bit-exact model of the Haifuraiya receive front end.

Models, integer-for-integer against the RTL:
  halfband_model : halfband_decimator.vhd  (75-tap, round-half-up >>17, sat16)
  core_model     : haifuraiya_channelizer_top.vhd =
                     polyphase_filterbank_parallel (full-precision 40-bit MAC)
                   + r2sdf_fft (6 DIF stages, Q1.14 twiddles TW_SCALE=16383,
                     ties-away ROM rounding, 40-bit wrap sums, truncating >>14
                     on the twiddled difference)
                   + r2sdf_reorder (FRAME_PHASE=1 ping-pong, bit-reversal)
                   + priming (FILL_FRAMES=2) and the oversampled-output
                     rotation j^(k*m), m = emitted-frame index + 1.

Validation: validate_against_dump() compares (idx, re, im) beat-for-beat with
tb_core_tone.vhd / tb_chain_tone.vhd capture files. Zero tolerance.
"""
import numpy as np

MASK40 = 1 << 40
HALF40 = 1 << 39

def wrap40(a):
    return ((a + HALF40) % MASK40) - HALF40

def round_ties_away(x):
    return np.sign(x) * np.floor(np.abs(x) + 0.5)

# ---------------------------------------------------------------- halfband ---
HB_TAPS = np.array([5,0,-12,0,26,0,-50,0,88,0,-147,0,233,0,-355,0,522,0,-747,0,
1047,0,-1444,0,1970,0,-2682,0,3681,0,-5188,0,7776,0,-13559,0,41604,65536,
41604,0,-13559,0,7776,0,-5188,0,3681,0,-2682,0,1970,0,-1444,0,1047,0,-747,0,
522,0,-355,0,233,0,-147,0,88,0,-50,0,26,0,-12,0,5], dtype=np.int64)

def _hb_lane(x):
    """One lane (I or Q), int array at 20 Msps -> decimated int16 at 10 Msps.
    dl(0)=newest; output on every 2nd input (emit when ph toggles '1'->,
    i.e. on even-index inputs counting from 1: samples 1,3,5.. 0-based odd)."""
    x = np.asarray(x, dtype=np.int64)
    # convolution with dl(i)=x[n-i]: y[n] = sum_i taps[i]*x[n-i]
    acc = np.convolve(x, HB_TAPS)[:len(x)]
    # RTL emits on the 2nd sample of each pair: 0-based input indices 1,3,5,...
    acc = acc[1::2]
    r = acc + (1 << 16)
    y = r >> 17
    return np.clip(y, -32768, 32767).astype(np.int64)

def halfband_model(xi, xq):
    return _hb_lane(xi), _hb_lane(xq)

# ------------------------------------------------------------- filterbank ---
def load_coeffs(pkg_path):
    import re as _re
    vals = _re.findall(r'x"([0-9A-Fa-f]{4})"', open(pkg_path).read())
    c = np.array([int(v, 16) for v in vals], dtype=np.int64)
    c[c >= 32768] -= 65536
    return c.reshape(64, 24)      # branch-major: C[k, i]

def filterbank(x, C, M=16, N=64, T=24):
    """x: int array (one lane). Returns (F, 64) int64 branch outputs.
    Frame f fires with newest sample index t = M*f + (M-1);
    branch k tap i multiplies x[t - (k + N*i)]."""
    x = np.asarray(x, dtype=np.int64)
    L = len(x)
    F = L // M
    xp = np.concatenate([np.zeros(N * T, dtype=np.int64), x])  # zero history
    out = np.empty((F, N), dtype=np.int64)
    t = np.arange(F) * M + (M - 1) + N * T                      # index into xp
    for k in range(N):
        # taps i=0..23 at xp[t - k - 64 i]  -> (F, 24) gather
        idx = t[:, None] - k - N * np.arange(T)[None, :]
        out[:, k] = (xp[idx] * C[k][None, :]).sum(axis=1)
    return out

# ------------------------------------------------------------------ r2sdf ---
def _tw_rom(N=64):
    k = np.arange(N // 2)
    a = 2.0 * np.pi * k / N
    scale = float((1 << 14) - 1)               # 16383, matches TW_SCALE
    re = round_ties_away(np.cos(a) * scale).astype(np.int64)
    im = round_ties_away(-np.sin(a) * scale).astype(np.int64)
    return re, im

def r2sdf_stream(zr, zi, N=64):
    """Bit-exact streaming R2SDF DIF over a continuous sample stream.
    zr, zi: int64 arrays, length multiple of N. Returns transformed stream
    (pre-reorder). Vectorized over 2D-sample windows per stage."""
    TWRE, TWIM = _tw_rom(N)
    for s in range(6):                          # D = 32,16,8,4,2,1
        D = N >> (s + 1)
        S = N // (2 * D)                        # twiddle stride = 2^s
        W = 2 * D
        nwin = len(zr) // W
        a_r = zr[: nwin * W].reshape(nwin, W)[:, :D]
        a_i = zi[: nwin * W].reshape(nwin, W)[:, :D]
        b_r = zr[: nwin * W].reshape(nwin, W)[:, D:]
        b_i = zi[: nwin * W].reshape(nwin, W)[:, D:]
        sum_r = wrap40(a_r + b_r)               # phase-B forward output
        sum_i = wrap40(a_i + b_i)
        dif_r = wrap40(a_r - b_r)
        dif_i = wrap40(a_i - b_i)
        twr = TWRE[np.arange(D) * S][None, :]
        twi = TWIM[np.arange(D) * S][None, :]
        pr = dif_r * twr - dif_i * twi          # <= 2^53, int64-safe
        pi = dif_r * twi + dif_i * twr
        fb_r = wrap40(pr >> 14)                 # truncating un-scale (slice)
        fb_i = wrap40(pi >> 14)
        out_r = np.empty_like(zr[: nwin * W]).reshape(nwin, W)
        out_i = np.empty_like(zi[: nwin * W]).reshape(nwin, W)
        # phase A of window w outputs the feedback written in window w-1
        out_r[0, :D] = 0; out_i[0, :D] = 0      # zero-initialized feedback
        out_r[1:, :D] = fb_r[:-1]; out_i[1:, :D] = fb_i[:-1]
        out_r[:, D:] = sum_r;      out_i[:, D:] = sum_i
        zr = out_r.reshape(-1); zi = out_i.reshape(-1)
    return zr, zi

def _bitrev6(v):
    r = 0
    for b in range(6):
        r = (r << 1) | ((v >> b) & 1)
    return r

BITREV = np.array([_bitrev6(v) for v in range(64)])

def core_model(xi, xq, C, M=16, N=64):
    """Full core: two filterbanks -> P2S (branch order) -> R2SDF -> reorder
    (FRAME_PHASE=1) -> priming (FILL_FRAMES=2) -> rotation j^(k*m).
    Returns beats as (n_beats, 3) int64 array of [idx, re, im], exactly the
    tb_core_tone capture format."""
    fb_i = filterbank(xi, C, M, N)              # (F, 64) -> FFT real input
    fb_q = filterbank(xq, C, M, N)
    F = fb_i.shape[0]
    zr, zi = r2sdf_stream(fb_i.reshape(-1), fb_q.reshape(-1), N)
    # reorder closed form: emitted frame e (e >= 1) bin idx =
    #   stream[64*e - 1 + bitrev(idx)]; priming drops e = 0 (never read) and
    #   emission starts at e = 1 with rotation m = e + 1.
    beats = []
    e_max = F - 1                                # need write-frame e complete
    ks = np.arange(N)
    for e in range(1, e_max):
        src = 64 * e - 1 + BITREV                # per-idx source position
        re = zr[src].copy(); im = zi[src].copy()
        m = e + 1
        sel = (ks * m) % 4
        rre = np.where(sel == 0, re, np.where(sel == 1, -im,
              np.where(sel == 2, -re, im)))
        rim = np.where(sel == 0, im, np.where(sel == 1, re,
              np.where(sel == 2, -im, -re)))
        frame = np.stack([ks, rre, rim], axis=1)
        beats.append(frame)
    return np.concatenate(beats, axis=0)

# -------------------------------------------------------------- validation ---
def validate_against_dump(beats, dump_path):
    d = np.loadtxt(dump_path, dtype=np.int64)
    n = min(len(d), len(beats))
    ok = np.array_equal(d[:n], beats[:n])
    if not ok:
        bad = np.nonzero((d[:n] != beats[:n]).any(axis=1))[0]
        print(f"  MISMATCH: {len(bad)} beats differ, first at beat {bad[0]}")
        print(f"    rtl  : {d[bad[0]]}")
        print(f"    model: {beats[bad[0]]}")
    return ok, n

if __name__ == "__main__":
    import sys
    C = load_coeffs(sys.argv[1] if len(sys.argv) > 1
                    else "haifuraiya_coeffs_pkg.vhd")
    print("coefficients loaded:", C.shape)
