#!/usr/bin/env python3
"""opv_chan_stim_gen_real.py -- OPV channelizer stimulus from REAL OPV frames.

Produces GENUINE OPV frames: the 134-byte payload is CCSDS-randomized, K=7 R=1/2
convolutionally encoded, and 67x32 interleaved -- ported bit-for-bit from
opv-mod.cpp (verified: frames decode 4/4 PERFECT, 0 errors, through opv-demod).
The 24-bit sync word 0x02B8DB is the raw frame marker. The whole frame is then
DIFFERENTIAL-MSK modulated (the d_val_xor/d_s1/d_s2 precoder, bit-identical to
msk_modulator.vhd / opv-mod.cpp).

WHY THIS MATTERS: the previous version wrote a RAW counter payload (0x00,0x01,...)
straight to MSK -- no randomize/encode/interleave. That produced long single-symbol
runs (up to 15 identical bits) that starve a single-line de Buda of one squared line
(de Buda 1972, Sec. VII: "loss of lock if a long string of only mark/space is
received... remedy: source encoding"). Real whitened frames cut the worst-case run
and are the honest test vector.

File format: "I Q" space-separated signed-16 per line (matches the testbench reader).

NOISE (--ebn0)
--------------
Complex baseband, constant-envelope MSK, so signal power Ps = amp^2. Complex
AWGN of total power sigma^2 spread across the sample rate fs gives N0 =
sigma^2/fs. The info bit rate is Rb = baud/2 (R=1/2 code), so Eb = Ps/Rb and

    Eb/N0 = Ps*fs / (Rb * sigma^2)      ->    sigma^2 = Ps*fs / (Rb * 10^(EbN0/10))

Eb/N0 is what the receiver actually sees: the channelizer filters the noise down
with the signal, so N0 and Rb survive and fs cancels. But sigma at the ADC is
LARGE, because the wideband noise is spread thin. At fs=20 Msps and Eb/N0 = 6 dB,
sigma is 13.6x the signal amplitude, and amp=9000 would need a peak near 355,000
-- eleven times past int16. That is not a modelling artefact. It is 54.2 kHz of
signal inside 20 MHz of noise, recovered by 10*log10(20e6/54200) = 25.7 dB of
processing gain.

So when --ebn0 is given, the signal AND the noise are scaled together (which
preserves the ratio) until the composite fits --fullscale with --headroom to
spare. The effective signal amplitude that results is REPORTED, not assumed. It
will be far below --amp, and that is correct: with noise present, a channel
carrying a real signal is a small fraction of full scale. Recovering it is the
per-channel normalizer's job.
"""
import argparse, numpy as np

SYNC_WORD = 0x02B8DB
FRAME_BYTES = 134                       # RAW payload bytes (opv-mod FRAME_BYTES)
ENCODED_BITS = FRAME_BYTES * 8 * 2      # 2144 after R=1/2
SYNC_BITS = 24
FRAME_BITS = SYNC_BITS + ENCODED_BITS   # 2168 symbols / 40 ms frame
EASTER_EGG = "HELLO WORLD FROM OPULENT VOICE - 73 DE W5NYV - "   # override with --message

def _tile(msg, nbytes):
    raw = msg.encode("ascii", "replace") or b" "
    return (raw * ((nbytes // len(raw)) + 1))[:nbytes]

# ---- CCSDS randomizer (LFSR): seed 0xFF, taps 7^6^4^2 ----
class LFSR:
    def __init__(s): s.state = 0xFF
    def next_byte(s):
        out = 0
        for i in range(7, -1, -1):
            out |= ((s.state >> 7) & 1) << i
            fb = ((s.state >> 7) ^ (s.state >> 6) ^ (s.state >> 4) ^ (s.state >> 2)) & 1
            s.state = ((s.state << 1) | fb) & 0xFF
        return out

# ---- convolutional encoder K=7 R=1/2 : TRUE Voyager 171/133 (d_free=10) ----
# Parity masks 0x67/0x76 for the state=(in<<6)|sr layout, mirroring opv_codec.hpp
# GROUND TRUTH. (The old 0x4F/0x6D were 174/155 octal -- the d_free=8 tap bug that
# came from a hand-copied encoder drifting out of sync with the C++ codec.)
class ConvEncoder:
    def __init__(s): s.sr = 0
    def reset(s): s.sr = 0
    def get_state(s): return s.sr
    def encode_bit(s, b):
        st = (b << 6) | s.sr
        g1 = bin(st & 0x67).count('1') & 1
        g2 = bin(st & 0x76).count('1') & 1
        s.sr = ((s.sr << 1) | b) & 0x3F
        return g1, g2

# ---- 67x32 block interleaver with MSB-first byte correction ----
def interleave(bits):
    t = [0] * len(bits)
    for i in range(len(bits)):
        ip = (i % 32) * 67 + (i // 32)
        bn, bib = ip // 8, ip % 8
        t[bn * 8 + (7 - bib)] = bits[i]
    return t

def encode_frame(payload):              # 134 bytes -> 2144 encoded+interleaved bits
    # randomize -> TAIL-BITING conv encode -> interleave, mirroring opv_codec.hpp.
    lf, cv = LFSR(), ConvEncoder()
    rnd = [payload[i] ^ lf.next_byte() for i in range(FRAME_BYTES)]

    # flatten to the encoder's bit order: byte 133 first, MSB first within a byte
    bits_in = []
    for bi in range(FRAME_BYTES - 1, -1, -1):     # last byte first (HDL order)
        for bp in range(7, -1, -1):
            bits_in.append((rnd[bi] >> bp) & 1)

    # tail-biting pass 1: encode from the zero state to discover the ring end
    # state (output discarded).
    cv.reset()
    for b in bits_in:
        cv.encode_bit(b)
    seed = cv.get_state()

    # pass 2: real encode, continuing from the seeded state (NO reset) so the ring
    # closes -- start state == end state == seed. This protects the wrap bits; in a
    # real OPV frame byte 0 is the Base-40 station ID (callsign), so the wrap must
    # be reliable, not left to the un-terminated trellis edge.
    cv.sr = seed
    enc = []
    for b in bits_in:
        g1, g2 = cv.encode_bit(b)
        enc += [g1, g2]
    assert cv.get_state() == seed, "tail-biting ring-closure failed"

    return interleave(enc)

def build_frame_bits(f):
    payload = list(_tile(MESSAGE, FRAME_BYTES))              # easter-egg payload (--message)
    sync = [(SYNC_WORD >> (SYNC_BITS - 1 - i)) & 1 for i in range(SYNC_BITS)]
    return np.array(sync + encode_frame(payload), dtype=np.uint8)

def build_bitstream(n):
    return np.concatenate([build_frame_bits(f) for f in range(n)])


def build_preamble_bits():
    """One preamble frame: 2168 bits of 0xCC (1100 1100), RAW -- no sync word,
    no FEC. Bit-identical to opv-mod's send_preamble_frame(). Its only job is to
    give the receiver time to acquire symbol timing and settle its AGC before the
    first real frame arrives. At 54200 baud that is 40.00 ms."""
    return np.array([(0xCC >> (7 - (i % 8))) & 1 for i in range(FRAME_BITS)],
                    dtype=np.uint8)


# ---- OPV differential MSK precoder (bit-identical to the RTL / opv-mod) ----
def diff_encode(bits):
    d_val_xor_T = 0; b_n = 1
    ds1 = np.zeros(len(bits), np.int8); ds2 = np.zeros(len(bits), np.int8)
    for i, bit in enumerate(bits):
        d_val = 1 if bit == 0 else -1
        if   d_val == 1  and d_val_xor_T == 1:  d_val_xor = 1
        elif d_val == 1  and d_val_xor_T == -1: d_val_xor = -1
        elif d_val == -1 and d_val_xor_T == 1:  d_val_xor = -1
        elif d_val == -1 and d_val_xor_T == -1: d_val_xor = 1
        else: d_val_xor = 1
        d_pos = (d_val + 1) >> 1; d_neg = (d_val - 1) >> 1
        d_pos_enc = d_pos; d_neg_enc = (d_neg if b_n == 0 else -d_neg)
        s1 = 1 if (d_pos_enc == 1 and d_val_xor_T == 1) else (-1 if (d_pos_enc == 1 and d_val_xor_T == -1) else 0)
        if   d_neg_enc == -1 and d_val_xor_T == 1:  s2 = -1
        elif d_neg_enc == -1 and d_val_xor_T == -1: s2 = 1
        elif d_neg_enc == 1  and d_val_xor_T == 1:  s2 = 1
        elif d_neg_enc == 1  and d_val_xor_T == -1: s2 = -1
        else: s2 = 0
        ds1[i] = s1; ds2[i] = s2
        d_val_xor_T = d_val_xor; b_n = 1 - b_n
    return ds1, ds2

def add_awgn(s, fs, baud, ebn0_db, rng):
    """Complex AWGN at a given INFO-BIT Eb/N0. Returns (noisy, sigma, meas_ebn0_db).

    Signal power is measured from s itself rather than assumed, so this is
    correct even if the caller has already scaled or clipped anything.
    """
    rb = baud / 2.0                      # R = 1/2 -> info bit rate
    ps = float(np.mean(np.abs(s) ** 2))  # complex signal power
    n0 = ps / (rb * 10.0 ** (ebn0_db / 10.0))
    sigma2 = n0 * fs                     # total complex noise power over fs
    sigma = np.sqrt(sigma2)
    n = (rng.standard_normal(len(s)) + 1j * rng.standard_normal(len(s))) * (sigma / np.sqrt(2.0))
    # measure what we actually made, do not trust the algebra
    meas = 10.0 * np.log10(ps * fs / (rb * float(np.mean(np.abs(n) ** 2))))
    return s + n, sigma, meas


def fit_fullscale(z, fullscale, headroom):
    """Scale the composite so its peak component sits at headroom*fullscale.

    Scaling signal and noise together leaves Eb/N0 untouched.
    """
    pk = max(float(np.max(np.abs(z.real))), float(np.max(np.abs(z.imag))))
    if pk == 0.0:
        return z, 1.0
    k = headroom * fullscale / pk
    return z * k, k


def build_burst_timeline(frames, bursts, preamble, idle_ms, fs, baud):
    """Return a list of (kind, bits_or_nsamples) describing the whole timeline.

    kind is 'idle' (n samples of NOTHING -- the transmitter is off) or 'bits'.

    Real OPV: every transmission opens with ONE preamble frame, then data frames
    run back-to-back with no gaps. Between transmissions the transmitter is OFF.
    The receiver sees only its own noise floor. That silence is what the squelch
    floor and the AGC's re-acquisition have to survive.
    """
    idle_n = int(round(idle_ms * 1e-3 * fs))
    tl = []
    for b in range(bursts):
        if idle_ms > 0:
            tl.append(('idle', idle_n))
        bits = []
        if preamble:
            bits.append(build_preamble_bits())
        bits.append(build_bitstream(frames))
        tl.append(('bits', np.concatenate(bits)))
    if idle_ms > 0:
        tl.append(('idle', idle_n))
    return tl


def modulate_diff(bits, fs, baud, fd, amp, center):
    ds1, ds2 = diff_encode(bits)
    tone = np.where(ds1 != 0, 1.0, -1.0)
    n_samples = int(np.ceil(len(bits) * fs / baud)); n = np.arange(n_samples)
    sym = np.minimum((n * baud / fs).astype(np.int64), len(bits) - 1)
    f_inst = center + fd * tone[sym]
    phase = 2.0 * np.pi * np.cumsum(f_inst) / fs
    return amp * np.exp(1j * phase), n_samples

def write_stimulus(path, s, fullscale=32767):
    iv = np.clip(np.round(s.real).astype(np.int64), -fullscale - 1, fullscale)
    qv = np.clip(np.round(s.imag).astype(np.int64), -fullscale - 1, fullscale)
    with open(path, "w") as fh:
        fh.write("\n".join(f"{int(a)} {int(b)}" for a, b in zip(iv, qv))); fh.write("\n")

MESSAGE = EASTER_EGG

def main():
    global MESSAGE
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="opv_chan_stim_dc.txt")
    ap.add_argument("--frames", type=int, default=6)
    ap.add_argument("--fs", type=float, default=20.0e6)
    ap.add_argument("--baud", type=float, default=54200.0)
    ap.add_argument("--fc", type=float, default=0.0)
    ap.add_argument("--carrier-offset", type=float, default=0.0)
    ap.add_argument("--fd", type=float, default=None)
    ap.add_argument("--amp", type=float, default=9000.0)
    ap.add_argument("--message", type=str, default=EASTER_EGG, help="easter-egg payload text")
    ap.add_argument("--ebn0", type=float, default=None,
                    help="INFO-bit Eb/N0 in dB. Omit for a noiseless waveform.")
    ap.add_argument("--seed", type=int, default=1,
                    help="AWGN seed. Same seed = same noise, so runs are comparable.")
    ap.add_argument("--fullscale", type=int, default=32767,
                    help="peak sample magnitude. Use 2047 for a 12-bit demod bench.")
    ap.add_argument("--headroom", type=float, default=0.90,
                    help="fraction of fullscale the composite peak is scaled to")
    ap.add_argument("--bursts", type=int, default=1,
                    help="number of PTT transmissions. Gaps of --idle-ms between them.")
    ap.add_argument("--idle-ms", type=float, default=0.0,
                    help="transmitter-OFF time between bursts, in ms. Noise continues.")
    ap.add_argument("--preamble", action="store_true",
                    help="prepend one 40 ms preamble frame (2168 raw bits of 0xCC) to "
                         "each burst, exactly as opv-mod -P does")
    a = ap.parse_args()
    fd = a.fd if a.fd is not None else a.baud / 4.0
    MESSAGE = a.message
    center = a.fc + a.carrier_offset
    if a.bursts > 1 or a.preamble or a.idle_ms > 0:
        tl = build_burst_timeline(a.frames, a.bursts, a.preamble, a.idle_ms, a.fs, a.baud)
        chunks = []
        for kind, payload in tl:
            if kind == 'idle':
                chunks.append(np.zeros(payload, dtype=complex))   # TX OFF. Noise added later.
            else:
                sc, _ = modulate_diff(payload, a.fs, a.baud, fd, a.amp, center)
                chunks.append(sc)
        s = np.concatenate(chunks); ns = len(s)
        bits = np.concatenate([p for k, p in tl if k == 'bits'])
    else:
        bits = build_bitstream(a.frames)
        s, ns = modulate_diff(bits, a.fs, a.baud, fd, a.amp, center)

    sigma = 0.0
    meas_ebn0 = None
    eff_amp = a.amp
    if a.ebn0 is not None:
        rng = np.random.default_rng(a.seed)
        # Eb/N0 must be referenced to the BURST power, not to the average over a
        # timeline that is mostly silence. Measure Ps on the non-zero samples.
        on = np.abs(s) > 0
        ps_burst = float(np.mean(np.abs(s[on]) ** 2)) if on.any() else 1.0
        rb = a.baud / 2.0
        sigma = np.sqrt(ps_burst / (rb * 10.0 ** (a.ebn0 / 10.0)) * a.fs)
        n = (rng.standard_normal(len(s)) + 1j * rng.standard_normal(len(s))) * (sigma / np.sqrt(2.0))
        meas_ebn0 = 10.0 * np.log10(ps_burst * a.fs / (rb * float(np.mean(np.abs(n) ** 2))))
        s = s + n   # noise runs through the idle gaps too. The receiver never sees zero.
        s, k = fit_fullscale(s, a.fullscale, a.headroom)
        sigma *= k
        eff_amp = a.amp * k
    write_stimulus(a.out, s, a.fullscale)
    print(f"wrote {a.out}: {ns} samples, {len(bits)} bits")
    if a.bursts > 1 or a.preamble or a.idle_ms > 0:
        per = (1 if a.preamble else 0) + a.frames
        print(f"  timeline   : {a.bursts} burst(s) of "
              f"{'1 preamble + ' if a.preamble else ''}{a.frames} data frame(s) = "
              f"{per*FRAME_BITS/a.baud*1e3:.1f} ms each")
        if a.idle_ms > 0:
            print(f"               separated by {a.idle_ms:.1f} ms of TRANSMITTER OFF "
                  f"(noise continues; the receiver never sees zero)")
        print(f"               total {ns/a.fs*1e3:.1f} ms")
    else:
        print(f"  frames     : {a.frames} (2168 bits each)")
    print(f"  frame      : sync 0x{SYNC_WORD:06X} + easter-egg payload -> CCSDS-randomize + K=7 R=1/2 + 67x32 interleave")
    print(f"  modulation : DIFFERENTIAL MSK (d_val_xor/d_s1/d_s2), I=cos Q=sin  [bit-exact to opv-mod / msk_modulator]")
    _pl = _tile(MESSAGE, FRAME_BYTES)
    print(f"  message    : {MESSAGE!r}")
    print(f"  payload[0:16]: {' '.join(f'{b:02X}' for b in _pl[:16])} = {_pl[:16].decode('ascii','replace')!r}")
    print(f"  fs={a.fs/1e3:.1f}k baud={a.baud:.0f} fd={fd:.0f}  center=fc {a.fc:.0f}+offset {a.carrier_offset:.0f}={center:.0f} Hz  amp={a.amp:.0f}")
    if a.ebn0 is None:
        print("  noise      : NONE. Every symbol is confidently decided, so the 3-bit")
        print("               soft quantiser will sit on its rails (codes 0 and 7).")
        print("               That is the CORRECT high-SNR distribution, not a bug.")
        print("               The middle codes only carry information when there is noise.")
        print("               Use --ebn0 to make the soft path do its job.")
    else:
        import math as _m
        rb = a.baud / 2.0
        # Convention (2026-07-17): all C/N figures in the 156.25 kHz
        # CHANNEL bandwidth -- the noise the receiver actually integrates.
        # MSK signal-property bandwidths (99% occ = 1.18*baud ~ 64 kHz,
        # null-to-null = 1.5*baud ~ 81 kHz) are documented in
        # rx_link_budget.py, not used as noise denominators here.
        CHAN_BW = 156.25e3
        pg = 10*_m.log10(a.fs / CHAN_BW)               # channelizer processing gain
        cn = a.ebn0 + 10*_m.log10(rb / CHAN_BW)        # C/N in the channel
        iv = np.clip(np.round(s.real).astype(np.int64), -a.fullscale-1, a.fullscale)
        qv = np.clip(np.round(s.imag).astype(np.int64), -a.fullscale-1, a.fullscale)
        clip = float(np.mean((np.abs(iv) >= a.fullscale) | (np.abs(qv) >= a.fullscale)))
        print(f"  noise      : AWGN, requested Eb/N0 = {a.ebn0:.2f} dB (info bits, R=1/2), seed={a.seed}")
        print(f"               MEASURED Eb/N0 from the arrays = {meas_ebn0:.2f} dB")
        print(f"               sigma (complex, total) = {sigma:.0f}   sigma/amp_eff = {sigma/max(eff_amp,1e-9):.2f}")
        print(f"               effective signal amplitude = {eff_amp:.0f} of {a.fullscale}"
              f"  ({20*_m.log10(max(eff_amp,1e-9)/a.fullscale):.1f} dBFS)")
        print(f"               composite peak scaled to {a.headroom*100:.0f}% FS; clipped samples = {100*clip:.3f}%")
        print(f"               C/N in the 156.25 kHz channel = {cn:.2f} dB;  channelizer processing gain = {pg:.1f} dB")
        print(f"               K=7 R=1/2 soft Viterbi threshold is ~4.5 dB Eb/N0 at BER 1e-5.")

if __name__ == "__main__": main()
