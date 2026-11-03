#!/usr/bin/env python3
"""opv_stim_txt2bin.py IN.txt OUT.bin -- opv_stim's text stimulus ("I Q" per line,
int16 each) to the packed binary opv_play streams: one 32-bit little-endian beat
per sample, I in the low half, Q in the high half (the AXIS convention
haifuraiya_channelizer_axi uses: tdata(15:0) = I, tdata(31:16) = Q)."""
import sys, numpy as np
if len(sys.argv) != 3:
    sys.exit(__doc__)
a = np.loadtxt(sys.argv[1], dtype=np.int64)
if a.ndim != 2 or a.shape[1] != 2:
    sys.exit("expected two columns (I Q) per line")
lo = (a[:, 0] & 0xFFFF).astype(np.uint32)
hi = (a[:, 1] & 0xFFFF).astype(np.uint32)
(lo | (hi << 16)).astype('<u4').tofile(sys.argv[2])
print(f"{len(a)} samples -> {sys.argv[2]} ({4*len(a)} bytes, {len(a)/20e6:.3f} s at 20 MSps)")
