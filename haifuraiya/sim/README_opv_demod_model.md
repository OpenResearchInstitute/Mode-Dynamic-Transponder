# demod_phase0: Python golden model of the coherent MSK demodulator

## Phase 0a status: VALIDATED (2026-07-15)

opv_demod_model.py is a float transliteration of opv-cxx-demod's
CoherentMSKDemodulator, channelized mode, function for function:

    corr_at              interpolating tone correlators (Catmull-Rom cubic,
                         M = max(12, round(sps)) sub-points, phase-continuous
                         absolute LO reference, cached rotator power tables)
    track_correlations   PI timing loop, ML-gradient TED on the dominant tone
                         (EL 0.5, alpha 0.06, beta 0.0025, clamps 0.05 / 2.0)
    combine              decision-switched Costas (Hodgart, a=0.01 b=2e-4)
                         + Massey 2T combine + differential boxplus
                         -> both parity streams
    resolve              parity + polarity by best |normalized sync corr|
    (validation tail)    quantize / 67x32 deinterleave / WAVA tail-biting
                         Viterbi (G1 0x67, G2 0x76, WAVA_W 48) / CCSDS
                         derandomize -- hardware-wise these are
                         frame_sync_detector_soft + opv-decode on the A53;
                         included here only to close the validation loop.

Validation on chan5_iq.cs16 (the canonical channelizer-output stimulus):

    symbols demodulated : 23945        (C++ binary: 23945 -- exact match)
    frames decoded      : 10           (C++: 10)
    payload bytes       : ALL 10 FRAMES BYTE-IDENTICAL to opv-demod -c
                          -R 625000 -r output (1340/1340 bytes)
    metrics             : same order of magnitude per frame (float64 vs the
                          C++ float32 MAC differ in ULPs; payloads identical)

The C++ modem was NOT modified. The reference stays the reference.

## Scope note

The model's demodulator scope = the future VHDL demodulator scope:
complex channel IQ in (625 ksps, sps 11.5314), resolved soft stream out.
The frame extractor here is a batch stand-in for the (already proven)
fabric frame_sync_detector_soft; it deliberately uses the same
hunt-strictly (0.85) / hold-loosely (0.70) two-threshold doctrine.

## Phase 0b (next): fixed point

Quantize node by node, in this order, with a dump hook and a float-vs-fixed
diff at each step:
  1. input scaling contract (16-bit normalized channel samples, as-is)
  2. interpolator (Catmull-Rom coefficient arithmetic -> Farrow form widths)
  3. rotator tables and LO phase accumulator (the SYM_SPS_FP Q16 word and a
     tone phase accumulator; sincos -> LUT widths from the pluto_msk
     sin_cos_lut submodule)
  4. correlator accumulators (M=12 MAC growth)
  5. TED arithmetic (the division: replace err/|ya|^2 with a normalized
     shift-based form -- the one true design decision in the port; candidate:
     amplitude-normalized input makes |ya| near-constant, so a constant-scale
     TED with model-measured slope may suffice; decide by Eb/N0 sweep)
  6. timing PI accumulators (freq/adj clamps in fixed point)
  7. Costas (theta accumulator width, the |act| normalize -> same treatment
     as 5)
  8. Massey/boxplus (trivial), soft output scaling to the frame-sync
     amplitude contract (mean|soft| target 17300)
Acceptance: <= 0.2 dB loss vs the float model across an Eb/N0 sweep at
sps 11.5314, and byte-identical decode on chan5_iq.cs16.
