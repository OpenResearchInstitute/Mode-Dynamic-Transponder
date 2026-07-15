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

## Phase 0b session log (2026-07-15): the harness's first catch

New tools, all validated before use:
  opv_encode_model.py  encoder (randomize/tail-biting K=7/interleave) proven
                       two ways: metric-0 round trip through the
                       byte-validated decoder, AND zero sign disagreements
                       against the C++ modulator's actual on-air bits
                       (diag_soft.py on chan5_iq). CPM modulator at channel
                       rate proven by C++ demod decoding 4/4 frames.
  diag_soft.py         compares resolved soft signs against re-encoded truth
                       per frame; reports disagreement rate, periodicity
                       (mod 2/4/8/16/32/67), and magnitude statistics.
                       Baseline on a healthy platform: 0/2144 everywhere.
  ebn0_sweep.py        Eb/N0 sweep at the seam. Calibration VERIFIED:
                       Es = A^2*sps, Eb/N0 = Es/(2 sigma^2); the C++ NATIVE
                       batch path decodes 6/6 byte-correct at every level
                       from 20 down to 8 dB under this calibration.

FINDING (byte-correct FER, 6 frames/point, one noise seed per point):

    Eb/N0   native 40sps batch   625k fractional (C++ -R 625000)
     20            6/6                 2/5
     16            6/6                 2/5
     14            6/6                 6/6
     12            6/6                 6/6
     10            6/6                 0/6
      8            6/6                 1/5

The fractional-timing path (the dogu/channel-rate path -- the one the VHDL
demod transliterates) CYCLE-SLIPS stochastically under noise, seed-dependent
and largely SNR-independent: measured sync spacings of 2162..2172 symbols
against the true 2168, with local BER clean between slip events. The native
batch path (integer windows, no timing loop) is solid throughout. The
python model, being a faithful transliteration, exhibits the same behavior
-- which is correct Phase 0 behavior: the model matches the reference,
including its weaknesses.

Consequence for the design: timing-loop hardening is now a named Phase 0
work item, to be developed IN THE MODEL with this harness as judge
(candidates: preamble-aided acquisition, gain scheduling after lock, slip
detect/correct from the sync tracker, wider early-late spacing, TED
decimation), before any VHDL. The bench-validated dogu C++ path likely has
never been characterized at threshold at 625k; this table is that
characterization's first draft and is worth sharing with the team.

Also noted, unchased: opv-demod -c misdecodes when fed opv-mod's FULL-SCALE
output directly (amp ~32k); at amp 3000 the same signal decodes perfectly.
Worth a look someday; all harness work uses headroom-safe amplitudes.

## Outstanding: the keroppi decode anomaly

Still open from the session start: opv_demod_model.py on keroppi decoded
chan5_iq.cs16 to garbage (uniform ~2030 metrics) while the same code and
file decode cleanly elsewhere. The diagnostic is built for exactly this:

    python3 diag_soft.py chan5_iq.cs16 cxx_frames.bin

The periodicity table will name the fault class in one run: ~50% flat =
misalignment; a sharp mod-8 or mod-32 signature = byte/bit-order handling
difference (suspect numpy version behavior); zero disagreements = fault in
the decoder tail on that platform. Report the whole printout.

## RESOLVED (2026-07-15): the keroppi anomaly -- and a reference finding

diag_soft.py on keroppi showed the signature: syncs +1.000 at the exact
grid, payload dead-flat ~50% at FULL soft strength, no periodicity. Only
one stage can do that: parity selection. Confirmed by hypothesis probe:
the WRONG parity stream (dec1) ALSO exhibits a +1.000 normalized sync
correlation, one symbol offset, with garbage payload (decode metric ~2800
vs ~2 for the correct stream). resolve()'s single-best-peak rule is
therefore a TIE at 1.000 broken by floating-point dust: one machine's dust
picks dec0 (correct), keroppi's picks dec1, and every downstream symptom
follows. Not a numpy bug, not a decoder-tail bug: an under-determined
decision in the RECEIVER ALGORITHM, inherited faithfully from the C++.

Fix (opv_demod_model.py): resolve() is now DECODE-VERIFIED -- both
parities tail-decode one frame, the lower Viterbi metric wins (separation
~30 vs ~2800; unambiguous). Regression battery green: chan5 decode 10
frames byte-identical, codec round trip, mod->demod loop, diag baseline
0/2144.

Consequences:
  1. The C++ SyncTracker::resolve has the SAME latent degeneracy and is
     currently winning the tie by platform luck. Worth reporting with this
     writeup; a decode-verified (or multi-peak grid-consistency) rule is a
     small patch there.
  2. FABRIC DESIGN INPUT: the Phase-1+ hypothesis-resolver block cannot
     select on sync correlation alone. It must consult a stronger
     statistic -- decode quality fed back from the A53, dual-hypothesis
     frame_sync with deferred selection, or an equivalent. This is now a
     requirement, discovered before any VHDL was written.
