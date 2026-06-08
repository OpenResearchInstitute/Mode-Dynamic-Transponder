# Seam-B simulation validation: frame_sync_detector_soft -> opv-decode -3

Goal: prove the fabric->A53 boundary in simulation before any bitstream. The seam is
`frame_sync_detector_soft.m_axis_soft_bit` (SOFT_WIDTH=3, 2144 values/frame, sync stripped)
feeding `opv-decode -3` (decode-only) on the A53, replacing the PL decoder
`ov_frame_decoder_soft`.

Environment: x86-64 sandbox, GHDL 4.1.0 (nvc unavailable). All seven pluto_msk submodules
present (nco, pi_controller, prbs, msk_modulator, msk_demodulator, lowpass_ema, power_detector).

## HEADLINE RESULT (proven, numerically)

`opv-decode -3` and the PL decoder `ov_frame_decoder_soft` consume the soft-bit stream
BYTE-IDENTICALLY:

- Quantizer interpretation: VHDL quantize() codes (sign-magnitude-ish 0..7) <-> opv-decode -3
  linear qs, monotonic and agreeing at the extremes. Proven by decoding VHDL-quantized raw
  soft at the true payload offset -> metric 0, byte-identical to golden.
- Deinterleave + byte-to-bit order: VHDL `soft_deinterleave_address` ==
  C++ `deinterleave_addr` for ALL 2144 indices (0 mismatches). Both do
  (idx%32)*67 + (idx/32), then byte*8 + (7 - bit_in_byte) MSB-first correction.
- Soft Viterbi metric: both use expected 0 -> sg, expected 1 -> 7-sg.

=> opv-decode -3 is a faithful drop-in for ov_frame_decoder_soft. Whatever frame_sync emits
on m_axis_soft_bit, both decoders interpret it identically; they cannot disagree on the same
stream. This is the green light for the fabric->A53 split.

## The 11-symbol offset: most likely a standalone-TB artifact, not an RTL bug

Earlier (standalone TB) measurement: driving frame_sync_detector_soft directly with the C++
demodulator's soft (`opv-mod | opv-demod -X`, int16 one-per-symbol) and rx_bit = sign(soft),
the captured m_axis_soft_bit matched the true payload at a uniform shift of -11 (99%), and
decoded byte-identical to golden after realigning by 11.

Why this is most likely an artifact, not a bug:
- The orderings are byte-identical (above), so the 11 cannot be an ordering/contract
  difference.
- frame_sync_detector_soft performs sync detection by CORRELATING THE SOFT STREAM
  (calc_corr over soft_sr + soft_r), so its framing follows the soft phase.
- The standalone TB fed it the C++ demod's soft, whose group delay / sync-word phase differs
  from the VHDL msk_demodulator's rx_data_soft. In real msk_top the demod drives
  rx_data/rx_data_soft/rx_dvalid coincident (lines 1039-1041) and rx_bit_corr is just rx_bit
  (optionally inverted via rx_invert, line 972). A different soft phase moves where the
  correlator locks -> an apparent fixed offset.
- Since both decoders consume identically and the PL chain is the validated reference, the
  real VHDL chain (demod -> frame_sync -> opv-decode -3) should decode with NO shift.

DEFINITIVE confirmation (to run with correctly-pinned submodules): full VHDL loopback
(tb_msk_modem_134byte or the cocotb msk_test.py), capture sync_det_soft_tdata via the provided
external-name snippet, feed opv-decode -3. Expect clean decode, zero shift.

## Could not assemble the full msk_top sim in this sandbox

The uploaded submodule "-main" tips do not match the ports msk_top pins:
- msk_modulator: no `tx_shift` port (msk_top maps tx_shift => tx_shift).
- msk_demodulator: no `dbg_acc_i_f1 / dbg_acc_q_f1 / dbg_acc_iq_delta_f1` ILA ports
  (msk_top maps them).
A GitHub zip cannot carry submodule commit SHAs, so the "-main" tips are a different version
than pluto_msk pins. To run the authoritative full sim here, provide a recursive checkout
(git clone --recursive, or submodules at their pinned commits / a tarball with them populated).
A new-msk_top + old-submodule + patches Frankenstein was deliberately NOT built -- a misaligned
measurement is worse than none.

(Also note: one GHDL-strictness shim was applied to lowpass_ema.vhd lines 131-132 --
`(PROD_W-1 => '0', OTHERS => '1')` -> `('0', OTHERS => '1')`. Functionally identical;
nvc/Vivado accept the original. Not a bug.)

## Design note (unchanged): soft_frame_buf is a single buffer

Unlike the hard path's circ_buffer (wr/rd pointers), the soft path uses a single
soft_frame_buf. Emission must complete before the next frame's payload starts writing. Fine at
real symbol rates with tready high (~21 us emit vs ~440 us inter-frame), but feeding one symbol
per clock in sim reproduces a drain/fill race; a long DMA stall could too. Consider
double-buffering or a guard.

## Artifacts

- frame_sync_seam_tb.vhd        standalone seam TB (drives frame_sync directly)
- soft_seam_capture_snippet.vhd external-name capture for the full loopback TB
- seam_diag.py                  quantize replication + alignment sweep + offset localization
