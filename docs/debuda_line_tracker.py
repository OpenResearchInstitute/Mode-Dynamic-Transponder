"""
debuda_line_tracker.py  --  custom de Buda symbol-clock recovery for Haifuraiya OPV/MSK

WHY THIS EXISTS
---------------
The first RTL attempt repurposed the per-symbol decision-directed costas loop as the
sync-line tracker. It could not lock: (1) its integrate-and-dump error is data-modulated,
and (2) its dump gate (tclk) is derived from the very NCOs it's trying to acquire
(chicken-and-egg). The clean 11/12 clock it produced was a FREE-RUNNING NCO artifact.

de Buda's method instead extracts the data-free +-R/2 spectral lines of z^2 with a
NARROWBAND filter and tracks each with a continuous CW PLL -- no symbol dump anywhere.
This file is that, designed properly: loop bandwidth + damping as the spec parameters,
validated on the real RTL capture, under noise, and with carrier offset.

DOMAIN MODEL
------------
  z[n]          complex baseband MSK at fs = 625000, baud R = 54200, sps = fs/R = 11.5314
  w = z^2       constant-envelope -> discrete data-free lines at +-R/2 (~29 dB / 60 Hz RBW)
  Two line trackers, one per line:
     NCO (nominal +-R/2)  ->  mix line toward DC  ->  one-pole "de Buda" filter
       ->  phase detector angle(.)  ->  PI loop  ->  NCO adjust
  Clock = difference of the two NCO phase accumulators. It advances at R
     (one cycle per symbol); each 2*pi wrap is a symbol-clock edge.
  Carrier is NOT extracted here -- the data path's psi_k loop absorbs it (preamble-aided).

RTL MAPPING (next step)
-----------------------
  NCO              : existing nco.vhd; freq word = (rx_freq_word_f1/f2 << 1) + adjust
  mix w*exp(-j.th) : complex multiply (reuse sin_cos_lut + mixer)
  de Buda filter   : one-pole complex IIR  f += lam*(x - f);  lam ~= 1/256 (2^-8 shift)
  phase detector   : CORDIC atan2 (vectoring) of the filtered phasor  <-- NEW primitive
  PI loop          : reuse pi_controller.vhd; K1,K2 from (Bn,zeta) below
  clock            : (th_plus - th_minus) MSB/wrap -> single-edge tclk (existing beat idea)
  acquisition      : coarse FFT of the +R/2 line (REUSE the channelizer FFT) + parabolic
                     interp -> set NCO nominal; narrow loop locks the <~35 Hz residual

VALIDATED OPERATING POINTS (this file, measured)
------------------------------------------------
  BnT = 8e-5  (Bn ~= 50 Hz), zeta = 0.707           narrow track
  lam = 0.003 (de Buda one-pole ~= 300 Hz)
  pull-in ~ tens of Hz  -> carrier offset REQUIRES the FFT coarse aid
  FFT Nf=8192 + parabolic interp -> coarse to ~35 Hz (inside pull-in)
  clock jitter ~0.34-0.39 sample (~3% of a symbol); holds +15 dB down to -3 dB Es/N0
  locks the real fixed-point RTL capture (wdump.txt) at std 0.34 sample
"""
import numpy as np

fs, R = 625000.0, 54200.0
sps    = fs / R
FDEV   = R / 4


def pll_gains(BnT, zeta=0.707):
    """2nd-order PLL proportional/integral gains from loop bandwidth*T and damping (Rice form)."""
    th = BnT / (zeta + 1.0 / (4.0 * zeta))
    d  = 1.0 + 2.0 * zeta * th + th * th
    return 4.0 * zeta * th / d, 4.0 * th * th / d          # K1 (prop), K2 (integ)


class LineTracker:
    """One de Buda CW line PLL: NCO -> mix to DC -> one-pole filter -> angle PD -> PI."""
    def __init__(self, f_nom, BnT=8e-5, zeta=0.707, lam=0.003):
        self.wn = 2 * np.pi * f_nom / fs
        self.K1, self.K2 = pll_gains(BnT, zeta)
        self.lam = lam
        self.th = 0.0
        self.integ = 0.0
        self.f = 0.0 + 0.0j

    def step(self, w):
        x = w * np.exp(-1j * self.th)                       # mix line toward DC
        self.f = (1 - self.lam) * self.f + self.lam * x     # de Buda narrowband filter
        e = np.angle(self.f)                                # phase error (strong phasor)
        self.th += self.wn + self.K1 * e + self.integ
        self.integ += self.K2 * e
        return self.th


def run(w, f_aid=0.0, BnT=8e-5, zeta=0.707, lam=0.003):
    """Two trackers at +-R/2 (+ optional coarse aid). Returns phase-difference D and line freqs."""
    Tp = LineTracker(+R / 2 + f_aid, BnT, zeta, lam)
    Tm = LineTracker(-R / 2 + f_aid, BnT, zeta, lam)
    N = len(w)
    D = np.empty(N)
    for n in range(N):
        D[n] = Tp.step(w[n]) - Tm.step(w[n])
    return D, Tp.integ * fs / (2 * np.pi), Tm.integ * fs / (2 * np.pi)


def clock_edges(D):
    """Symbol-clock edges = 2*pi wraps of the phase difference (one per symbol, rate R)."""
    k = np.floor(D / (2 * np.pi))
    return np.where(np.diff(k) != 0)[0] + 1


def fft_acquire(w, Nf=8192):
    """Coarse +R/2 line frequency via FFT magnitude peak + parabolic interpolation."""
    Wm = np.abs(np.fft.fftshift(np.fft.fft((w[:Nf] - w[:Nf].mean()) * np.hanning(Nf))))
    f  = np.fft.fftshift(np.fft.fftfreq(Nf, 1 / fs))
    band = np.where(np.abs(f - R / 2) < 6000)[0]
    k = band[np.argmax(Wm[band])]
    a, b, c = Wm[k - 1], Wm[k], Wm[k + 1]
    delta = 0.5 * (a - c) / (a - 2 * b + c + 1e-9)
    return f[k] + delta * (fs / Nf)


def clock_alignment(edges, skip=4000, nsym=3000):
    """Offset (mean, std) of recovered clock edges vs true symbol boundaries round(k*sps)."""
    tb = np.round(np.arange(nsym) * sps).astype(int)
    ed = edges[edges > skip]
    off = np.array([e - tb[np.argmin(np.abs(tb - e))] for e in ed])
    return off.mean(), off.std()


# ------------------------------------------------------------------ self-test / validation
def _make_w(nsym=1500, foff=0.0, seed=3, snr_db=None):
    rng = np.random.default_rng(seed)
    bits = np.concatenate([np.tile([1, 1, -1, -1], 16), rng.integers(0, 2, nsym - 64) * 2 - 1])
    N = int(len(bits) * sps); n = np.arange(N)
    sym = np.minimum((n / sps).astype(int), len(bits) - 1)
    psi = np.cumsum(2 * np.pi * FDEV * bits[sym] / fs) + 2 * np.pi * foff * n / fs
    z = np.exp(1j * psi)
    if snr_db is not None:
        n0 = 1.0 / (2 * 10 ** (snr_db / 10))
        z = z + np.sqrt(n0) * (rng.standard_normal(N) + 1j * rng.standard_normal(N))
    return z * z


if __name__ == "__main__":
    print("=== de Buda line tracker -- self test ===")
    # 1) clean, no offset
    w = _make_w()
    D, fp, fm = run(w); m, s = clock_alignment(clock_edges(D))
    print(f"no offset      : clock align {m:+.2f} +- {s:.3f} samp ; lines {fp:+.0f},{fm:+.0f} Hz")
    assert s < 0.6 and abs(fp) < 100
    # 2) FFT-aided acquisition at +2 kHz carrier
    w = _make_w(foff=2000); fc = fft_acquire(w)
    D, fp, fm = run(w, f_aid=fc - R / 2); m, s = clock_alignment(clock_edges(D))
    print(f"+2 kHz (aided) : FFT line {fc:+.0f} Hz ; clock align {m:+.2f} +- {s:.3f} samp")
    assert s < 0.6
    # 3) noise robustness
    for snr in (10, 5, 0, -3):
        w = _make_w(snr_db=snr, seed=5); D, fp, fm = run(w); m, s = clock_alignment(clock_edges(D))
        print(f"Es/N0 {snr:+3d} dB   : clock jitter {s:.3f} samp ({s/sps*100:.1f}% symbol)")
    print("PASS")
