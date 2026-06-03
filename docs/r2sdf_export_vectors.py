#!/usr/bin/env python3
"""Export golden test vectors for tb_r2sdf_fft from the bit-exact model.
Frame 0 = DC (should peak at bin 0), frame 1 = tone at bin 9 (peak bin 9),
frames 2..7 = full-scale random (all-bin, full-dynamic-range coverage)."""
import math, random
from r2sdf_fft_model import fft_fixed
N, K = 64, 8
rng = random.Random(2025)
frames = []
frames.append([(1 << 16, 0) for _ in range(N)])                       # DC
k0 = 9
frames.append([(int(round((1 << 16) * math.cos(2*math.pi*k0*n/N))),
                int(round((1 << 16) * math.sin(2*math.pi*k0*n/N)))) for n in range(N)])
for _ in range(K - 2):
    frames.append([(rng.randint(-(1 << 17), 1 << 17),
                    rng.randint(-(1 << 17), 1 << 17)) for _ in range(N)])
with open('fft_input.txt', 'w') as fi, open('fft_expected.txt', 'w') as fe:
    for fidx, f in enumerate(frames):
        out = fft_fixed(f)
        for (re, im) in f:
            fi.write(f"{re} {im}\n")
        for (re, im) in out:
            fe.write(f"{re} {im}\n")
        mag = [r*r + i*i for (r, i) in out]
        peak = mag.index(max(mag))
        print(f"frame {fidx}: peak bin = {peak}")
