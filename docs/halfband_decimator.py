"""
halfband_decimator.py -- Haifuraiya 2:1 halfband decimator (20 -> 10 Msps)

Golden reference for the FPGA implementation. The fixed-point path is
bit-exact to the intended VHDL: 16-bit I/Q in, signed 18-bit coefficients,
wide accumulator, round-half-up, arithmetic shift right by 17, saturate to 16-bit.

Design: equiripple (Parks-McClellan) forced to an exact halfband.
  fs_in = 20 MHz, fs_out = 10 MHz, transition 4.25-5.75 MHz (centered on fs/4)
  L = 75 taps, 39 nonzero, 19 unique multipliers after symmetry folding
  + the center tap (0.5) is a hardwired shift, not a multiply
  int18 stopband ~88 dB, passband ripple ~0.001 dB, exactly -6.02 dB at fs/4
  unity DC gain (coeff sum = 2^17)

Channel mapping it produces (verified): a tone at LO +/- k*156.25 kHz lands on
channelizer channel k (positive) or 64-k (negative). +1.25 MHz -> ch8, -1.25 -> ch56.
"""
import numpy as np

COEFF_BITS = 18
DATA_BITS  = 16
SHIFT      = COEFF_BITS - 1          # 17
CENTER     = 37
FS_IN      = 20_000_000

# signed 18-bit taps, scale 2^17 = 131072, unity DC gain
HB_TAPS = np.array([5, 0, -12, 0, 26, 0, -50, 0, 88, 0, -147, 0, 233, 0, -355, 0, 522, 0, -747, 0, 1047, 0, -1444, 0, 1970, 0, -2682, 0, 3681, 0, -5188, 0, 7776, 0, -13559, 0, 41604, 65536, 41604, 0, -13559, 0, 7776, 0, -5188, 0, 3681, 0, -2682, 0, 1970, 0, -1444, 0, 1047, 0, -747, 0, 522, 0, -355, 0, 233, 0, -147, 0, 88, 0, -50, 0, 26, 0, -12, 0, 5], dtype=np.int64)


def decimate_fixed(x_i, x_q, taps=HB_TAPS, out_bits=DATA_BITS):
    """Bit-exact 2:1 halfband decimation. Inputs are integer 16-bit I and Q.
    Returns (yi, yq) at half the input rate, group-delay aligned."""
    def filt(x):
        acc = np.convolve(np.asarray(x, dtype=np.int64), taps)
        y = (acc + (1 << (SHIFT - 1))) >> SHIFT      # round-half-up then >>17
        lim = (1 << (out_bits - 1)) - 1
        return np.clip(y, -lim - 1, lim)
    return filt(x_i)[CENTER::2], filt(x_q)[CENTER::2]


def decimate_float(x_i, x_q, taps=HB_TAPS):
    """Floating-point reference (no quantization), for comparison."""
    h = taps / (1 << SHIFT)
    yi = np.convolve(np.asarray(x_i, float), h)[CENTER::2]
    yq = np.convolve(np.asarray(x_q, float), h)[CENTER::2]
    return yi, yq


if __name__ == "__main__":
    # self-check: OPV offsets land on the right channelizer channels
    n = np.arange(40000)
    A = 0.5 * (2**(DATA_BITS - 1) - 1)
    def tone(f):
        p = 2*np.pi*f/FS_IN*n
        return np.round(A*np.cos(p)).astype(np.int64), np.round(A*np.sin(p)).astype(np.int64)
    def channel(yi, yq, N=64):
        z = yi.astype(float) + 1j*yq.astype(float)
        z = z[len(z)//4:3*len(z)//4]
        Z = np.abs(np.fft.fft(z*np.hanning(len(z)), 4096))
        f = np.fft.fftfreq(4096, d=2/FS_IN)
        return int(round(f[np.argmax(Z)]/((FS_IN/2)/N))) % N
    for f, exp in [(1.25e6, 8), (-1.25e6, 56), (0.0, 0), (2.5e6, 16)]:
        ch = channel(*decimate_fixed(*tone(f)))
        print(f"  {f/1e6:+5.2f} MHz -> ch {ch:2d}  (expected {exp})  {'OK' if ch==exp else 'FAIL'}")
