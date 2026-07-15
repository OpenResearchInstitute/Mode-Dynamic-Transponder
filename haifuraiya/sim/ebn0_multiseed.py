#!/usr/bin/env python3
"""ebn0_multiseed.py -- multi-seed Eb/N0 characterization at the channel seam.

Per (Eb/N0, seed) trial: generate an OPV burst (encoder + CPM modulator at
625 ksps), add calibrated complex AWGN, then demodulate with:
  MODEL leg : opv_demod_model.py (the transliteration the VHDL inherits;
              the leg that hardening experiments modify)
  CXX leg   : the untouched opv-demod binary (reference control; optional,
              enabled with --cxx PATH)
Reported per Eb/N0 point, with min/max across seeds:
  pre-FEC BER (model soft signs vs encoded truth)
  byte-FER    (frames whose decoded 134 bytes match exactly; both legs)
  slip prob   (model leg: any sync spacing != 2168 within the burst)

Calibration (verified against the native C++ path):
  Es = A^2 * sps,  Eb/N0(channel bit) = Es / (2 sigma^2)
Provenance: logs the md5 of the C++ binary used, per house rule.

Usage:
  python3 ebn0_multiseed.py --points 14,12,10,8,6,5,4 --seeds 10 \
          --frames 8 --cxx ~/stim/opv-cxx-demod/bin/opv-demod \
          --csv baseline.csv
"""
import argparse, hashlib, os, subprocess, sys, tempfile
import numpy as np
from opv_demod_model import (CoherentModel, SYMBOL_RATE, SYNC_BITS,
                             ENCODED_BITS, FRAME_SYMBOLS, frame_decode,
                             track_mlse, vbank_unified, mlse4_psp,
                             extract_frames)
from opv_encode_model import encode_frame, make_burst

PAT = np.array([1.0 if ((0x02B8DB >> (23 - i)) & 1) == 0 else -1.0
                for i in range(24)])

def mlse_trial(x, payloads):
    Y1, Y2 = track_mlse(x)
    soft = mlse4_psp(vbank_unified(Y1, Y2))
    best = (None, -1)
    for pol in (1.0, -1.0):
        fr = extract_frames(pol*soft)
        gd = sum(1 for _, mt, by in fr if by is not None)
        if gd > best[1]:
            best = (fr, gd)
    frames = best[0] or []
    ok = sum(1 for _, mt, by in frames
             if by is not None and any(np.array_equal(by, p) for p in payloads))
    pos = [p for p, _, _ in frames]
    slipped = bool(np.any(np.diff(pos) != FRAME_SYMBOLS)) if len(pos) > 1 else False
    return ok, len(payloads), slipped

def model_trial(x, payloads, raw=False):
    """Demodulate with the python model. Returns (ber, fer_ok, fer_tot,
    slipped) or None if no sync found."""
    m = CoherentModel(625000.0 / SYMBOL_RATE, raw_decision=raw)
    Y1, Y2 = m.track_correlations(x)
    d0, d1 = m.combine(Y1, Y2)
    soft = m.resolve(d0, d1)
    w = np.lib.stride_tricks.sliding_window_view(soft, 24)
    c = (w @ PAT) / (np.abs(w).sum(axis=1) + 1e-9)
    hits = np.nonzero(c[:3 * FRAME_SYMBOLS] > 0.7)[0]
    if not len(hits):
        return None
    k0 = int(hits[0])
    bit_err = bit_tot = 0
    ok = tot = 0
    positions = []
    kk = k0
    for f, payload in enumerate(payloads):
        lo, hi = max(kk - 3, 0), min(kk + 4, len(c))
        if hi <= lo or kk + FRAME_SYMBOLS > len(soft):
            break
        kk = lo + int(np.argmax(c[lo:hi]))
        positions.append(kk)
        seg = soft[kk + SYNC_BITS: kk + SYNC_BITS + ENCODED_BITS]
        if len(seg) < ENCODED_BITS:
            positions.pop()
            break
        onair = encode_frame(payload)[SYNC_BITS:]
        bit_err += int(np.sum((seg < 0).astype(np.uint8) != onair))
        bit_tot += ENCODED_BITS
        metric, by = frame_decode(seg)
        tot += 1
        if by is not None and np.array_equal(by, payload):
            ok += 1
        kk = positions[-1] + FRAME_SYMBOLS
    if bit_tot == 0:
        return None
    spac = np.diff(positions)
    slipped = bool(np.any(spac != FRAME_SYMBOLS)) if len(spac) else False
    return bit_err / bit_tot, ok, tot, slipped

def cxx_trial(x, payloads, cxx_bin):
    """Decode with the untouched C++ binary; byte-FER only."""
    xi = np.clip(np.round(x.real), -32768, 32767).astype(np.int16)
    xq = np.clip(np.round(x.imag), -32768, 32767).astype(np.int16)
    buf = np.empty(2 * len(xi), dtype=np.int16)
    buf[0::2] = xi; buf[1::2] = xq
    r = subprocess.run([cxx_bin, "-c", "-R", "625000", "-q", "-r"],
                       input=buf.tobytes(), capture_output=True, timeout=300)
    got = np.frombuffer(r.stdout, dtype=np.uint8)
    got = got[:len(got) // 134 * 134].reshape(-1, 134)
    ok = sum(1 for g in got
             if any(np.array_equal(g, p) for p in payloads))
    return ok, len(payloads)   # denominator: frames SENT (missed = failed)

def run(args):
    cxx = None
    if args.cxx:
        cxx = os.path.expanduser(args.cxx)
        md5 = hashlib.md5(open(cxx, "rb").read()).hexdigest()
        print(f"# cxx binary: {cxx}  md5 {md5}")
    print(f"# frames/trial {args.frames}, seeds/point {args.seeds}, "
          f"amp {args.amp}, model resolve: decode-verified, "
          f"receiver: {'MLSE (V-bank TED + 4-state PSP)' if args.mlse else ('RAW-WINDOW exp1' if args.raw else 'legacy combine (baseline)')}")
    hdr = (f"{'Eb/N0':>6} {'BER(mean)':>10} {'BER(clean)':>10} "
           f"{'FER model':>10} {'slipP':>6}")
    if cxx:
        hdr += f" {'FER cxx':>9}"
    print(hdr)
    rows = []
    sps = 625000.0 / SYMBOL_RATE
    for p in [float(v) for v in args.points.split(",")]:
        bers, bers_clean, mok, mtot, slips = [], [], 0, 0, 0
        cok, ctot = 0, 0
        for s in range(args.seeds):
            rng = np.random.default_rng(hash((int(p * 10), s)) % 2**32)
            payloads = [rng.integers(0, 256, 134).astype(np.uint8)
                        for _ in range(args.frames)]
            sig = make_burst(payloads, amp=args.amp, preamble_frames=1)
            sigma = np.sqrt(args.amp**2 * sps / (2 * 10 ** (p / 10)))
            x = sig + sigma * (rng.standard_normal(len(sig))
                               + 1j * rng.standard_normal(len(sig)))
            x = (np.clip(np.round(x.real), -32768, 32767)
                 + 1j * np.clip(np.round(x.imag), -32768, 32767))
            if args.mlse:
                ok, tot_, sl = mlse_trial(x, payloads)
                mok += ok; mtot += args.frames; slips += int(sl)
            else:
                r = model_trial(x, payloads, raw=args.raw)
                if r is None:
                    mtot += args.frames; slips += 1
                else:
                    ber, ok, tot, sl = r
                    bers.append(ber)
                    if not sl:
                        bers_clean.append(ber)
                    mok += ok
                    mtot += args.frames          # missed frames count as failed
                    slips += int(sl)
            if cxx:
                co, ct = cxx_trial(x, payloads, cxx)
                cok += co; ctot += ct
        if args.mlse:
            bers, bers_clean = [], []   # not applicable to full-chain path
        row = {"ebn0": p,
               "ber": float(np.mean(bers)) if bers else 1.0,
               "ber_clean": float(np.mean(bers_clean)) if bers_clean else float("nan"),
               "fer_model": 1.0 - mok / max(mtot, 1),
               "slip_p": slips / args.seeds,
               "fer_cxx": (1.0 - cok / max(ctot, 1)) if cxx else None}
        rows.append(row)
        if args.mlse:
            line = (f"{p:6.1f} {'--':>10} {'--':>10} "
                    f"{mok:4d}/{mtot:<5d} {row['slip_p']:6.2f}")
        else:
            line = (f"{p:6.1f} {row['ber']:10.2e} {row['ber_clean']:10.2e} "
                    f"{mok:4d}/{mtot:<5d} {row['slip_p']:6.2f}")
        if cxx:
            line += f" {cok:4d}/{ctot:<4d}"
        print(line, flush=True)
    if args.csv:
        import csv
        with open(args.csv, "w", newline="") as fh:
            wcsv = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            wcsv.writeheader()
            wcsv.writerows(rows)
        print(f"# wrote {args.csv}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", default="14,12,10,8,6,5,4")
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--amp", type=float, default=3000.0)
    ap.add_argument("--cxx", default=None)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--raw", action="store_true", help="raw-window decision correlator (experiment 1)")
    ap.add_argument("--mlse", action="store_true", help="NEW receiver: V-bank TED + 4-state MLSE-PSP")
    run(ap.parse_args())
