# Run this on the output of the simulation to get a spectrum of a single channel 

import numpy as np
d = np.loadtxt('chan0_iq.txt')
x = d[:,0] + 1j*d[:,1]
N = len(x)
X = np.fft.fftshift(np.fft.fft(x*np.hanning(N)))
fn = np.fft.fftshift(np.fft.fftfreq(N))
P = np.abs(X)**2
P[N//2-1:N//2+2] = 0           # null DC offset so it can't bias the centroid

centroid = np.sum(fn*P)/np.sum(P)
print(f"samples: {N}")
print(f"power centroid (carrier): {centroid:+.5f} cyc/sample")

IF_HZ, FDEV = 27100.0, 13550.0
rate = IF_HZ/centroid
print(f"implied channel rate: {rate/1e3:.2f} kHz   (625 means M=16, 156 means ~64)")
for name, f in [('f1', IF_HZ-FDEV), ('f2', IF_HZ+FDEV)]:
    nf = f/rate
    word = int(round((nf % 1.0)*2**32)) & 0xFFFFFFFF
    print(f"  {name} {f:+.0f} Hz -> {nf:+.5f} cyc/sample -> 0x{word:08X}")

try:
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    plt.figure(figsize=(9,4))
    plt.plot(fn, 10*np.log10(P/P.max()+1e-12))
    plt.axvline(centroid, color='r', ls='--', label=f'carrier {centroid:+.4f}')
    plt.xlabel('cycles/sample'); plt.ylabel('dB'); plt.grid(True); plt.legend()
    plt.savefig('chan0_spectrum.png', dpi=110, bbox_inches='tight')
    print("wrote chan0_spectrum.png")
except Exception as e:
    print("(no plot:", e, ")")
