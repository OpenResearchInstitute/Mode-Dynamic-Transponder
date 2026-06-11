#!/usr/bin/env python3
"""
opv_chan_stim_gen.py  --  20 Msps complex OPV-framed MSK stimulus for
tb_haifuraiya_channelizer_axi.vhd  (injected at s_axis_data).

Signal chain this feeds:
    file @ 20 Msps complex  ->  halfband_decimator (/2 -> 10 Msps)
                            ->  channelizer (M_DECIMATION=16 -> 625 ksps/ch)
                            ->  channel 0 out  ->  msk_demodulator (I-only)
                            ->  frame_sync_detector_soft

Domain model
------------
  Frame      : [ SYNC_WORD (24 bits, MSB-first) ][ PAYLOAD_BITS payload ]
               -- matches frame_sync_detector_soft: SYNC=0x02B8DB,
                  PAYLOAD_BYTES=268 -> PAYLOAD_BITS=2144, total 2168 bits.
  Bitstream  : frames laid back-to-back, continuous (a receiver sees bits
               arrive off the air at clock cadence -- no gaps, no overfeed).
  Modulator  : continuous-phase MSK (h=1/2). bit=1 -> +fd, bit=0 -> -fd.
               Centroid fc places the signal at a REAL IF inside channel 0
               (off channel-centre DC), so the I-only Costas does not fold
               its tones under real projection.
  Writer     : "iv qv" per line, signed-16 -- exactly what the TB's
               read(l,iv); read(l,qv) loop consumes.

Frequencies (normalised to the 625 ksps channel rate the demod sees):
  fc  = 110130 Hz  -> 0.176  (matches proven rx freq words)
  fd  = baud/4     -> tones fc-/+fd = 96580 / 123680 Hz
                      (demod NCOs sit at 0x278E9F6B/0x32A84381 = 96560/123700;
                       the ~30 Hz residual is well within Costas pull-in)
"""

import argparse
import numpy as np

# ----- fixed protocol / chain constants -----
SYNC_WORD     = 0x02B8DB        # 24-bit OPV sync, MSB-first
SYNC_BITS     = 24
PAYLOAD_BYTES = 268             # frame_sync_detector_soft generic
PAYLOAD_BITS  = PAYLOAD_BYTES * 8   # 2144
FRAME_BITS    = SYNC_BITS + PAYLOAD_BITS  # 2168


def build_frame_bits(frame_idx: int) -> np.ndarray:
    """One frame: sync word (MSB-first) + a known, reproducible payload.

    Payload is a per-frame byte counter so the round-trip check is trivial:
    payload byte k of frame f = (frame_idx + k) & 0xFF, sent MSB-first.
    Swap in a PRBS or real OPV-encoded bytes later; frame_sync only needs
    the sync word to be correct -- it passes the payload soft-bits through.
    """
    bits = np.empty(FRAME_BITS, dtype=np.uint8)

    # sync word, MSB-first (bit 23 first)
    for i in range(SYNC_BITS):
        bits[i] = (SYNC_WORD >> (SYNC_BITS - 1 - i)) & 1

    # payload, byte counter, each byte MSB-first
    for k in range(PAYLOAD_BYTES):
        byte = (frame_idx + k) & 0xFF
        base = SYNC_BITS + k * 8
        for b in range(8):
            bits[base + b] = (byte >> (7 - b)) & 1

    return bits


def build_bitstream(n_frames: int) -> np.ndarray:
    """n_frames laid back-to-back, continuous (no inter-frame gap)."""
    return np.concatenate([build_frame_bits(f) for f in range(n_frames)])


def msk_modulate(bits, fs, baud, fc, fd, amp):
    """Continuous-phase MSK -> complex baseband at sample rate fs.

    Instantaneous frequency f[n] = fc + fd*(2*bit-1); phase integrates so
    it stays continuous across symbol boundaries (true CPFSK, no glitches).
    Non-integer samples-per-symbol (fs/baud = 369.004) is fine -- the bit
    for sample n is chosen by time, not by a fixed sample count.
    """
    n_samples = int(np.ceil(len(bits) * fs / baud))
    n = np.arange(n_samples)
    sym_idx = np.minimum((n * baud / fs).astype(np.int64), len(bits) - 1)
    bit = bits[sym_idx].astype(np.float64)

    f_inst = fc + fd * (2.0 * bit - 1.0)            # Hz per sample
    phase = 2.0 * np.pi * np.cumsum(f_inst) / fs     # continuous phase
    s = amp * np.exp(1j * phase)
    return s, n_samples


def write_stimulus(path, s, noise_amp=0.0, seed=1):
    """Write 'iv qv' signed-16 per line. Optional AWGN (noise_amp = RMS)."""
    iv = np.round(s.real).astype(np.int64)
    qv = np.round(s.imag).astype(np.int64)
    if noise_amp > 0.0:
        rng = np.random.default_rng(seed)
        iv += np.round(rng.normal(0.0, noise_amp, iv.size)).astype(np.int64)
        qv += np.round(rng.normal(0.0, noise_amp, qv.size)).astype(np.int64)
    iv = np.clip(iv, -32768, 32767)
    qv = np.clip(qv, -32768, 32767)
    with open(path, "w") as fh:
        fh.write("\n".join(f"{int(a)} {int(b)}" for a, b in zip(iv, qv)))
        fh.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out",      default="opv_chan_stim.txt")
    ap.add_argument("--frames",   type=int,   default=5,
                    help="number of back-to-back frames (>=4 to reach LOCK_FRAMES=3)")
    ap.add_argument("--fs",       type=float, default=20.0e6, help="input sample rate")
    ap.add_argument("--baud",     type=float, default=54200.0)
    ap.add_argument("--fc",       type=float, default=110130.0, help="MSK centroid IF")
    ap.add_argument("--fd",       type=float, default=None,
                    help="freq deviation (default baud/4 = true MSK h=1/2)")
    ap.add_argument("--amp",      type=float, default=3000.0, help="signal peak (ADC-like)")
    ap.add_argument("--noise",    type=float, default=0.0,   help="AWGN RMS (0 = clean)")
    args = ap.parse_args()

    fd = args.fd if args.fd is not None else args.baud / 4.0

    bits = build_bitstream(args.frames)
    s, n_samples = msk_modulate(bits, args.fs, args.baud, args.fc, fd, args.amp)
    write_stimulus(args.out, s, noise_amp=args.noise)

    sps_in   = args.fs / args.baud
    sps_chan = (args.fs / 2.0 / 16.0) / args.baud     # after /2 decim, /16 channelize
    dur_ms   = n_samples / args.fs * 1e3
    print(f"wrote {args.out}")
    print(f"  frames        : {args.frames}  ({FRAME_BITS} bits/frame, "
          f"sync=0x{SYNC_WORD:06X}, payload={PAYLOAD_BYTES} B)")
    print(f"  bits total    : {len(bits)}")
    print(f"  samples       : {n_samples}  ({dur_ms:.2f} ms sim @ {args.fs/1e6:.0f} Msps)")
    print(f"  SPS @ input   : {sps_in:.3f}   SPS @ channel : {sps_chan:.3f}")
    print(f"  centroid fc   : {args.fc:.0f} Hz  ({args.fc/((args.fs/2/16)/1):.4f} of chan rate)"
          .replace('/1)', ')'))
    print(f"  tones         : {args.fc-fd:.0f} / {args.fc+fd:.0f} Hz  (fd={fd:.0f}, "
          f"spacing={2*fd:.0f} = baud/2={args.baud/2:.0f})")
    print(f"  amplitude     : {args.amp:.0f} peak"
          + (f", + AWGN RMS {args.noise:.0f}" if args.noise > 0 else " (clean)"))


if __name__ == "__main__":
    main()
