#!/usr/bin/env python3
"""grade_payload_ber.py -- per-frame payload bit error rate for delivered
frames, measured against the exactly reconstructed transmitted sequence.

THE acceptance instrument for the receiver (2026-10-18): sync counts and
soft amplitudes both passed runs whose payloads were undecodable. This
measures content.

Reads seam_chan_out.txt (quantized softs, 2144 per delivered frame) and
compares sign against the known encoded frame bits from opv_stim's own
encoder (deterministic, same every frame).

Usage (run from haifuraiya/sim, or pass --stim-dir pointing at it):
  python3 grade_payload_ber.py <rundir-or-seam-file> [--stim-dir DIR]
                               [--fec-limit 8.0]

Verdict per frame: BER, polarity, and decodable? (BER under --fec-limit %,
the approximate K=7 R=1/2 soft-decision correction ceiling; default 8%).
Exit code 0 = all frames decodable, 1 = any frame over the limit.
"""
import argparse, os, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="run directory containing seam_chan_out.txt, or the file itself")
    ap.add_argument("--stim-dir", default=".", help="directory containing opv_stim.py")
    ap.add_argument("--fec-limit", type=float, default=8.0,
                    help="decodability threshold, percent pre-FEC BER")
    a = ap.parse_args()

    sys.path.insert(0, a.stim_dir)
    try:
        from opv_stim import build_frame_bits
    except ImportError:
        sys.exit("cannot import opv_stim.py -- run from haifuraiya/sim or use --stim-dir")

    path = a.target
    if os.path.isdir(path):
        path = os.path.join(path, "seam_chan_out.txt")

    enc = list(build_frame_bits(0))[24:]       # 2144 encoded payload bits
    epm = [1 if b == 1 else -1 for b in enc]
    n = len(epm)

    q = []
    with open(path) as fh:
        for line in fh:
            s = line.split()
            if s:
                try:
                    q.append(int(s[0]))
                except ValueError:
                    pass
    nfr = len(q) // n
    print(f"{path}: {len(q)} softs = {len(q)/n:.2f} frames "
          f"(quantized 3-bit; sign at >=4)")
    print(f"FEC decodability limit: {a.fec_limit:.1f}% pre-FEC BER "
          f"(K=7 R=1/2 soft-decision, approximate)")
    print()
    print("frame   BER      pol  verdict")

    bad = 0
    for k in range(nfr):
        c = [1 if v >= 4 else -1 for v in q[k*n:(k+1)*n]]
        e1 = sum(1 for x, y in zip(c, epm) if x != y)
        e2 = n - e1
        ber, pol = (e1, '+') if e1 <= e2 else (e2, '-')
        pct = 100.0 * ber / n
        ok = pct <= a.fec_limit
        bad += 0 if ok else 1
        print(f"  {k+1:3d}  {pct:6.2f}%   {pol}   "
              f"{'DECODABLE' if ok else '** NOT DECODABLE **'}")

    print()
    print(f"{nfr - bad}/{nfr} frames decodable")
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
