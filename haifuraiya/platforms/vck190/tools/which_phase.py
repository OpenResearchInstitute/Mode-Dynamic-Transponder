#!/usr/bin/env python3
# which_phase.py STIM COEFFS_PKG channel_iq.txt [channel_iq2.txt ...]
# Runs the golden channelizer model (designed halfband phase: 0-based odd inputs,
# and the other phase) on the first part of the stimulus, extracts channel 5,
# and reports the complex ratio of each captured channel_iq against both.
# The capture is after real gains (quantizer, eq, normalizer), so only the
# ANGLE is meaningful: ~0 deg = that capture used that phase.
import sys, numpy as np
sys.path.insert(0, __import__('os').getcwd())   # run from haifuraiya/sim
import golden_channelizer as G
NIN = 400_000                                   # input samples to model (enough for ~12k channel samples)
stim = np.loadtxt(sys.argv[1], dtype=np.int64, max_rows=NIN)
C = G.load_coeffs(sys.argv[2])
def chan(phase, idx):
    xi, xq = stim[:,0], stim[:,1]
    def lane(x):
        acc = np.convolve(x, G.HB_TAPS)[:len(x)]
        acc = acc[phase::2]                      # phase 1 = designed (odd), 0 = even
        return np.clip((acc + (1<<16)) >> 17, -32768, 32767)
    beats = G.core_model(lane(xi), lane(xq), C)
    b = beats[beats[:,0] == idx]
    return b[:,1] + 1j*b[:,2]
def unit(z):
    a = np.abs(z); a[a == 0] = 1; return z / a
# the AXI wrapper relabels channel k as (64-k) mod 64, so the bench's channel 5 is model idx 59
IDX = [59, 5]
m = {(ph, ix): chan(ph, ix) for ph in (1, 0) for ix in IDX}
r01 = np.vdot(m[(1,59)][100:3000], m[(0,59)][100:3000]) / np.vdot(m[(1,59)][100:3000], m[(1,59)][100:3000])
print("model: even-phase vs designed(odd)-phase angle = %+.1f deg (expect ~ +/-14.06)" % np.degrees(np.angle(r01)))
for f in sys.argv[3:]:
    c = np.loadtxt(f, dtype=np.int64, max_rows=20000); z = unit(c[:,0] + 1j*c[:,1])
    for ix in IDX:
        for ph in (1, 0):
            mm = unit(m[(ph, ix)])
            a = mm[:6000]; b = z[:6000]
            xc = np.correlate(b, a, mode='full'); lag = int(np.argmax(np.abs(xc))) - (len(a) - 1)
            if lag >= 0: x, y = mm[:5000], z[lag:lag+5000]
            else:        x, y = mm[-lag:-lag+5000], z[:5000]
            n = min(len(x), len(y)); x, y = x[:n], y[:n]
            r = np.vdot(x, y) / np.vdot(x, x)
            res = np.sum(np.abs(y - r*x)**2) / np.sum(np.abs(y)**2)
            print("  %-48s model idx %2d %s-phase: lag %+5d  angle %+6.1f deg  residual %5.1f%%" %
                  (f[-48:], ix, "designed(odd)" if ph else "even         ", lag, np.degrees(np.angle(r)), 100*res))
