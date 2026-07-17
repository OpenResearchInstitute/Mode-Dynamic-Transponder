#!/usr/bin/env python3
"""gen_opv20_stim.py -- OPV BERT stimulus at 20 Msps in channel 5, as
"I Q" text for tb_chain_opv (and for golden_channelizer.py cross-checks).

Runs opv-mod and opv-resample from your opv-cxx-demod build, mixes the
2.168 Msps complex baseband up to +781.25 kHz (channel 5 center), scales to
rms 9000, and writes opv20_stim.txt. Run from a normal shell (needs numpy).

Usage: python3 gen_opv20_stim.py [--bin ../path/to/opv-cxx-demod/bin]
                                 [--frames 10] [--call W5NYV]
"""
import argparse, subprocess, numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--bin", default="../../opv-cxx-demod/bin")
ap.add_argument("--frames", type=int, default=10)
ap.add_argument("--call", default="W5NYV")
ap.add_argument("--out", default="opv20_stim.txt")
a = ap.parse_args()

mod = subprocess.run([f"{a.bin}/opv-mod", "-S", a.call, "-P", "-B", str(a.frames)],
                     capture_output=True, check=True)
res = subprocess.run([f"{a.bin}/opv-resample", "2168000", "20000000"],
                     input=mod.stdout, capture_output=True, check=True)
d = np.frombuffer(res.stdout, dtype=np.int16).astype(np.float64)
x = d[0::2] + 1j * d[1::2]
n = np.arange(len(x))
y = x * np.exp(2j * np.pi * 781250.0 * n / 20e6)      # place in channel 5
y *= 9000.0 / np.sqrt(np.mean(np.abs(y) ** 2))
yi = np.clip(np.round(y.real), -32768, 32767).astype(int)
yq = np.clip(np.round(y.imag), -32768, 32767).astype(int)
with open(a.out, "w") as fh:
    fh.write("\n".join(f"{i} {q}" for i, q in zip(yi, yq)) + "\n")
print(f"wrote {a.out}: {len(yi)} samples at 20 Msps "
      f"({len(yi)/20e6:.3f} s, preamble + {a.frames} BERT frames, ch5)")
