#!/usr/bin/env python3
# Seam-B diagnostic for frame_sync_detector_soft -> opv-decode -3.
# Inputs:
#   /tmp/seam_soft.s16   int16 soft, one per symbol (opv-mod -B N | opv-demod -s -c -q -X ...)
#   /tmp/seam_out.txt    captured m_axis_soft_bit codes (0..7), one per line, from the GHDL TB
#   /tmp/seam_golden.bin golden frames (opv-decode -q -r < seam_soft.s16)
# Usage: seam_diag.py /path/to/opv-decode
import sys, numpy as np, subprocess, re
dec = sys.argv[1]
a = np.fromfile('/tmp/seam_soft.s16', dtype='<i2').astype(int)
def vhdl_q(s):                       # exact frame_sync_detector_soft quantize() (-12 dBFS thresholds)
    if s < -2800: return 7
    if s < -1400: return 5
    if s < -500:  return 4
    if s <  500:  return 3
    if s < 1400:  return 2
    if s < 2800:  return 1
    return 0
N = 2144
golden = open('/tmp/seam_golden.bin','rb').read()
gset = {golden[i*134:(i+1)*134] for i in range(len(golden)//134)}
def dec3(codes):
    p = subprocess.run([dec,'-3','-r'], input=bytes(c & 0xFF for c in codes), capture_output=True)
    pf = re.search(rb'(\d+) perfect', p.stderr)
    return (int(pf.group(1)) if pf else 0), p.stdout
# 1) contract check: VHDL-quantized RAW soft must decode at the true payload offset
starts = [o for o in range(0, len(a)-N) if dec3([vhdl_q(int(x)) for x in a[o:o+N]])[0] >= 1]
print("contract: true payload offsets that decode perfect:", starts)
# 2) localize captured-stream offset vs the true windows
cap = [int(x) for x in open('/tmp/seam_out.txt')]
caps = [cap[i*N:(i+1)*N] for i in range(len(cap)//N)]
exp = {o: [vhdl_q(int(x)) for x in a[o:o+N]] for o in starts}
for ci, c in enumerate(caps):
    best = (None, 0, 0)
    for o in exp:
        for sh in range(-30, 31):
            m = sum(1 for i in range(N) if 0 <= i+sh < N and c[i] == exp[o][i+sh])
            if m > best[2]: best = (o, sh, m)
    print(f"cap{ci}: best exp@{best[0]} shift {best[1]} -> {best[2]}/{N} ({100*best[2]//N}%)")
# 3) realign by the measured offset and decode
SH = 11
c = cap[SH:]; c = c[:(len(c)//N)*N]
p, d = dec3(c)
nd = len(d)//134
hits = sum(1 for i in range(nd) if d[i*134:(i+1)*134] in gset)
print(f"realigned by {SH}: frames={nd} perfect={p} byte-identical-to-golden={hits}/{nd}")
