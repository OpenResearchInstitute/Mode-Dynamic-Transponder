#!/usr/bin/env python3
# combine_model.py -- VALIDATED golden model of the 2-symbol (Massey 2T) MSK
# detection back-end, ported from opv_demod.hpp CoherentMSKDemodulator::combine()
# and checked 100% sign-for-sign against the C++ on real chan0_iq correlations.
# This is the reference the fabric back-end (in msk_demodulator.vhd) must match:
# it replaces the current per-symbol d1-d2 + decision-directed dph detection and
# recovers ~3 dB (the MSK 2-symbol observation gain).
import numpy as np

def detect_2T(Y1, Y2, parity=0):
    """Y1,Y2: per-symbol complex tone correlations (fabric c1r+jc1i, c2r+jc2i).
       Returns soft decisions (sign<0 -> bit). Latency ~2 symbols."""
    nsym=len(Y1)
    # --- residual Costas (Hodgart form): de-rotate -> imaginary data arms ---
    pll_a, pll_b = 0.01, 2e-4
    theta=0.0; freq=0.0
    X=np.zeros(nsym); Yv=np.zeros(nsym)
    for k in range(nsym):
        rot=complex(np.cos(theta), -np.sin(theta))
        y1=Y1[k]*rot; y2=Y2[k]*rot
        X[k]=y1.imag; Yv[k]=y2.imag                  # active tone -> imag axis
        act = y2 if (abs(y2)**2 > abs(y1)**2) else y1 # dominant tone
        err = -(act.real * (-1.0 if act.imag<0 else 1.0)) / (abs(act)+1e-9)
        freq  += pll_b*err
        theta += pll_a*err + freq
    # --- Massey 2T combine (two consecutive symbols) ---
    enc=np.zeros(nsym)
    for i in range(nsym-1):
        A = X[i]+X[i+1]; B = Yv[i]+Yv[i+1]
        sgn = 1.0 if ((i+parity)&1)==0 else -1.0
        enc[i] = A - sgn*B
    # --- soft differential decode (boxplus / min-sum) ---
    def boxplus(a,b):
        s = -1.0 if ((a<0)!=(b<0)) else 1.0
        return s*min(abs(a),abs(b))
    dec=np.zeros(nsym)
    for i in range(1,nsym): dec[i]=boxplus(enc[i], enc[i-1])
    return dec

if __name__=="__main__":
    io=np.loadtxt('/tmp/combine_io.txt'); ref=np.loadtxt('/tmp/combine_dec.txt')
    Y1=io[:,1]+1j*io[:,2]; Y2=io[:,3]+1j*io[:,4]
    dec=detect_2T(Y1,Y2,0)
    print("sign match to golden:", f"{np.mean(np.sign(dec)==np.sign(ref[:,2]))*100:.1f}%")
