#!/usr/bin/env python3
"""pipeline_fftresample.py -- chan5 decode-oracle pipeline with the
2168000 -> 20000000 upsample done by exact FFT resampling in numpy,
bypassing opv-resample entirely. Everything else identical to
run_decode_pipeline.sh. Purpose: isolate whether the opv-resample
upsample path is the stage corrupting the keroppi chan5 stimulus.

Usage:  OPV_BIN=~/stim/opv-cxx-demod/bin python3 pipeline_fftresample.py
Needs:  golden_channelizer.py + haifuraiya_coeffs_pkg.vhd in cwd, numpy.
Output: chan5_fft.cs16  ->  decode with:
        python3 opv_demod_model.py chan5_fft.cs16
        $OPV_BIN/opv-demod -c -R 625000 < chan5_fft.cs16
"""
import os, subprocess, numpy as np, importlib.util

BIN = os.environ.get("OPV_BIN", "../opv-cxx-demod/bin")
FRAMES = int(os.environ.get("FRAMES", "10"))

mod = subprocess.run([f"{BIN}/opv-mod", "-S", "W5NYV", "-P", "-B", str(FRAMES)],
                     capture_output=True, check=True)
d = np.frombuffer(mod.stdout, dtype=np.int16).astype(np.float64)
x = d[0::2] + 1j*d[1::2]
print(f"opv-mod: {len(x)} samples at 2.168 Msps")

# exact rational FFT resample 2168000 -> 20000000 (ratio 2500/271)
UP, DOWN = 2500, 271
PAD = 2168 * 4                             # ~4 symbols of zeros, kills FFT
x = np.concatenate([np.zeros(PAD), x, np.zeros(PAD)])   # circular wraparound
n_in = (len(x) // DOWN) * DOWN            # crop to a multiple of 271
x = x[:n_in]
n_out = n_in * UP // DOWN
X = np.fft.fft(x)
Y = np.zeros(n_out, dtype=complex)
h = n_in // 2
Y[:h] = X[:h]
Y[-h:] = X[-h:]
y = np.fft.ifft(Y) * (n_out / n_in)
print(f"fft resample: {n_in} -> {n_out} samples at 20 Msps (exact 2500/271)")

n = np.arange(len(y))
y = y * np.exp(2j*np.pi*781250.0*n/20e6)
y *= 9000.0 / np.sqrt(np.mean(np.abs(y)**2))
yi = np.clip(np.round(y.real), -32768, 32767).astype(np.int64)
yq = np.clip(np.round(y.imag), -32768, 32767).astype(np.int64)

spec = importlib.util.spec_from_file_location("g", "golden_channelizer.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
C = g.load_coeffs("haifuraiya_coeffs_pkg.vhd")
hi, hq = g.halfband_model(yi, yq)
beats = g.core_model(hi, hq, C)
m = beats[:, 0] == 59
ch = beats[m][:, 1] + 1j*beats[m][:, 2]
s = 9000.0/np.sqrt(np.mean(np.abs(ch)**2))
ci = np.clip(np.round(ch.real*s), -32768, 32767).astype(np.int16)
cq = np.clip(np.round(ch.imag*s), -32768, 32767).astype(np.int16)
out = np.empty(2*len(ci), dtype=np.int16); out[0::2] = ci; out[1::2] = cq
out.tofile("chan5_fft.cs16")
print(f"chan5_fft.cs16: {len(ci)} samples at 625k")
