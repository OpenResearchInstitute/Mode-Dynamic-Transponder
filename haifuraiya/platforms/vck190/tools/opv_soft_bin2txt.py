#!/usr/bin/env python3
"""opv_soft_bin2txt.py IN.bin OUT.txt -- opv_play's capture (one byte per soft bit,
0..7, frames back to back) to the grader's format (one value per line), i.e. the
same file the simulation bench writes as seam_chan_out.txt."""
import sys, numpy as np
if len(sys.argv) != 3:
    sys.exit(__doc__)
b = np.fromfile(sys.argv[1], dtype=np.uint8)
if (b > 7).any():
    print(f"warning: {(b > 7).sum()} values above 7 -- not a clean soft-bit capture", file=sys.stderr)
np.savetxt(sys.argv[2], b, fmt='%d')
print(f"{len(b)} soft bits = {len(b)/2144:.2f} frames -> {sys.argv[2]}")
