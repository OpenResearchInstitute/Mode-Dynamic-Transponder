#!/usr/bin/env python3
"""
r2sdf_fft_model.py -- Fixed-point golden model for the Haifuraiya pipelined
                      (R2SDF) FFT core.

Open Research Institute -- Haifuraiya / Mode-Dynamic-Transponder
Polyphase channelizer, pipelined-FFT back end.

WHAT THIS IS
------------
The bit-exact reference for the R2SDF FFT RTL. The VHDL core must reproduce
this model's integer outputs exactly, sample for sample. The recipe below is
transplanted verbatim from the current iterative core (fft_n_pt.vhd): same
widths, same twiddle ROM, same truncation, same wrap-on-overflow, same radix-2
DIF decomposition. An R2SDF pipeline changes *when* each butterfly is computed,
not the arithmetic -- the butterflies within a stage are independent and the
stage order is unchanged -- so the numbers come out identical, produced
continuously instead of in 320-cycle bursts. That makes the new core a true
numerical drop-in: OUTPUT_SHIFT, the power detectors, EQ, and m_axis widths
need no change.

THE FIXED-POINT SPEC (the "recipe" both Python and VHDL must obey)
-----------------------------------------------------------------
  Datapath   : DATA_WIDTH = 40-bit signed, held constant through all stages.
               No per-stage rescale; the log2(N) bits of growth of an unscaled
               forward FFT live in the 40-bit headroom.
  Overflow   : wrap (two's complement), NOT saturate. Matches the current core,
               which relies on input headroom so the sum path never actually
               overflows in operation.
  Twiddles   : TWIDDLE_WIDTH = 16-bit signed, Q1.14 (scale 2^14 = 16384).
               W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N).
               Stored value = round(trig * (2^14 - 1)) = round(trig * 16383),
               round-to-nearest (matches VHDL integer(real)).
  Butterfly  : DIF radix-2.
               sum  = wrap40(a + b)                  (NOT twiddled)
               diff = wrap40(a - b)
               prod = diff * twiddle                 (full precision)
               out  = wrap40(prod >> 14)             (arithmetic shift = floor =
                                                      truncate; un-scales Q1.14
                                                      and drops the top 2 bits)
  Order      : natural-order input -> natural-order output. DIF leaves results
               in bit-reversed order; the readout undoes it (out_idx = 0..N-1),
               matching the convention the channelizer already expects.

The result is the UNSCALED forward DFT (DC bin = sum of inputs, ~N x growth),
exactly as today.
"""

import math

DATA_WIDTH    = 40
TWIDDLE_WIDTH = 16
TWIDDLE_FRAC  = TWIDDLE_WIDTH - 2          # Q1.14 -> 14 fractional bits
TWIDDLE_SCALE = 1 << TWIDDLE_FRAC          # 16384


def wrap(x, width=DATA_WIDTH):
    """Two's-complement wrap to `width` bits (models VHDL signed truncation)."""
    mask = (1 << width) - 1
    x &= mask
    if x & (1 << (width - 1)):
        x -= (1 << width)
    return x


def make_twiddles(n):
    """Twiddle ROM, k = 0 .. N/2-1, Q1.14.  W_N^k = cos - j*sin."""
    rom = []
    for k in range(n // 2):
        angle = 2.0 * math.pi * k / n
        re = round(math.cos(angle) * (TWIDDLE_SCALE - 1))    # round-to-nearest
        im = round(-math.sin(angle) * (TWIDDLE_SCALE - 1))
        rom.append((wrap(re, TWIDDLE_WIDTH), wrap(im, TWIDDLE_WIDTH)))
    return rom


def butterfly(a, b, tw):
    """DIF radix-2 butterfly.  a, b, tw are (re, im) int tuples.

    out_a = a + b                 (no twiddle)
    out_b = ((a - b) * tw) >> 14  (truncating un-scale of the Q1.14 product)
    """
    ar, ai = a
    br, bi = b
    twr, twi = tw

    sum_re = wrap(ar + br)                 # sum half, untwiddled
    sum_im = wrap(ai + bi)

    diff_re = wrap(ar - br)                # diff held at 40 bits, like the RTL
    diff_im = wrap(ai - bi)

    prod_re = diff_re * twr - diff_im * twi    # full-precision complex multiply
    prod_im = diff_re * twi + diff_im * twr

    out_b_re = wrap(prod_re >> TWIDDLE_FRAC)   # floor-shift then wrap to 40 bits
    out_b_im = wrap(prod_im >> TWIDDLE_FRAC)

    return (sum_re, sum_im), (out_b_re, out_b_im)


def bit_reverse(i, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (i & 1)
        i >>= 1
    return r


def fft_fixed(x):
    """Fixed-point radix-2 DIF FFT.

    x : list of (re, im) int tuples, length N (a power of 2).
    returns : list of N (re, im) int tuples in NATURAL frequency order.

    This is the bit-exact reference.  The DIF butterfly schedule matches
    fft_n_pt.vhd p_addr exactly (half_size / group / pair / twiddle index).
    """
    n = len(x)
    log2n = n.bit_length() - 1
    assert (1 << log2n) == n, "N must be a power of 2"

    rom = make_twiddles(n)
    buf = [(wrap(re), wrap(im)) for (re, im) in x]      # natural-order load

    for s in range(log2n):                              # DIF stages
        hs = (n // 2) >> s                              # half_size
        nxt = list(buf)
        for k in range(n // 2):                         # butterflies in stage s
            grp   = k >> (log2n - 1 - s)
            pair  = k % hs
            idx_a = grp * (2 * hs) + pair
            idx_b = idx_a + hs
            tw_i  = pair * (1 << s)
            out_a, out_b = butterfly(buf[idx_a], buf[idx_b], rom[tw_i])
            nxt[idx_a] = out_a
            nxt[idx_b] = out_b
        buf = nxt

    out = [None] * n                                    # bit-reversed -> natural
    for i in range(n):
        out[bit_reverse(i, log2n)] = buf[i]
    return out


# ---------------------------------------------------------------------------
# Self-test / verification reference.  Run:  python3 r2sdf_fft_model.py
# ---------------------------------------------------------------------------
def _selftest():
    import numpy as np

    n = 64
    log2n = 6

    # 1. DC: bin 0 is the exact sum, every other bin is 0 (no truncation loss
    #    on a DC input because every difference is zero).
    c = 1000
    y = fft_fixed([(c, 0)] * n)
    assert y[0] == (n * c, 0), f"DC bin0 {y[0]} != {(n*c, 0)}"
    assert all(y[b] == (0, 0) for b in range(1, n)), "DC: nonzero off-bins"

    # 2. Complex tone at bin m -> spectral peak at bin m.
    m = 9
    A = 1 << 20
    x = [(round(A * math.cos(2 * math.pi * m * t / n)),
          round(A * math.sin(2 * math.pi * m * t / n))) for t in range(n)]
    y = fft_fixed(x)
    mags = [r * r + i * i for (r, i) in y]
    peak = max(range(n), key=lambda b: mags[b])
    assert peak == m, f"tone peak at bin {peak}, expected {m}"

    # 3. Cross-check against the unscaled float DFT: small relative error.
    xc = np.array([r + 1j * i for (r, i) in x])
    Yf = np.fft.fft(xc)
    Yfix = np.array([r + 1j * i for (r, i) in y])
    rel = np.abs(Yfix - Yf) / np.abs(Yf).max()
    assert rel.max() < 2e-3, f"max rel err {rel.max():.2e} too high"

    # 4. Determinism.
    assert fft_fixed(x) == y

    print("self-test OK")
    print(f"  DC   : bin0 = {n * c} exact, off-bins all zero")
    print(f"  tone : injected bin {m}, measured peak bin {peak}, "
          f"|peak| ~ {math.isqrt(mags[m])}  (ideal N*A = {n * A})")
    print(f"  float cross-check : max relative error = {rel.max():.2e}")
    print(f"  N = {n}, {log2n} stages, datapath {DATA_WIDTH}b, "
          f"twiddle {TWIDDLE_WIDTH}b Q1.{TWIDDLE_FRAC}")


if __name__ == "__main__":
    _selftest()
