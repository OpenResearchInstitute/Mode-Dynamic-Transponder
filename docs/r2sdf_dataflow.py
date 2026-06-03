#!/usr/bin/env python3
"""
r2sdf_dataflow.py -- cycle-accurate model of the R2SDF pipeline dataflow.

This mirrors exactly what the VHDL will do: log2(N) autonomous delay-feedback
stages, each valid-gated, followed by a bit-reversal reorder. It reuses the
EXACT fixed-point primitives from r2sdf_fft_model (wrap, twiddle ROM, the
truncating butterfly), so if this matches the golden model fft_fixed() then the
*architecture* (stage operation, twiddle alignment, reorder direction) is
proven correct -- and the VHDL just has to transcribe it.
"""

from r2sdf_fft_model import (wrap, make_twiddles, fft_fixed, bit_reverse,
                             TWIDDLE_FRAC)


class Stage:
    """One R2SDF DIF stage, feedback depth D. One push = one valid sample."""
    def __init__(self, n, d):
        self.d = d
        self.stride = n // (2 * d)        # = 2^stage_index
        self.rom = make_twiddles(n)
        self.fb = [(0, 0)] * d            # feedback shift register, depth D
        self.c = 0                        # local counter, 0 .. 2D-1

    def push(self, din):
        d = self.d
        z = self.fb[0]                    # value delayed by D
        if self.c < d:                    # phase A: load input, pass z forward
            out = z
            fb_in = din
        else:                             # phase B: butterfly
            ar, ai = z
            br, bi = din
            sum_re = wrap(ar + br)
            sum_im = wrap(ai + bi)
            diff_re = wrap(ar - br)
            diff_im = wrap(ai - bi)
            twr, twi = self.rom[(self.c - d) * self.stride]
            prod_re = diff_re * twr - diff_im * twi
            prod_im = diff_re * twi + diff_im * twr
            out = (sum_re, sum_im)
            fb_in = (wrap(prod_re >> TWIDDLE_FRAC),
                     wrap(prod_im >> TWIDDLE_FRAC))
        self.fb = self.fb[1:] + [fb_in]   # shift: drop head, append new tail
        self.c = (self.c + 1) % (2 * d)
        return out


def r2sdf_stream(samples, n):
    """Push a flat sample stream through the cascade. Returns the (bit-reversed,
    latency-delayed) output stream, one sample per input sample."""
    log2n = n.bit_length() - 1
    stages = [Stage(n, n >> (i + 1)) for i in range(log2n)]
    out = []
    for s in samples:
        x = s
        for st in stages:
            x = st.push(x)
        out.append(x)
    return out


def verify():
    import random
    n = 64
    log2n = 6
    rng = random.Random(1234)

    # Several frames of full-scale-ish random complex input.
    nframes = 8
    frames = []
    for _ in range(nframes):
        f = [(rng.randint(-(1 << 17), (1 << 17)),
              rng.randint(-(1 << 17), (1 << 17))) for _ in range(n)]
        frames.append(f)

    flat = [s for f in frames for s in f]
    flat += [(0, 0)] * (4 * n)            # drain the pipeline
    stream = r2sdf_stream(flat, n)

    # Find the pipeline latency L: the offset where the stream, taken in
    # N-blocks and de-bit-reversed, equals fft_fixed(frame 0).
    expected0 = fft_fixed(frames[0])
    L = None
    for cand in range(0, len(stream) - n):
        seg = stream[cand:cand + n]
        # de-bit-reverse: natural[bit_reverse(k)] = seg[k]
        nat = [None] * n
        for k in range(n):
            nat[bit_reverse(k, log2n)] = seg[k]
        if nat == expected0:
            L = cand
            break
    if L is None:
        print("FAIL: could not align any output block to fft_fixed(frame 0)")
        return False
    print(f"pipeline latency L = {L} samples")

    # Now check ALL frames at that latency, bit-exact.
    mismatch = 0
    for fi, frame in enumerate(frames):
        seg = stream[L + fi * n: L + (fi + 1) * n]
        nat = [None] * n
        for k in range(n):
            nat[bit_reverse(k, log2n)] = seg[k]
        exp = fft_fixed(frame)
        if nat != exp:
            mismatch += 1
            # show first differing bin
            for b in range(n):
                if nat[b] != exp[b]:
                    print(f"  frame {fi} bin {b}: got {nat[b]} exp {exp[b]}")
                    break
    if mismatch == 0:
        print(f"PASS: all {nframes} frames bit-exact to the golden model")
        print(f"  reorder: natural[bit_reverse(k)] = stream[k]")
        return True
    print(f"FAIL: {mismatch}/{nframes} frames mismatched")
    return False


if __name__ == "__main__":
    ok = verify()
    raise SystemExit(0 if ok else 1)
