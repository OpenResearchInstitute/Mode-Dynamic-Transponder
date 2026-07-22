#!/bin/bash
# End-to-end decode-oracle pipeline, golden-model edition.
# Requires: opv-cxx-demod built (bin/opv-mod, bin/opv-resample, bin/opv-demod),
# numpy, and haifuraiya_coeffs_pkg.vhd next to golden_channelizer.py.
set -e
BIN=${OPV_BIN:-../opv-cxx-demod/bin}
FRAMES=${FRAMES:-10}
$BIN/opv-mod -S W5NYV -P -B $FRAMES > opv_2168k.cs16 2>/dev/null
$BIN/opv-resample 2168000 20000000 < opv_2168k.cs16 > opv_20m.cs16 2>/dev/null
python3 - <<'PYEOF'
import numpy as np, importlib.util
spec = importlib.util.spec_from_file_location("g", "golden_channelizer.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
C = g.load_coeffs("haifuraiya_coeffs_pkg.vhd")
d = np.fromfile("opv_20m.cs16", dtype=np.int16).astype(np.float64)
x = d[0::2] + 1j*d[1::2]
n = np.arange(len(x))
y = x*np.exp(2j*np.pi*781250.0*n/20e6)          # place in channel 5
y *= 9000.0/np.sqrt(np.mean(np.abs(y)**2))
yi = np.clip(np.round(y.real),-32768,32767).astype(np.int64)
yq = np.clip(np.round(y.imag),-32768,32767).astype(np.int64)
hi, hq = g.halfband_model(yi, yq)                # 20M -> 10M, bit-exact
beats  = g.core_model(hi, hq, C)                 # channelizer, bit-exact
m = beats[:,0] == 59                             # raw bin 59 = channel 5
ch = beats[m][:,1] + 1j*beats[m][:,2]
s = 9000.0/np.sqrt(np.mean(np.abs(ch)**2))
ci = np.clip(np.round(ch.real*s),-32768,32767).astype(np.int16)
cq = np.clip(np.round(ch.imag*s),-32768,32767).astype(np.int16)
out = np.empty(2*len(ci), dtype=np.int16); out[0::2]=ci; out[1::2]=cq
out.tofile("chan5_iq.cs16")
print(f"chan5_iq.cs16: {len(ci)} samples at 625k")
PYEOF
$BIN/opv-demod -c -R 625000 < chan5_iq.cs16
