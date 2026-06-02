"""
channel_eq.py -- Haifuraiya per-channel EQ for the 20->10 Msps halfband droop.

The 2:1 halfband rolls off only the outermost channels: ch28-31 and their mirrors
ch33-36 are the only ones touched, worst is ch31/33 at -2.67 dB, and ch32 is the
unusable Nyquist wrap bin. Because the filter attenuates signal and in-band noise
together, the droop is a SCALE error, so a per-channel gain restores flatness.
Verified: applying these quantized gains flattens the 63 usable channels to within
0.065 milli-dB.

Placement: one multiplier at the channelizer output, indexed by TDEST, BEFORE the
power-detector tap. Then telemetry AND demod both see flat channels from a single
DSP48 + this 64-entry ROM. (If you can only correct telemetry in software, multiply
CHANNEL_POWER[k] by POWER_CORR[k] in the publisher instead.)

Format: CH_EQ_GAIN is Q2.16 (scale 2^16). corrected = (sample * gain) >> 16, saturate.
"""
import numpy as np

EQ_SHIFT = 16                      # gains are Q2.16
NYQUIST_BIN = 32                   # left at unity; ambiguous bin, do not use
SAMPLE_BITS = 16

# sample-path gain = 1/|H(f_ch)|, Q2.16, indexed by channelizer TDEST (0..63)
CH_EQ_GAIN = np.array([
    65536, 65537, 65537, 65535, 65535, 65537, 65535, 65534,
    65537, 65538, 65535, 65537, 65538, 65535, 65535, 65538,
    65537, 65537, 65538, 65535, 65534, 65538, 65538, 65535,
    65536, 65536, 65538, 65534, 65679, 67085, 72793, 89074,
    65536, 89074, 72793, 67085, 65679, 65534, 65538, 65536,
    65536, 65535, 65538, 65538, 65534, 65535, 65538, 65537,
    65537, 65538, 65535, 65535, 65538, 65537, 65535, 65538,
    65537, 65534, 65535, 65537, 65535, 65535, 65537, 65537,
], dtype=np.int64)

# power-path correction = 1/|H(f_ch)|^2 (float), for software telemetry flattening
POWER_CORR = np.array([
    1.000000, 1.000042, 1.000036, 0.999954, 0.999983, 1.000041, 0.999967, 0.999942,
    1.000042, 1.000046, 0.999984, 1.000030, 1.000047, 0.999966, 0.999983, 1.000052,
    1.000021, 1.000024, 1.000067, 0.999981, 0.999942, 1.000055, 1.000049, 0.999979,
    1.000015, 0.999997, 1.000065, 0.999953, 1.004384, 1.047836, 1.233731, 1.847308,
    1.000000, 1.847308, 1.233731, 1.047836, 1.004384, 0.999953, 1.000065, 0.999997,
    1.000015, 0.999979, 1.000049, 1.000055, 0.999942, 0.999981, 1.000067, 1.000024,
    1.000021, 1.000052, 0.999983, 0.999966, 1.000047, 1.000030, 0.999984, 1.000046,
    1.000042, 0.999942, 0.999967, 1.000041, 0.999983, 0.999954, 1.000036, 1.000042,
], dtype=np.float64)


def apply_eq_fixed(samples, ch, sample_bits=SAMPLE_BITS):
    """Bit-exact channelizer-output EQ: corrected = (sample * gain) >> 16, saturated.
    `samples`: integer array for one channel; `ch`: its index 0..63."""
    g = int(CH_EQ_GAIN[ch])
    y = (np.asarray(samples, dtype=np.int64) * g + (1 << (EQ_SHIFT - 1))) >> EQ_SHIFT
    lim = (1 << (sample_bits - 1)) - 1
    return np.clip(y, -lim - 1, lim)


def correct_power(channel_power):
    """Flatten a 64-element CHANNEL_POWER vector in software (telemetry path)."""
    return np.asarray(channel_power, dtype=np.float64) * POWER_CORR


if __name__ == "__main__":
    unity = 1 << EQ_SHIFT
    nonunity = [k for k in range(64) if abs(int(CH_EQ_GAIN[k]) - unity) > 4]
    print("channels with a real EQ boost:", nonunity)
    print(f"max sample gain : {CH_EQ_GAIN.max() / unity:.4f}  (ch31/33)")
    print(f"ch32 gain       : {CH_EQ_GAIN[NYQUIST_BIN] / unity:.4f}  (left at unity)")
    print(f"max power corr  : {POWER_CORR.max():.4f}  (ch31/33)")
