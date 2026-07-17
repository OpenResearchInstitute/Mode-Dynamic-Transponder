#!/usr/bin/env python3
"""10 Msps stimuli for tb_core_tone: +/-791.25 kHz (channel 5 center +/-10 kHz).
Dependency-free (math only) -- safe under Vivado's bundled python."""
import math
fs, n, amp = 10e6, 8192, 9000.0
for name, f in [("tone_p.txt", 791250.0), ("tone_m.txt", -791250.0)]:
    with open(name, "w") as fh:
        for k in range(n):
            ph = 2.0 * math.pi * f * k / fs
            fh.write(f"{int(round(amp*math.cos(ph)))} {int(round(amp*math.sin(ph)))}\n")
    print(f"wrote {name}: f={f:+.1f} Hz, {n} samples at 10 Msps")
