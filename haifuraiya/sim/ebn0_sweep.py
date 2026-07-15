#!/usr/bin/env python3
"""ebn0_sweep.py -- Eb/N0 sweep harness at the channelizer-demod seam.

Generates OPV bursts at the channel rate with the validated python
encoder/modulator, adds calibrated complex AWGN, runs the demod model, and
reports pre-FEC BER (resolved soft signs vs encoded truth) and FER
(frame_decode payload bytes correct) per Eb/N0 point.

Calibration. Constant-envelope amplitude A, sps = 625000/54200 samples per
symbol, one CHANNEL bit per MSK symbol:
    Es = A^2 * sps            (discrete symbol energy)
    Eb/N0 (channel bit) = Es / (2 sigma^2),  sigma = per-component noise std
    Eb/N0 (info bit, rate 1/2) = channel-bit Eb/N0 + 3.01 dB
Theory reference for the pre-FEC curve: coherent MSK ~ BER = Q(sqrt(2 Eb/N0));
the harness prints the theory value so implementation loss is visible per
point. This float-model curve is the Phase 0b baseline: every fixed-point
quantization step re-runs the sweep and must stay within 0.2 dB of it.

Usage: python3 ebn0_sweep.py [--points 12,8,6,5,4] [--frames 8] [--seed 3]
"""
import argparse
import numpy as np
from math import erfc, sqrt
from opv_demod_model import (CoherentModel, SYMBOL_RATE, SYNC_BITS,
                             ENCODED_BITS, FRAME_SYMBOLS, frame_decode)
from opv_encode_model import encode_frame, make_burst

def qfunc(x):
    return 0.5 * erfc(x / sqrt(2.0))

def run_point(ebn0_db, n_frames, rng, amp=9000.0, fs=625000.0):
    sps = fs / SYMBOL_RATE
    payloads = [rng.integers(0, 256, 134).astype(np.uint8)
                for _ in range(n_frames)]
    s = make_burst(payloads, fs=fs, amp=amp, preamble_frames=1)
    es = amp * amp * sps
    sigma = np.sqrt(es / (2.0 * 10.0 ** (ebn0_db / 10.0)))
    noise = sigma * (rng.standard_normal(len(s)) +
                     1j * rng.standard_normal(len(s)))
    x = s + noise
    xi = np.clip(np.round(x.real), -32768, 32767)
    xq = np.clip(np.round(x.imag), -32768, 32767)
    x = xi + 1j * xq

    m = CoherentModel(sps)
    Y1, Y2 = m.track_correlations(x)
    d0, d1 = m.combine(Y1, Y2)
    soft = m.resolve(d0, d1)

    # locate first data sync (skip preamble), then walk the grid
    pat = np.array([1.0 if b == 0 else -1.0 for b in
                    [(0x02B8DB >> (SYNC_BITS - 1 - i)) & 1
                     for i in range(SYNC_BITS)]])
    w = np.lib.stride_tricks.sliding_window_view(soft, SYNC_BITS)
    c = (w @ pat) / (np.abs(w).sum(axis=1) + 1e-9)
    hits = np.nonzero(c[:3 * FRAME_SYMBOLS] > 0.7)[0]
    if not len(hits):
        return None
    k0 = int(hits[0])

    bit_err = bit_tot = 0
    frames_ok = frames_tot = 0
    for f, payload in enumerate(payloads):
        kk = k0 + f * FRAME_SYMBOLS
        lo, hi = max(kk - 3, 0), min(kk + 4, len(c))
        if hi <= lo or kk + FRAME_SYMBOLS > len(soft):
            break
        kk = lo + int(np.argmax(c[lo:hi]))
        seg = soft[kk + SYNC_BITS: kk + SYNC_BITS + ENCODED_BITS]
        if len(seg) < ENCODED_BITS:
            break
        onair = encode_frame(payload)[SYNC_BITS:]
        rx = (seg < 0).astype(np.uint8)
        bit_err += int(np.sum(rx != onair))
        bit_tot += ENCODED_BITS
        metric, by = frame_decode(seg)
        frames_tot += 1
        if by is not None and np.array_equal(by, payload):
            frames_ok += 1
    if bit_tot == 0:
        return None
    return bit_err / bit_tot, frames_ok, frames_tot

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", default="12,8,6,5,4.5,4")
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--seed", type=int, default=3)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    print(f"{'Eb/N0(ch)':>9} {'theory BER':>11} {'meas BER':>11} "
          f"{'FER':>9}  ({a.frames} frames/point, seed {a.seed})")
    for p in [float(x) for x in a.points.split(",")]:
        r = run_point(p, a.frames, rng)
        th = qfunc(np.sqrt(2.0 * 10.0 ** (p / 10.0)))
        if r is None:
            print(f"{p:9.1f} {th:11.2e} {'no sync':>11} {'-':>9}")
            continue
        ber, ok, tot = r
        print(f"{p:9.1f} {th:11.2e} {ber:11.2e} {ok:4d}/{tot:<4d}")
