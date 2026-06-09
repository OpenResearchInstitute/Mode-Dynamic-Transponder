# Not the right tool for the job, but used to FFT the results from a single channel

import numpy as np
d = np.loadtxt('chan0_iq.txt')
x = (d[:,0] + 1j*d[:,1]) * np.hanning(len(d))
X = np.fft.fftshift(np.fft.fft(x)); fn = np.fft.fftshift(np.fft.fftfreq(len(x)))
mag = np.abs(X); peaks=[]
for i in np.argsort(mag)[::-1]:
    if all(abs(fn[i]-p) > 0.005 for p in peaks):
        peaks.append(fn[i])
        print(f"peak {fn[i]:+.5f} cyc/sample -> freq_word 0x{int(round((fn[i]%1.0)*2**32))&0xFFFFFFFF:08X}")
    if len(peaks) >= 4: break
