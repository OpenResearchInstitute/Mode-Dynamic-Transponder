# core_tone_check: bare-channelizer tone verification

Measures four properties of haifuraiya_channelizer_top with GHDL, no Vivado:

1. Bin mapping: +781.25 kHz lands in raw FFT bin 59 = relabeled channel 5
   (relabel (N - k) mod N lives in haifuraiya_channelizer_axi, not the core;
   this bench reports both).
2. Adjacent rejection at the probe offset.
3. Oversampled-output derotation: a +10 kHz offset inside the channel comes
   out at +10 kHz, not at +/-156.25 kHz (which is what a missing or
   wrong-sign (-j)^(k*m) rotation produces for k mod 4 /= 0).
4. Conjugation: the sign of the in-bin tone. +in -> +out means the channel
   stream is a faithful complex-baseband downconversion (no spectral flip).

## Run

    python3 gen_tone_stim.py
    ghdl -a --std=08 haifuraiya_coeffs_pkg.vhd fft_pkg.vhd \
        polyphase_filterbank_parallel.vhd r2sdf_stage.vhd r2sdf_reorder.vhd \
        r2sdf_fft.vhd haifuraiya_channelizer_top.vhd tb_core_tone.vhd
    ghdl -e --std=08 tb_core_tone
    ghdl -r --std=08 tb_core_tone -gSTIM_FILE=tone_p.txt -gOUT_FILE=chan_out_p.txt
    ghdl -r --std=08 tb_core_tone -gSTIM_FILE=tone_m.txt -gOUT_FILE=chan_out_m.txt
    python3 analyze_tone.py

Runtime is about five minutes per tone with ghdl-mcode (the 1536-deep shared
buffer dominates). Also checks frame_dropped == 0 and channel_last on the
core's raw idx 63 for every frame.

## Measured 2026-07-14 (GHDL 4.1.0, files as received)

    input +791.25 kHz: raw bin 59 -> relabeled channel 5,
        next bin 35.5 dB down, in-bin tone +10121 Hz (FFT bin quantization)
    input -791.25 kHz: raw bin 5 -> relabeled channel 59,
        next bin 35.5 dB down, in-bin tone -10121 Hz
    dropped_frames = 0, bad_last_beats = 0 in both runs

Conclusion: +frequency maps to +relabeled channel, the per-bin derotation is
present and has the correct sign, and the channel output is NOT conjugated.

## Chain bench (batch 2): tb_chain_tone.vhd

Adds halfband_decimator in front of the core, driven at 20 Msps -- the
production input path. Compile halfband_taps_pkg.vhd and
halfband_decimator.vhd before it. Three stimuli:

    +791.250 kHz            signal check, expect channel 5, in-bin tone +10 kHz
    +5.16625 MHz            alias probe: folds across the 10 Msps boundary
    -4.85375 MHz            direct reference at the same landing channel (33)

## Measured 2026-07-14 (chained RTL, GHDL 4.1.0)

    +791.25 kHz  -> raw bin 59 -> channel 5, in-bin tone +10.5 kHz, no drops
    alias probe  -> raw bin 31 -> channel 33, in-bin tone +10.5 kHz, rms 3.32e7
    reference    -> raw bin 31 -> channel 33, in-bin tone -10.5 kHz, rms 9.55e7

    measured alias rejection at the ch33 edge: 9.18 dB
    analytic |H(4.854M)|/|H(5.166M)| from HB_TAPS: 9.18 dB   (exact match)

CORRECTION (2026-07-14, caught in review): an earlier revision of this note
claimed the aliased tone arrives "frequency-flipped" in-channel as a
diagnostic signature. That was WRONG. Complex 2:1 decimation aliases by
pure TRANSLATION (f -> f - 10 MHz), not mirroring: an interferer at
+5.15625 MHz + delta lands at channel-33 center + delta with its spectral
orientation PRESERVED, indistinguishable in-channel from a co-channel
station. The mirrored offsets in the measurement above (+10.5 vs -10.5 kHz)
came from the probe and reference tones being placed at mirrored offsets BY
CONSTRUCTION (fold-point + 10 kHz vs channel-center - 10 kHz). The
rejection numbers are unaffected. Practical consequence: fold-over cannot
be identified by any in-channel spectral signature, which strengthens the
case for marking channels 31/33 in the channel plan.

## Per-channel alias protection (from HB_TAPS, EQ-ROM-validated model)

    ch 27 (and 37):  92.6 dB      ch 30 (and 34):  19.1 dB
    ch 28 (and 36):  53.2 dB      ch 31 (and 33):   8.9 dB
    ch 29 (and 35):  32.5 dB      ch 32: Nyquist wrap, do not use

The channel_eq ROM matches 1/|H(f_center)| of these taps to better than
0.02 dB at every entry, and is mirror-symmetric about ch32, so the
(N - k) mod N relabel cannot mis-apply it.
