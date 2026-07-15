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

## Session 2 log (2026-07-15): baseline established, loss hunt underway

BASELINE (ebn0_multiseed.py, 10 seeds x 8 frames, decode-verified resolve,
provenance-logged; her run, baseline_float.csv):
  - Model and C++ track within a few frames at EVERY point (transliteration
    control green across the whole curve). The curve therefore characterizes
    the reference itself, at channel rate, for the first time.
  - BER(clean) floor ~3e-2, level-INDEPENDENT from 16 down to 12 dB.
  - slipP 0.2..0.5 in the good region; 1.0 at and below 8 dB.
  - FER cliff ~9-10 dB vs the ~4.5 dB mission target: ~5 dB to recover.

FINDING (isolated, bankable): the Catmull-Rom interpolating correlator
loses ~3.6 dB of detection SNR vs a raw integer-sample correlator on the
same signal+noise (9.06 vs 12.62 dB coherent; ideal 13.01; M-independent).
The robust native 40sps path uses integer windows -- consistent.

EXPERIMENTS JUDGED AND REJECTED (flags remain in the model, default off):
  1. raw_decision (raw-window decision correlations, interpolated TED):
     slips WORSENED (plant/controller mismatch: decision timing quantized
     to integers while the TED regulates fractional position). Lesson: the
     decision correlator and TED must be redesigned TOGETHER. This remains
     the leading fix direction -- and the hardware-natural one -- but as a
     joint design, not a knob.
  2. gain_sched (post-lock loop gain reduction): everything worsened.
     Lesson (confirmed by genie decomposition): the decision-switched
     Costas performs systematic per-symbol demodulation work (locking
     theta=0 yields 50% BER); slowing it removes necessary tracking.

OPEN: ownership of the 3e-2 BER(clean) floor. Genie timing does NOT
remove it (timing jitter exonerated). Naive genie phase is invalid
(see above). NEXT INSTRUMENT: data-aided genie phase -- compute the true
per-symbol phase trajectory from the known transmitted bits and substitute
it for the Costas; the residual BER then cleanly splits detection loss
from phase-tracking loss. First experiment of the next session.

## Session 2, part 2: FLOOR ATTRIBUTED (2026-07-15)

Complete attribution chain for the ~3e-2 BER(clean) floor, each step
measured at 12 dB:
  - genie timing (fixed true grid):        floor unchanged -> timing OUT
  - clean-replay genie phase (the clean
    run's recorded Costas trajectory
    substituted on the noisy run):         floor unchanged -> phase OUT
  - decision-variable SNR (enc is linear
    in Y, so noise-only pipeline gives
    the exact noise part):                 13.9 dB, only 1.1 dB structural
                                           loss -> average SNR OUT
  - clean-signal |enc| eye distribution:   continuous weak tail; 3.6% of
                                           symbols below 0.25x median eye,
                                           min/median 0.0007
CONCLUSION: the floor is DATA-PATTERN-DEPENDENT EYE CLOSURE in the
single-T tone-correlator + Massey combine approximation of the MSK
matched receiver. ~3-4% of bit-transition patterns yield a nearly closed
eye on a CLEAN signal; noise flips those for free. The 3.6 dB correlator
SNR loss (session 2 part 1) is real but secondary.

Also measured en route: on a clean signal the Costas theta is
quasi-static (0.04 deg/symbol mean motion) -- it is a slow phase
reference, not a per-symbol tracker; the earlier theta=0 catastrophe was
about the converged offset value, not tracking dynamics.

## The solve target (next design work)

A correct 2T matched detection path: proper de Buda/Massey MSK reception
(2T-spaced matched correlations / half-sine weighted I-Q rails in the
offset-QPSK view), designed JOINTLY with a TED that shares its
observables -- per the experiment-1 lesson that the decision path and
timing loop must move together. Success criteria on the harness:
BER(clean) floor collapses toward theory, slip probability improves
(better observables feed the TED), C++ TX interop preserved (RX-side
change only), byte-identical decode on the clean canonical stimulus.
Then quantize (<=0.2 dB budget), then VHDL.

## Session 2, part 3: detection redesign underway (2026-07-15)

Design method: empirical, from the modulated signal itself (convention-safe).

PROVEN on clean signal:
  - Eye-closure mechanism confirmed precisely: equal-bit 2T windows put all
    energy in one tone arm (orthogonal, |Z|=72k); TRANSITION windows split
    it (42.5k/42.5k) and the old combine partially cancels -> the weak tail
    (80% of weak symbols are transitions).
  - The rail statistics S=Z1+Z2, D=Z1-Z2 (algebraically the half-sine
    weighted matched filters) have an OPEN eye: min/med 0.84, zero weak.
  - Angle bookkeeping decoded from raw scatter vs known bits: each tone
    arm's LO advances with its own tone, so the STRONG statistic's angle is
    frozen within same-bit runs and steps ~pi net per '0' bit. The
    information is in ANGLE DIFFERENCES; every axis-tracker architecture
    was structurally wrong (three were built and rejected en route:
    single tracker, quadrature-offset tracker, dual per-rail trackers --
    all defeated by the pi/2-per-symbol weighting slide and the
    data-dependent accumulated phase).
  - combine_v3 (max-select of S/D per window + differential phase
    U_k conj(U_{k-1})): eye min/med 0.49, ZERO weak symbols. Naive
    Re() decision reaches 76% bit match -- mapping incomplete because
    transition windows contribute half-angle steps.

NEXT (single well-defined task): derive the exact delta-phase -> bit
decision rule from the scatter table (candidates: 2-window-spaced
differential U_{k+1} conj(U_{k-1}); or quantized delta-angle alphabet
{0, +-pi/2, pi} with per-type bit meaning). Then: clean 100% match ->
noise BER at 12 dB (floor must collapse toward theory) -> full sweep vs
baseline_float.csv -> C++ TX interop check on the canonical stimulus ->
then TED co-design on the same statistics, quantization, VHDL.

## Session 3 (2026-07-16): detector derivation -- structure found, MLSE next

Method continued: measure, never assume. Key artifacts of the day:

MEASURED (definitive, spreads of 0.06 deg): the matched-arm phase-step
table by bit pair and window parity. Same-bit boundaries: exactly 0.
Transitions: +/-172.2 deg at even k, -/+7.7 deg at odd k, where
7.8 deg = 2*pi*13550/625000 = ONE SAMPLE of tone phase (the pos-grid
offset made visible). This table IS the arm-unification law:
  Q_k = Y2_k * exp(j*172.15deg) * (-1)^k
puts both tone arms on a single phase reference.

combine_v5 (2T MF bank on unified arms, signs (-1,+1,+1), noncoherent
magnitude scoring): 100.000% clean bit match, eye min/med 0.80, zero weak
symbols. THE EYE-CLOSURE PROBLEM IS SOLVED STRUCTURALLY.

combine_v6 (decision-directed axis tracker): rejected -- fights the pi
data flips. combine_v7 (squaring/double-angle EMA axis): correct axis
(99.4% clean), noise BER ~2.7e-2 -- no better than v5.

ROOT CAUSE of the remaining noise wall, understood and quantified:
per-window pair decisions have hypothesis distance T (adjacent pairs
share a symbol) -- a structural ~6 dB margin giveaway. Margin-T
prediction at 12 dB ~1e-2 matches measurement. MSK's full distance
(the MSK = BPSK result) requires SEQUENCE detection.

NEXT (well-defined): combine_v8 = 4-state MLSE (Viterbi) over the
unified coherent V-bank. MSK phase trellis: 4 states, branch metrics =
Re(V_hyp * e^-j*axis) with the squaring-loop axis, traceback ~16-32
symbols. All ingredients exist and are hardware-natural (the fabric
already has a 64-state Viterbi in the FEC; a 4-state one is trivial).
Gate: clean 100%, then 12 dB BER must approach theory-with-interpolator-
loss (~1e-4-ish), then full sweep vs baseline, then interop, then TED
co-design, quantization, VHDL.

## Session 3, part 2: MLSE derivation completed on paper, 94% in code

Answered en route: why not reuse the FEC Viterbi? The 67x32 interleaver
sits between modulation and code, so a joint super-trellis is impossible
by design (that would be turbo equalization). But the ENGINE is reused:
the 4-state MLSE is the same ACS+traceback pattern as viterbi_tailbiting
with different parameters, free-running, soft output (max-log margins).

DERIVED EXACTLY from the measured step table (unified variables):
  - phase step is pi iff the NEW bit is 0; 0 otherwise. Trellis state
    flip rule: s' = s if b_new==1 else -s. (The flip-on-change variant
    was tested and is WRONG: 67%.)
  - coherent bank signs for the trellis: V11 = Y1k+Y1k+1,
    V00 = Qk - Qk+1, V10 = Y1k - Qk+1, V01 = Qk + Y1k+1  [signs +,-,-,+].
    Note v5's magnitude bank tolerated a wrong V10 sign silently; the
    coherent trellis cannot -- magnitudes forgive, projections do not.

STATUS: pointer-correct 4-state MLSE (mlse4) reaches 94.05% clean with
exhaustively fitted signs. Remaining ~6% clean deficit is attributed to
the squaring-loop axis reference (EMA transient and/or half-pi ambiguity
mid-stream), not the trellis. First broken traceback (state
reconstruction instead of stored predecessors) caught by clean gate at
50% -- the gates work.

NEXT session, in order:
  1. Fix the axis reference: candidates -- per-survivor phase (classic
     MLSE-with-phase, elegant: each trellis path carries its own axis),
     or preamble-seeded axis with slow update, or block phase estimate.
  2. Gate: 100.000% clean. Then noise gauntlet at 12/10/8/6 dB --
     success = approach theory + interpolator loss (~1e-4 at 12 dB).
  3. Full multi-seed sweep vs baseline_float.csv; interop on the
     C++-modulated canonical file; TED co-design on the V-bank
     observables; quantization; VHDL.

## Session 4 (2026-07-16): THE FLOOR IS DEAD

mlse4_psp (4-state MLSE, per-survivor phase, derived constants) on the
unified coherent V-bank, genie timing:
    clean gate: 100.000%
    Eb/N0 12: BER 0 (>= ~47k bits)   [old floor 3.1e-2]
    Eb/N0 10: 8.5e-5   8: 1.3e-3   6: 8.7e-3
    => total implementation loss ~1.1-1.5 dB vs coherent MSK theory.
Components shipped in opv_demod_model.py: vbank_unified(), mlse4_psp().
Answer recorded: two Viterbis in series is the correct architecture
(4-state undoes the modulation memory, K=7 undoes the code memory; the
interleaver between them forbids merging and enables both).

REMAINING GATES before VHDL:
  1. Full-chain FER: mlse soft -> resolve/frame path -> byte-correct
     frames; interop on the C++-modulated canonical chan5 stimulus.
  2. Multi-seed sweep (ebn0_multiseed with --mlse) vs baseline_float.csv.
  3. TED co-design on V-bank observables (replace genie timing; the bank
     gives better timing observables than the old dominant-tone TED).
  4. Axis/PSP acquisition characterization within the preamble budget.
  5. Fixed-point quantization (<=0.2 dB), then msk_mlse4.vhd et al.

## Session 4, part 2: FULL-CHAIN GATES (2026-07-16) -- "Go flight"

BURN 1  full chain, clean, self-modulated:  6/6 frames, ALL METRICS 0. GO.
        (Required upgrading the python modulator to exact fractional-
        boundary CPM: the old per-sample tone switching carried +/-0.5
        sample transition jitter that the NEW receiver is sensitive
        enough to see (~metric 180) and the old receiver's floor had
        masked. The instrument outgrew its fixture; fixture fixed.)
BURN 2  interop, C++ opv-mod through channelizer (canonical chan5):
        10/10 frames byte-identical to the reference decode, including
        frame 1 (metric 30). GO. Required phase-diverse PSP init
        (states seeded at 0/45/90/135 deg) to cover axis acquisition.
BURN 3  8 dB noise, full chain with the OLD timing loop: 2/18.
        NOT a detector result: genie-timed MLSE at 8 dB is 1.3e-3 BER.
        The old TED slips at 8 dB with probability ~1.0 (baseline data);
        timing is now the sole threshold-setting element of the chain.

Chain as of this gate:
  timing loop (OLD, slip-prone)  <- the one remaining pre-VHDL component
  -> Y1,Y2 -> vbank_unified -> mlse4_psp (soft) -> extract/frame path
  -> K=7 decode. Everything right of the timing loop is proven clean
  and interoperable.

NEXT: TED co-design on the V-bank observables. The bank's winner
statistic gives a far better timing discriminant than the old dominant-
tone trick (full 2T energy, pattern-independent thanks to the open eye).
Candidates: early-late on |V_winner|, or ML gradient on the coherent
projection. Gates: slip-free at 8 dB over the sweep, acquisition within
the preamble, then the full multi-seed sweep (exact-CPM modulator) vs a
re-run baseline, then quantization, then VHDL.

## Session 5 (2026-07-16): THE DRAGON IS DOWN

TED co-design (V-bank winner early-late, same 3x-correlation cost and PI
plumbing as the old loop, error = (|Vw(late)|-|Vw(early)|)/|Vw(on)|):
  GATE 1 interop (canonical C++ chan5): 10/10 byte-identical. GO.
  GATE 2 8 dB full chain: 18/18 (old TED: 2/18). Slips eliminated.
  THRESHOLD HUNT (3 seeds x 6 frames, full chain):
      6.0 dB 17/18 | 5.0 16/18 | 4.5 16/18 | 4.0 10/18 | 3.5 6/18
  => mission target (~4.5 dB) MET. Cliff at ~4 dB = the K=7 code's own
  threshold: the demodulator is no longer the chain's limiting element.
  Old receiver cliff: ~9-10 dB. Recovered: ~5 dB, as quantified by the
  day-1 baseline.

Chain (all model, all proven): track_mlse (V-bank EL TED) -> vbank_unified
-> mlse4_psp -> extract/frame path -> K=7. Interop with untouched C++
modulator preserved at every gate.

REMAINING before fabric (bookkeeping, not design):
  1. Full multi-seed statistical sweep for the record (10 seeds, exact-CPM
     modulator, re-run baseline for apples-to-apples), acquisition-time
     characterization vs the preamble budget, metrics-jitter tuning
     (interop metrics 35-76 vs 7-36 with old TED: slight timing jitter,
     alpha/beta/EL tuning pass).
  2. track_mlse shipped into opv_demod_model.py as the default tracker.
  3. Fixed-point quantization (<=0.2 dB budget), node by node.
  4. VHDL: msk_mlse4.vhd + vbank + TED, dump-compare per block against
     the fixed-point model; frame sync and K=7 fabric blocks unchanged.
