#!/usr/bin/env python3
"""20 Msps stimuli for tb_chain_tone: signal, alias probe, alias reference.
Dependency-free (math only) so it runs under any python, including the
libffi-broken numpy in Vivado 2022.2's bundled python 3.8."""
import math
fs, n, amp = 20e6, 8192, 9000.0
for name, f in [("tone20_p.txt", 791250.0),
                ("tone20_alias.txt", 5156250.0 + 10000.0),
                ("tone20_ref33.txt", -4843750.0 - 10000.0)]:
    with open(name, "w") as fh:
        for k in range(n):
            ph = 2.0 * math.pi * f * k / fs
            i = int(round(amp * math.cos(ph)))
            q = int(round(amp * math.sin(ph)))
            fh.write(f"{i} {q}\n")
    print(f"wrote {name}: f={f:+.1f} Hz, {n} samples at 20 Msps")
