#!/usr/bin/env python3
"""
chan_analyze.py -- channelizer-output I/Q characterization for OPV MSK demod bring-up.

PURPOSE
  Given a channel capture (chan0_iq.txt: one complex sample per line, "I Q"),
  answer the one question that splits the "f1 won't lock" problem in half:

      Is the channelizer delivering a clean, balanced, genuinely-COMPLEX
      two-sided MSK signal -- i.e. are BOTH the +13550 Hz and -13550 Hz tones
      present, at full strength?

        YES -> channelizer is innocent; f1's failure is INSIDE the demod.
        NO  -> the defect is UPSTREAM (a suppressed sideband, or dead quadrature).

  It also characterizes the channel DC (LO leakage): static offset vs settling
  transient vs drift vs zero-mean fluctuation -- a settling DC eats sim window.

WHY THESE TESTS, AND WHY AN FFT ALONE IS NOT ENOUGH
  A *real* signal (dead Q path) is conjugate-symmetric, so its +13.55 and -13.55
  FFT bands come out balanced -- it masquerades as a healthy two-sided signal.
  Instantaneous frequency does not lie: clean complex MSK toggles between
  +13.55 and -13.55 kHz; a real/Q-broken signal collapses to junk near 0 kHz.
  So: spectrum balance is NECESSARY, instantaneous frequency is SUFFICIENT.
  This tool runs both and reconciles them.

USAGE
  python3 chan_analyze.py [file=chan0_iq.txt] [fs=625000] [dev=13550] [baud=54200]
  python3 chan_analyze.py --selftest      # prove the tool discriminates good/bad

Notes
  - fs is the per-CHANNEL rate (625000 = 10 MSps / M=16), not the 20 MSps input.
  - dev = baud/4 = 13550 Hz is the MSK tone deviation.
  - 'rail' defaults to 32767 (the 16-bit channel sample full scale).
"""
import sys
import numpy as np

# ----------------------------------------------------------------------------
# config
# ----------------------------------------------------------------------------
CFG = dict(file="chan0_iq.txt", fs=625000.0, dev=13550.0, baud=54200.0, rail=32767.0)


def parse_args(argv):
    cfg = dict(CFG)
    for a in argv:
        if a == "--selftest":
            cfg["selftest"] = True
            continue
        k, _, v = a.partition("=")
        if k in ("fs", "dev", "baud", "rail"):
            cfg[k] = float(v)
        elif k == "file":
            cfg["file"] = v
    return cfg


def hr(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


# ----------------------------------------------------------------------------
# 1. LEVELS, CLIPPING, QUADRATURE SANITY
# ----------------------------------------------------------------------------
def report_levels(z, rail):
    """PURPOSE: is the capture a sane, un-clipped, genuinely complex signal?
    Catches the failure an FFT hides -- a dead or duplicated Q path."""
    hr("1. LEVELS / CLIPPING / QUADRATURE")
    print("PURPOSE: confirm the capture is un-clipped and genuinely complex")
    I, Q = z.real, z.imag
    rms = np.sqrt(np.mean(np.abs(z) ** 2))
    pk = np.max(np.abs(np.concatenate([I, Q])))
    clip = 100.0 * np.mean((np.abs(I) >= rail) | (np.abs(Q) >= rail))
    sI, sQ = np.std(I), np.std(Q)
    # SYMMETRIC dead-axis test: which axis is starved, if any -- assume NEITHER.
    lo, hi = (sI, sQ) if sI <= sQ else (sQ, sI)
    dead_ratio = lo / (hi + 1e-9)                 # min/max; ~1 balanced, ~0 one axis dead
    dead_axis = "I" if sI < sQ else "Q"
    # corr is undefined if an axis is constant -> treat as "dependent"
    corr = 0.0 if (sI < 1e-6 or sQ < 1e-6) else float(np.corrcoef(I, Q)[0, 1])
    print(f"  RMS amplitude        : {rms:9.1f}")
    print(f"  peak |sample|        : {pk:9.1f}   (rail {rail:.0f})")
    print(f"  samples at full scale: {clip:9.3f} %")
    print(f"  std(I) / std(Q)      : {sI:8.1f} / {sQ:8.1f}")
    print(f"  min/max std ratio    : {dead_ratio:9.3f}   (~1.0 balanced; ~0 = one axis dead)")
    print(f"  corr(I,Q)            : {corr:+9.3f}   (~0 good; ~+/-1 = I==Q / swap-dup)")
    verdict = "OK"
    if clip > 1.0:
        verdict = "CLIPPING -- spectrum/images suspect, fix gain before trusting tones"
    elif dead_ratio < 0.25:
        verdict = (f"QUADRATURE DEAD on the {dead_axis} axis (std {lo:.1f} vs {hi:.1f}) "
                   f"-- signal is effectively REAL; do NOT assume which axis upstream")
    elif abs(corr) > 0.9:
        verdict = "I/Q LINEARLY DEPENDENT -- likely a swap/duplication (I==+/-Q) bug"
    print(f"VERDICT: {verdict}")
    return dict(rms=rms, clip=clip, dead_ratio=dead_ratio, dead_axis=dead_axis,
                corr=corr, qi=dead_ratio, verdict=verdict)


# ----------------------------------------------------------------------------
# 2. DC CHARACTERIZATION  (static offset vs transient vs drift vs fluctuation)
# ----------------------------------------------------------------------------
def report_dc(z, fs, block=200):
    """PURPOSE: classify the channel DC. A settling transient (LO-leakage
    blocker charging) eats the sim window; a static offset biases the loops."""
    hr("2. DC CHARACTERIZATION")
    print("PURPOSE: offset vs transient vs drift vs zero-mean fluctuation")
    I, Q = z.real, z.imag
    N = len(z)
    rms = np.sqrt(np.mean(np.abs(z) ** 2))
    gdc = abs(z.mean())
    gpct = 100 * gdc / rms
    print(f"  global mean I/Q      : {I.mean():+8.1f} / {Q.mean():+8.1f}")
    print(f"  global |DC|          : {gdc:8.1f}   ({gpct:+.1f}% of RMS)")

    # skip-sweep: the decisive transient detector (does |DC| decay with time?)
    print("  |DC| vs start offset (settling test):")
    skips = [s for s in (0, N // 10, N // 5, 2 * N // 5, 3 * N // 5, 4 * N // 5) if s < N - 100]
    dcs = []
    for s in skips:
        zz = z[s:]
        d = abs(zz.mean())
        dcs.append(d)
        print(f"    t>={1e3*s/fs:6.1f} ms : |DC|={d:8.1f}  ({100*d/rms:5.1f}% of RMS)")
    decay = dcs[0] / (dcs[-1] + 1e-9)

    # local block means -> fluctuation vs steady
    nb = N // block
    mI = np.array([I[i*block:(i+1)*block].mean() for i in range(nb)])
    mQ = np.array([Q[i*block:(i+1)*block].mean() for i in range(nb)])
    cross = (np.sum(np.diff(np.sign(mI[mI != 0])) != 0) +
             np.sum(np.diff(np.sign(mQ[mQ != 0])) != 0))
    frac_cross = cross / (2 * max(1, nb))

    # verdict -- transient is gated on the SKIP-SWEEP decay, not on tail crossings
    if gpct < 3.0 and frac_cross > 0.10:
        verdict = "DC-CLEAN (whole-file DC ~0; local blocks are zero-mean fluctuation)"
    elif gpct < 3.0:
        verdict = "CLEAN (DC negligible)"
    elif decay > 2.0:
        verdict = (f"SETTLING TRANSIENT (|DC| decays {decay:.1f}x over the record "
                   f"-- DC blocker/filter charging; shortens usable window)")
    elif dcs[-1] > 2 * dcs[0]:
        verdict = "DRIFT (|DC| grows with time)"
    else:
        verdict = "STATIC OFFSET (|DC| high and roughly constant in time)"
    print(f"  block sign-crossings : {frac_cross:.2f} of blocks")
    print(f"VERDICT: {verdict}")
    return dict(gpct=gpct, decay=decay, verdict=verdict)


# ----------------------------------------------------------------------------
# 3. SPECTRUM  (tones present? balanced? above noise? DC vs tones?)
# ----------------------------------------------------------------------------
def report_spectrum(z, fs, dev):
    """PURPOSE: are both +/-dev tones present, balanced, and ABOVE the noise
    floor? (Balance alone can be faked by a real signal -- see section 4.)"""
    hr("3. SPECTRUM (tone balance vs noise floor)")
    print("PURPOSE: both +/-13.55 tones present, balanced, above noise")
    N = len(z)
    W = np.hanning(N)
    Z = np.fft.fftshift(np.fft.fft(z * W))
    f = np.fft.fftshift(np.fft.fftfreq(N, 1 / fs))
    mag = np.abs(Z)

    def band(lo, hi):
        m = (f >= lo) & (f < hi)
        return mag[m].max() if m.any() else 0.0

    d = dev
    pos = band(d - 600, d + 600)
    neg = band(-d - 600, -d + 600)
    dc = band(-150, 150)
    nm = (np.abs(f) > 3 * d) & (np.abs(f) < 6 * d)        # guard band for noise
    noise = np.median(mag[nm]) if nm.any() else 1.0
    db = lambda x: 20 * np.log10((x + 1e-9) / (max(pos, neg) + 1e-9))

    print(f"  +{d/1e3:.2f} kHz tone    : {db(pos):+6.1f} dB   (TNR {20*np.log10(pos/noise):+5.1f} dB)")
    print(f"  -{d/1e3:.2f} kHz tone    : {db(neg):+6.1f} dB   (TNR {20*np.log10(neg/noise):+5.1f} dB)")
    print(f"  DC (0 Hz)            : {db(dc):+6.1f} dB   relative to stronger tone")
    print(f"  noise floor (median) : {noise:9.1f}")
    bal = 20 * np.log10((min(pos, neg)) / (max(pos, neg) + 1e-9))
    tnr_weak = 20 * np.log10(min(pos, neg) / noise)
    if tnr_weak < 6:
        verdict = "ONE SIDEBAND SUPPRESSED (weaker tone is at the noise floor)"
    elif abs(bal) > 6:
        verdict = f"IMBALANCED ({bal:.1f} dB) -- investigate, but both tones exist"
    else:
        verdict = f"BOTH TONES PRESENT & BALANCED ({bal:+.1f} dB)"
    if db(dc) > 0:
        verdict += f"  [+ DC spike {db(dc):+.1f} dB ABOVE the tones]"
    print(f"VERDICT: {verdict}")
    return dict(bal=bal, tnr_weak=tnr_weak, verdict=verdict)


# ----------------------------------------------------------------------------
# 4. INSTANTANEOUS FREQUENCY  (the decisive complex-MSK test)
# ----------------------------------------------------------------------------
def report_msk(z, fs, dev, baud):
    """PURPOSE: prove the signal is genuinely two-sided complex MSK, not a
    conjugate-symmetric real signal that the FFT mistakes for balanced.
    Method: strip LOCAL DC (a transient otherwise inflates the estimate),
    then histogram the instantaneous frequency and check both +/-dev populated."""
    hr("4. INSTANTANEOUS FREQUENCY / MSK STRUCTURE")
    print("PURPOSE: genuine two-sided complex MSK vs real/Q-broken (FFT can't tell)")
    sps = fs / baud
    W = int(round(20 * sps))                     # local-DC window ~20 symbols
    zac = z.astype(complex).copy()
    for i in range(0, len(z), W):                # remove time-varying DC
        zac[i:i + W] -= z[i:i + W].mean()
    finst = np.diff(np.unwrap(np.angle(zac))) / (2 * np.pi) * fs   # Hz

    # analyze the SETTLED half (avoid the DC transient entirely)
    fset = finst[len(finst) // 2:] / 1e3                            # kHz
    dkhz = dev / 1e3
    tol = dkhz * 0.35
    fpos = np.mean(np.abs(fset - dkhz) < tol)
    fneg = np.mean(np.abs(fset + dkhz) < tol)
    fzero = np.mean(np.abs(fset) < tol)
    # two dominant histogram modes for the human
    h, e = np.histogram(fset, bins=160, range=(-3 * dkhz, 3 * dkhz))
    c = 0.5 * (e[:-1] + e[1:])
    modes = []
    for oi in np.argsort(h)[::-1]:
        if all(abs(c[oi] - m) > 5 for m in modes):
            modes.append(round(float(c[oi]), 1))
        if len(modes) == 2:
            break
    print(f"  settled-region modes : {sorted(modes)} kHz   (expect ~ +/-{dkhz:.1f})")
    print(f"  mass near +{dkhz:.1f} kHz : {100*fpos:5.1f} %")
    print(f"  mass near -{dkhz:.1f} kHz : {100*fneg:5.1f} %")
    print(f"  mass near   0   kHz : {100*fzero:5.1f} %   (high here = real/Q-broken)")
    both = fpos > 0.15 and fneg > 0.15
    if both:
        verdict = "GENUINE TWO-SIDED COMPLEX MSK (both tones carried; channelizer OK)"
    elif fpos > 0.15 and fneg < 0.05:
        verdict = "SINGLE-SIDED: -dev missing (upstream sideband suppression)"
    elif fzero > 0.4:
        verdict = "REAL / Q-BROKEN: energy collapses to DC, no clean +/-dev toggle"
    else:
        verdict = "AMBIGUOUS -- inspect histogram directly"
    print(f"VERDICT: {verdict}")
    return dict(fpos=fpos, fneg=fneg, fzero=fzero, modes=sorted(modes), verdict=verdict)


# ----------------------------------------------------------------------------
# summary -> the decision table
# ----------------------------------------------------------------------------
def summarize(lv, dc, sp, ms):
    hr("SUMMARY")
    chan_ok = ("GENUINE" in ms["verdict"]) and ("SUPPRESSED" not in sp["verdict"]) \
              and (lv["qi"] > 0.25)
    if chan_ok:
        print("  CHANNELIZER OK -- both tones, balanced, genuinely complex.")
        print("  => f1's failure to lock is DOWNSTREAM, inside the demod f1 arm /")
        print("     complex path. Interrogate the I/Q-swap and the f1 NCO sign next.")
    elif "Q-BROKEN" in ms["verdict"] or lv["qi"] < 0.25:
        print("  QUADRATURE DEAD upstream -- the channel itself is effectively real.")
        print("  => fix the channelizer/wrapper I/Q before touching the demod.")
    elif "SUPPRESSED" in sp["verdict"] or "missing" in ms["verdict"]:
        print("  SIDEBAND SUPPRESSED upstream -- f1 has no tone to lock.")
        print("  => fix the channelizer/wrapper complex path before the demod.")
    else:
        print("  Mixed signals -- read the per-section verdicts above.")
    if "TRANSIENT" in dc["verdict"] or "OFFSET" in dc["verdict"]:
        print(f"  DC note: {dc['verdict']}")
        print("  => a large/slow DC shortens the usable lock window; check the blocker.")


# ----------------------------------------------------------------------------
# self-test: prove the tool still discriminates the three channels we care about
# ----------------------------------------------------------------------------
def _make_msk(N, fs, dev, baud, kind="good", seed=0):
    rng = np.random.default_rng(seed)
    sps = fs / baud
    nb = int(N / sps) + 2
    bits = rng.integers(0, 2, nb) * 2 - 1
    idx = np.clip((np.arange(N) / sps).astype(int), 0, nb - 1)
    phi = 2 * np.pi * np.cumsum(dev * bits[idx]) / fs
    z = np.exp(1j * phi)
    if kind == "real":
        z = np.cos(phi).astype(complex)                       # dead Q
    elif kind == "real_i":
        z = (1j * np.cos(phi)).astype(complex)                # dead I
    elif kind == "suppressed":
        Z = np.fft.fft(z); ff = np.fft.fftfreq(N, 1 / fs)
        Z[ff < 0] = 0; z = np.fft.ifft(Z)                     # kill -sideband
    rms = np.sqrt(np.mean(np.abs(z) ** 2))
    t = np.arange(N) / fs
    z = z + (0.2 - 0.6j) * rms * np.exp(-t / 0.03)            # decaying Q-DC
    z = z + 0.03 * rms * (rng.standard_normal(N) + 1j * rng.standard_normal(N))
    return z * 6000                                            # scale to ~int range


def selftest(cfg):
    fs, dev, baud = cfg["fs"], cfg["dev"], cfg["baud"]
    for kind in ("good", "real", "real_i", "suppressed"):
        z = _make_msk(60000, fs, dev, baud, kind=kind, seed=3)
        hr(f"SELFTEST CHANNEL = {kind.upper()}")
        lv = report_levels(z, cfg["rail"])
        sp = report_spectrum(z, fs, dev)
        ms = report_msk(z, fs, dev, baud)
        print(f"\n  >> expected to read as: "
              f"{'channelizer OK' if kind=='good' else kind+' fault'}")


def main():
    cfg = parse_args(sys.argv[1:])
    if cfg.get("selftest"):
        selftest(cfg)
        return
    print(f"chan_analyze: file={cfg['file']} fs={cfg['fs']:.0f} dev={cfg['dev']:.0f}")
    d = np.loadtxt(cfg["file"])
    z = d[:, 0] + 1j * d[:, 1]
    print(f"loaded N={len(z)}  ({1e3*len(z)/cfg['fs']:.1f} ms)")
    lv = report_levels(z, cfg["rail"])
    dc = report_dc(z, cfg["fs"])
    sp = report_spectrum(z, cfg["fs"], cfg["dev"])
    ms = report_msk(z, cfg["fs"], cfg["dev"], cfg["baud"])
    summarize(lv, dc, sp, ms)


if __name__ == "__main__":
    main()
