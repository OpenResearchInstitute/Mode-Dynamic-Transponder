import numpy as np
d = np.loadtxt("opv_chan_stim_dc.txt")
z = d[:,0] + 1j*d[:,1]
N = len(z); fs = 20e6
Z = np.fft.fftshift(np.fft.fft(z * np.hanning(N)))
f = np.fft.fftshift(np.fft.fftfreq(N, 1/fs)) / 1e3      # kHz
mag = 20*np.log10(np.abs(Z) + 1)
print(f"N={N}, resolution {fs/N/1e3:.3f} kHz/bin\n")
for name, fc in [("ch5 center", 781.25), ("upper tone", 794.80),
                 ("lower tone", 767.70), ("baseband 0", 0.0)]:
    i = np.argmin(np.abs(f - fc))
    j = i - 60 + int(np.argmax(mag[i-60:i+60]))
    print(f"{name:11s} ~{fc:8.2f} kHz -> peak {f[j]:9.3f} kHz @ {mag[j]:6.1f} dB")
print("\nstrongest lines overall:")
for i in np.argsort(mag)[-8:][::-1]:
    print(f"  {f[i]:9.2f} kHz  {mag[i]:6.1f} dB")
