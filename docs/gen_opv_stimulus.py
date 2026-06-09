#!/usr/bin/env python3
"""
gen_opv_stimulus.py  --  channelizer-input stimulus for the Haifuraiya RX sim.

Pipeline (forward model of the real signal path):
    opv-mod (correct OPV MSK burst, complex int16 @ 2.168 MSps, centered at DC)
      -> resample to the channelizer input rate (default 10 MSps complex)
      -> shift up to TARGET_CHANNEL's center + a real IF inside the channel
      -> scale to int16 with headroom
      -> write "I Q" integer pairs, one sample per line

The TB's stimulus process reads the file and calls send_sample(I, Q) per line
(I -> s_axis_data_tdata[15:0], Q -> [31:16]), feeding the channelizer exactly as
the ADRV9002 would.

WHY an IF (not channel center): opv-mod's baseband is symmetric about DC, so the
I-only MSK demod would fold +13550 onto -13550 at channel center and never lock.
Shifting the burst to a positive IF (default +baud/2 = +27100 Hz) puts the two
MSK tones at +13550 and +40650 in the channel baseband -- both positive, both
inside the +/-78 kHz half-channel -- so the demod's two NCOs can separate them.

The script PRINTS the channel-baseband tone locations and the matching NCO freq
words so the TB constants and the stimulus stay consistent.

Faithfulness note: this never reimplements the modem -- opv-mod is the single
source of truth for the waveform. Only resample + frequency shift happen here.
"""
import argparse, subprocess, sys
import numpy as np
from scipy.signal import resample


def channel_center_hz(k, n_channels, fs_in):
    """FFT bin -> frequency. Channels 0..N/2 are positive; N/2..N-1 are negative."""
    spacing = fs_in / n_channels
    kk = k if k <= n_channels // 2 else k - n_channels
    return kk * spacing


def nco_freq_word(f_hz, channel_rate, nco_w=32):
    """Demod NCO tuning word for a tone at f_hz in the channel baseband."""
    w = int(round((f_hz / channel_rate) * (1 << nco_w))) & ((1 << nco_w) - 1)
    return w


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--opv-mod", default="opv-mod", help="path to opv-mod binary")
    ap.add_argument("--callsign", default="W5NYV")
    ap.add_argument("--frames", type=int, default=4, help="BERT frames (lock needs >=~4)")
    ap.add_argument("--preamble", action="store_true", help="prepend one preamble frame")
    ap.add_argument("--iq-in", default=None,
                    help="use this raw int16 I/Q file instead of running opv-mod")

    ap.add_argument("--fs-in", type=float, default=10e6, help="channelizer input rate")
    ap.add_argument("--fs-opv", type=float, default=2168000.0, help="opv-mod output rate")
    ap.add_argument("--n-channels", type=int, default=64)
    ap.add_argument("--m-decimation", type=int, default=16)
    ap.add_argument("--baud", type=float, default=54200.0)

    ap.add_argument("--channel", type=int, default=0, help="TARGET_CHANNEL")
    ap.add_argument("--if-offset", type=float, default=None,
                    help="IF inside the channel (Hz); default = +baud/2")
    ap.add_argument("--scale", type=float, default=0.5,
                    help="amplitude scale into int16 (headroom vs channelizer overflow)")
    ap.add_argument("--guard-samples", type=int, default=2000,
                    help="zero samples before/after the burst (AGC settle, clean wrap)")
    ap.add_argument("--noise-snr", type=float, default=None,
                    help="optional AWGN SNR in dB (default: clean)")

    ap.add_argument("--out", default="opv_chan_stim.txt")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    if_offset = args.if_offset if args.if_offset is not None else args.baud / 2.0
    channel_rate = args.fs_in / args.m_decimation
    spacing = args.fs_in / args.n_channels
    rng = np.random.default_rng(args.seed)

    # --- 1. get the OPV burst (complex int16 @ fs_opv, centered at DC) ---
    if args.iq_in:
        raw = np.fromfile(args.iq_in, dtype="<i2")
    else:
        cmd = [args.opv_mod, "-S", args.callsign, "-B", str(args.frames)]
        if args.preamble:
            cmd.insert(1, "-P")
        try:
            out = subprocess.run(cmd, capture_output=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as e:
            sys.exit(f"opv-mod failed: {e}\n(set --opv-mod to the binary path)")
        raw = np.frombuffer(out, dtype="<i2")
    iq = raw.astype(np.float64)
    base = iq[0::2] + 1j * iq[1::2]
    print(f"opv-mod: {len(base)} samples @ {args.fs_opv:.0f} Hz "
          f"({len(base)/(2168*40):.2f} frames-equiv)")

    # --- 2. resample fs_opv -> fs_in (FFT resample: exact rate, clean for an
    #        already heavily-oversampled +/-27 kHz signal) ---
    n_out = int(round(len(base) * args.fs_in / args.fs_opv))
    up = resample(base, n_out)

    # --- 3. shift to TARGET_CHANNEL center + IF ---
    f_abs = channel_center_hz(args.channel, args.n_channels, args.fs_in) + if_offset
    n = np.arange(len(up))
    up = up * np.exp(1j * 2 * np.pi * f_abs * n / args.fs_in)
    print(f"placed at f_abs = {f_abs:+.0f} Hz "
          f"(channel {args.channel} center {channel_center_hz(args.channel, args.n_channels, args.fs_in):+.0f} + IF {if_offset:+.0f})")

    # --- 4. guard + optional noise ---
    g = np.zeros(args.guard_samples, dtype=complex)
    sig = np.concatenate([g, up, g])
    if args.noise_snr is not None:
        p = np.mean(np.abs(up) ** 2)
        npow = p / (10 ** (args.noise_snr / 10))
        sig = sig + np.sqrt(npow / 2) * (rng.standard_normal(len(sig))
                                         + 1j * rng.standard_normal(len(sig)))

    # --- 5. scale to int16 with headroom ---
    peak = np.max(np.abs(np.concatenate([sig.real, sig.imag]))) or 1.0
    q = sig * (args.scale * 32760.0 / peak)
    I = np.clip(np.round(q.real), -32768, 32767).astype(np.int64)
    Q = np.clip(np.round(q.imag), -32768, 32767).astype(np.int64)

    # --- 6. write "I Q" per line ---
    with open(args.out, "w") as f:
        for ii, qq in zip(I, Q):
            f.write(f"{ii} {qq}\n")

    # --- 7. report tone locations + matching NCO freq words ---
    f1 = if_offset - args.baud / 4.0      # lower MSK tone in channel baseband
    f2 = if_offset + args.baud / 4.0      # upper MSK tone
    sps = channel_rate / args.baud
    print(f"\nwrote {len(I)} samples -> {args.out}")
    print(f"channel rate {channel_rate:.0f} Hz, SPS = {sps:.3f}  (NOTE: fractional)")
    print("channel-baseband MSK tones:")
    print(f"  f1 (lower) = {f1:+.0f} Hz  -> rx_freq_word_f1 = 0x{nco_freq_word(f1, channel_rate):08X}")
    print(f"  f2 (upper) = {f2:+.0f} Hz  -> rx_freq_word_f2 = 0x{nco_freq_word(f2, channel_rate):08X}")
    print("  (if no lock: swap f1/f2, flip --if-offset sign, or widen it; "
          "and retune Costas gains / symbol_lock for this SPS)")
    # rough sim cost
    print(f"\nsim feed: {len(I)} input samples @ {args.fs_in:.0f} Hz "
          f"= {len(I)/args.fs_in*1e3:.1f} ms of signal; "
          f"xsim wall time scales with this -- start small.")


if __name__ == "__main__":
    main()
