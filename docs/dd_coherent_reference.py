"""
Decision-Directed Coherent MSK Detector  --  golden reference for Haifuraiya RTL
================================================================================
Complex-baseband OPV/MSK receiver, post-channelizer (625 ksps/channel, R=54200 baud,
tones at +/- R/4 = +/- 13550 Hz).  This is the DATA branch.  The SYNC branch (de Buda
squarer + two PLLs on the +/- R/2 lines) supplies theta_c (carrier) and the symbol clock;
that branch is validated separately.

WHY THIS EXISTS
---------------
The original dual-Costas demod detected data by comparing the I-arms of two +/- R/4 tone
correlators.  That works on a REAL IF (the real Costas detector's intrinsic squaring gives
data-free spectral lines, and real-passband MSK tones are orthogonal in the real sense).
Ported to COMPLEX baseband it silently broke: Re(C1) on a single tone flips sign symbol to
symbol.  The cause is NOT cross-tone leakage -- the two complex tones ARE real-orthogonal
(<lo,up> over T is ~purely imaginary, Re ~= 0; a coherent receiver projecting on the real
axis ignores the quadrature crosstalk).  The cause is the MISSING PHASE STATE:

    the coherent reference at symbol k is  theta_c + psi_k ,  psi_k = (pi/2) * sum_{i<k} b_i

i.e. carrier phase PLUS the accumulated +/-90-deg-per-symbol MSK data phase.  Removing only
the constant carrier theta_c leaves psi_k rotating the correlation, which flips Re(C1).

THE FIX (this file): carry psi_k forward.  Decision-directed accumulator + a PI phase loop
that (a) soaks up the fractional-timing wobble (sps = 11.53 samples is non-integer),
(b) tracks any residual carrier offset the squared branch didn't fully null, and
(c) self-heals after an occasional wrong decision so errors don't run away.  Re-seed psi
from the known sync word each frame as a backstop (OPV has FEC + sync words downstream;
the inherent MSK 180-deg ambiguity is absorbed by OPV differential precoding).

RESULT: matches the genie coherent bound (BER 0) down to ~0 dB SNR and beats the
non-coherent magnitude detector by ~8x at -2 dB -- the coherent gain, where the link
budget actually needs it.

VALIDATED OPERATING POINTS (from stress sweeps -- see dd_coherent_stress.png)
  * Symbol timing : ~0.7-symbol capture window (-0.5 .. +0.2 of a symbol around the
                    naive boundary). Tune the recovered-clock dump phase to sit mid-window.
  * Carrier freq  : Ki=0.03 pulls in a residual offset past 3 kHz cleanly (Ki=0.01 only
                    reaches ~2 kHz). Default Ki bumped to 0.03 for that margin.
  * Acquisition   : a ~90-deg error in the de Buda theta_c estimate puts a COLD loop in a
                    bad branch (BER ~0.017). Drive the first ~16 symbols with the KNOWN
                    preamble bits (data-aided) -> BER ~0.0004. Always preamble-aid acquisition.
  * psi wordlength: the phase accumulator holds BER 0 at >=5 bits. 6-8 bits is ample;
                    the new NCO is cheap.

MAPS TO RTL
-----------
  zc          = channelizer I/Q with carrier removed (mult by NCO @ theta_c from sync branch)
  symbol gate = sync-branch recovered clock marks a = symbol-boundary sample index
  exp(-j psi) = a third small NCO (the psi accumulator) -- this is the new hardware
  LO/HI corr  = the EXISTING two tone correlators (integrate-and-dump over the symbol)
  perr/PI     = reuse the pi_controller structure already in costas_loop.vhd
"""
import numpy as np

fs, R = 625000.0, 54200.0          # channel sample rate, baud
fdev, sps = R/4, fs/R              # +/- tone offset (13550 Hz), samples/symbol (11.53)
L = int(round(sps))
_rel = np.arange(L)/fs
LO = np.exp(-1j*2*np.pi*fdev*_rel)  # lower tone reference  (bit -1)
HI = np.exp(+1j*2*np.pi*fdev*_rel)  # upper tone reference  (bit +1)


def detect(z, N, theta_c, Kp=0.20, Ki=0.03, aided=0, known_bits=None,
           resync_period=0, known_psi=None):
    """Decision-directed coherent MSK detection on complex baseband.

    z, N         : complex baseband (already at channel rate), length N
    theta_c      : carrier phase from the de Buda squared branch
    Kp, Ki       : PI phase-loop gains (Ki=0.03 -> pulls in >3 kHz residual offset)
    aided        : drive the first `aided` symbols with known_bits (data-aided acquisition;
                   ~16 resolves the bad-branch lock when theta_c is ~90 deg off)
    known_bits   : known preamble bits for the aided window
    resync_period: if >0, re-seed psi from known_psi every this many symbols (sync word)
    known_psi    : array of known reference phases for re-seed
    returns      : (bits_hat, psi_history)
    """
    zc = z * np.exp(-1j*theta_c)        # remove carrier  -> residual = data phase psi_k
    nsym = N // L + 2
    bits = np.full(nsym, np.nan)
    psi_hist = np.full(nsym, np.nan)
    psi = 0.0                           # init from known preamble-end phase in real Rx
    integ = 0.0
    for k in range(nsym):
        a = int(round(k*sps))           # symbol boundary (from recovered clock)
        if a + L > N:
            break
        if resync_period and known_psi is not None and k > 0 and k % resync_period == 0:
            psi = known_psi[k]; integ = 0.0
        seg = zc[a:a+L] * np.exp(-1j*psi)          # derotate by running phase state
        Clo = np.sum(seg*np.conj(LO))              # existing tone correlators
        Chi = np.sum(seg*np.conj(HI))
        b = -1.0 if np.real(Clo) > np.real(Chi) else 1.0   # COHERENT: real part only
        bits[k] = b
        drive = known_bits[k] if (aided and k < aided and known_bits is not None) else b
        Cwin = Clo if drive < 0 else Chi
        perr = np.angle(Cwin)                      # residual phase error (0 when locked)
        integ += Ki*perr
        psi += (np.pi/2)*drive + Kp*perr + integ   # feedforward data phase + PI correction
        psi_hist[k] = psi
    return bits, psi_hist


def detect_noncoherent(z, N, theta_c):
    """Non-coherent magnitude fallback (no psi_k needed). ~3 dB worse but dead simple."""
    zc = z * np.exp(-1j*theta_c)
    nsym = N // L + 2
    bits = np.full(nsym, np.nan)
    for k in range(nsym):
        a = int(round(k*sps))
        if a + L > N:
            break
        seg = zc[a:a+L]
        bits[k] = -1.0 if abs(np.sum(seg*np.conj(LO))) > abs(np.sum(seg*np.conj(HI))) else 1.0
    return bits


if __name__ == "__main__":
    # self-test
    def gen(bits, theta_c=0.0, snr=None, seed=0):
        Nn = int(len(bits)*sps)+1; n = np.arange(Nn)
        sym = np.minimum((n/sps).astype(int), len(bits)-1)
        z = np.exp(1j*(theta_c + np.cumsum(2*np.pi*fdev*bits[sym]/fs)))
        if snr is not None:
            g = np.random.default_rng(seed); p = 1/(10**(snr/10))
            z = z + np.sqrt(p/2)*(g.standard_normal(Nn)+1j*g.standard_normal(Nn))
        return z, Nn
    def ber(e, b):
        n = min(len(e), len(b)); e, b = e[:n], b[:n]
        m = ~np.isnan(e); e, b = e[m], b[m]
        return min(np.mean(e != b), np.mean(-e != b))
    rng = np.random.default_rng(1)
    bits = np.concatenate([np.tile([1,1,-1,-1],50), rng.integers(0,2,4000)*2-1])
    for snr in [8, 4, 0, -2]:
        z, N = gen(bits, 0.6, snr, 5)
        bd, _ = detect(z, N, 0.6); bn = detect_noncoherent(z, N, 0.6)
        print(f"SNR {snr:+d} dB   DD-coherent BER {ber(bd,bits):.5f}   non-coherent {ber(bn,bits):.5f}")
