# Channelizer -> MSK demod hookup (Haifuraiya, ZCU102 fabric path)

CURRENT plan (supersedes the stale "Path B: software demod" in haifuraiya_plan_of_attack.md):
  channelizer (PL) -> per-channel demux -> msk_demodulator (PL) -> frame_sync_detector_soft (PL)
  -> m_axis_soft_bit -> AXIS/DMA -> opv-decode -3 (A53, decode-only).

## The plan, plain version (do this)

1. Wire the channelizer's `m_axis_chans` into the demod. It carries complex I/Q
   (TDATA[31:16]=Q, [15:0]=I, 16-bit each), 64 channels TDM'd, TDEST=channel, TLAST on ch63.
   Feed the channel's I to the demod's rx_samples -- the demod is REAL-input, I-only (msk_top
   feeds it rx_samples_I; it forms its own I/Q internally via the NCO). Q is NOT used by the
   demod; msk_top routes Q only to a power_detector, and the channelizer already has per-channel
   power detection, so you likely don't need Q in this path. Set SAMPLE_W=16 to keep full width.
2. Single channel first: pass the channel through when TDEST==target, pulse the demod's
   sample-valid on those beats (~625 ksps for that channel).
3. Demod -> frame_sync exactly as msk_top wires it: rx_data->rx_bit_corr, rx_data_soft->soft,
   rx_dvalid->valid, demod_sync_lock = cst_lock_f1 AND cst_lock_f2.
4. frame_sync m_axis_soft_bit -> AXIS FIFO -> DMA -> A53 -> opv-decode -3.
5. Structure: a NEW wrapper one level up (the Haifuraiya equivalent of msk_top) instantiates
   `haifuraiya_channelizer_axi` + demod + frame_sync. Do NOT modify either channelizer file --
   the IP is timing-closed and packaged. `_top` is the wrong tap (40-bit, pre-channel_eq);
   `m_axis_chans` on the `_axi` wrapper is the equalized 16-bit I/Q you want.

Then build and watch the Costas lock (cst_lock_f1/f2). Everything downstream waits on it, so a
no-lock is loud and points straight at the next item.

## The one thing expected to need a nudge: rate / SPS retune

The demod's NCO freq words and Costas loop were tuned for SPS 40 @ 2.168 MSps. The channel comes
out near 625 ksps -> SPS ~11.53. Re-derive for the channel rate:
- rx_freq_word_f1/f2 (scale with the new fs / tone placement)
- Costas gains/shifts/alpha (loop bandwidth)
- symbol_lock_count / symbol_lock_threshold
- Watch the fractional SPS (~11.53 is non-integer): confirm symbol timing handles it, or pick a
  build rate that lands SPS friendlier. (Same sharp edge the frame_sync level-vs-peak bug lived on.)
If Costas won't lock, this is the knob.

## Build dependency closure (so you don't hit missing modules)

msk_demodulator has NO .gitmodules, so submoduling it alone won't pull its deps. Its costas_loop
directly instantiates work.pi_controller, work.nco, work.sin_cos_lut. Add into MDT:
- msk_demodulator  (pin 583faed)  -- costas_loop, costas_lock_detect, msk_demodulator
- nco              (pin 615fe5a)  -- nco.vhd + sin_cos_lut.vhd
- pi_controller    (pin d62c91e)
- frame_sync_detector_soft.vhd from pluto_msk (standalone, no deps -- submodule pluto_msk or
  just vendor the one file)
Full front-end source set: nco.vhd, sin_cos_lut.vhd, pi_controller.vhd, costas_lock_detect.vhd,
costas_loop.vhd, msk_demodulator.vhd, frame_sync_detector_soft.vhd.

## Validate in sim first (simulate before synthesize)

Single channel, before touching system_bd.tcl:
  complex OPV burst at the channel rate -> demod (retuned) -> frame_sync -> opv-decode -3.
Success = opv-decode -3 recovers the frame. The back half (frame_sync -> opv-decode -3) is
already validated byte-for-byte against the PL decoder; this splice is the only unproven joint.

## Key to getting Costas lock: the OPV signal must sit at a real IF in the channel

The demod is confirmed real-input (msk_top feeds it rx_samples_I only). It works on LibreSDR
because the OPV signal sits at a real IF in the captured band, not at DC. This matters at the
channelizer: each channel is centered at DC, and a DC-centered MSK signal is fatal to a real
(I-only) demod -- the two MSK tones are at +/- baud/4 and the real part cos(.) is identical for
+f and -f, so I-only cannot tell bit 0 from bit 1. The fix is to make sure each OPV signal lands
at a real IF *within* its channel, e.g. carrier ~+baud/2 off channel center so both tones are
positive and separable (tones at ~+13.6 kHz and ~+40.7 kHz, well inside the ~+/-78 kHz half-channel),
and set rx_freq_word_f1/f2 to that IF. Options to achieve it: uplink/LO frequency plan that offsets
the carrier in-channel, or a small per-channel complex->real-IF mix before the demod. Try the
straight I hookup with the OPV placed at an IF first; if Costas won't lock and the signal is at
channel center, this is why and this is the fix.

## Open items to confirm
- The channel rate for the actual ADRV9002 profile you're demoing at (tb_haifuraiya_channelizer_axi).
- 64x vs time-shared for full coverage (single channel first regardless).
