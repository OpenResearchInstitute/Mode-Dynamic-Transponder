# Statement of Work: Scaling the de Buda Demodulator from 1 to 64 Channels

**Project:** Mode-Dynamic-Transponder / Haifuraiya receiver
**Scope:** Take the proven single-channel de Buda MSK demodulator and scale it to all
64 Opulent Voice channels using 16:1 time-sharing, share the per-channel power
detector, integrate the DVB-S2 encoder, and verify the design fits and routes on
both the ZCU102 (ZU9EG, terrestrial build) and the VCK190 (XQRVC1902, flight path).
**Status:** DORMANT. Do not start until the entry gate (Section 2) is met.
**Baseline decision:** 16:1 time-sharing (4 demod cores). Not 8:1.

---

## 1. Why this SOW exists (context)

The current build has ONE demod wired to a single target channel. Measured on the
ZCU102 (xczu9eg), the placed system is 1,647 DSP (65%), 141,540 LUT (52%), 34.5 BRAM
tiles (4%). The channelizer already carries all 64 channels; only the demod is
single-channel. A naive 64x parallel demod is 64 x 77 = 4,928 DSP and fits no single
part. Time-sharing is therefore mandatory, not an optimization.

Key facts established during analysis, to be treated as the design's ground truth:

- **The demod datapath is fully pipelined, one sample per clock.** The CORDIC is a
  16-stage registered pipeline (STAGES=16), the de Buda FIR is direct-form
  "once per valid sample," square and mix are single-cycle. End-to-end latency is
  about 25 clocks; throughput is 1 sample/clock.
- **Each channel produces one sample every 160 clocks** (625 kSps at 100 MHz;
  4x oversampled, 11.53 samples/symbol, 54.2 kbaud). So one channel uses ~1/160 of a
  datapath's capacity. This idle is per-channel and independent of how many channels
  are built; it is the headroom that makes time-sharing fit.
- **Aggregate load is 64 x 625 kSps = 40 Msps**, i.e. one sample every 2.5 clocks of
  budget against a datapath that delivers one per clock.
- **The channelizer is already DSP-minimal.** Its ~1,096 DSP is the result of
  constant-coefficient pruning by the tool (the polyphase prototype has many trivial
  taps). It is fixed. DO NOT attempt to refold it.

---

## 2. Entry gate (execution trigger)

This SOW begins ONLY when ALL of the following are true for the single-channel
de Buda demod on the ZCU102:

1. Bit-accurate in RTL simulation against `debuda_fixedpoint_model.py`
   (0% BER clean; correct behavior with noise and with carrier/timing offset).
2. Carrier loop (common de Buda 2fc path) and both tone loops (f1, f2) acquire and
   hold lock in hardware, verified by ILA on the ZCU102.
3. Frame sync detect produces correct frames on a live or injected single channel.
4. The single-channel RTL is tagged in git as the GOLDEN REFERENCE. Every work
   package below is validated bit-for-bit against this reference extended to N
   channels. No work package is "done" until its regression passes.

Until this gate is met, this document is a plan, not an active task.

---

## 3. Target budget (what "done" must measure)

All figures are DSP. Measured values are from the hierarchical utilization report and
per-block synthesis; projected values are flagged.

| Component | DSP | Source |
|---|---|---|
| Channelizer core (filterbanks + FFT + decimator + EQ) | ~1,096 | measured, fixed, do not touch |
| Shared power detector (replaces 64 parallel) | ~15 | projected (replaces measured ~460) |
| Demod cores: 4 x 77 (16:1) | 308 | measured per-demod x core count |
| DVB-S2 encoder | ~64 | dvb_fpga post-impl, projected into this build |
| AXI / JESD / plumbing | ~12 | measured |
| **Total** | **~1,495** | |

Fit target:

| Part | Board | DSP avail | Utilization | Verdict |
|---|---|---|---|---|
| ZU9EG | ZCU102 (terrestrial) | 2,520 | ~59% | routes comfortably |
| XQRVC1902 | VCK190 (flight path) | 1,968 | ~76% | routes comfortably |

LUT is not the binding resource on either board (well under half on the ZU9EG, ~13%
on the Versal). DSP is the only tight axis, and it places in regular columns, which
tolerates high utilization better than fragmented logic. BRAM is expected comfortable
but is explicitly tallied in WP5.

Note on "folding required to hit these numbers": the only transforms REQUIRED to
reach ~1,495 DSP are the 16:1 demod interleave (WP1) and the shared power detector
(WP2). Symmetry-folding the de Buda FIR (WP3) is a RESERVE lever, not required for
the baseline, and is held unless WP5 shows margin pressure.

---

## 4. Per-demod DSP inventory (the thing being time-shared)

Measured, one `msk_demodulator` instance = 77 DSP:

| Sub-block | DSP | Notes |
|---|---|---|
| de Buda FIR (`fir_lowpass_complex`) | 46 | 25-tap complex, direct form, in the carrier loop |
| Costas loop f1 (`costas_loop`) | 8 | |
| Costas loop f2 (`costas_loop`) | 8 | |
| Carrier PI (`pi_controller`) | 4 | |
| Demod top glue | 11 | |
| CORDIC, sin/cos LUT, NCO | 0 | LUT/FF only |

Per instance also ~4,248 LUT, ~3,256 FF. When a core is time-shared across 16
channels, this arithmetic is REUSED across channels (still 77 DSP per core); only the
per-channel STATE grows and moves into RAM. Hence 4 cores = 308 DSP regardless of
channels-per-core.

---

## 5. Work packages

Dependencies: WP1 and WP2 are independent and can run in parallel. WP3 is optional and
gated by WP5. WP4 is independent. WP5 depends on WP1, WP2, WP4. WP6 depends on WP5.

### WP1 - Interleave the demod core to 16:1 (the main effort)

Convert the single-channel demod into a channel-interleaved core serving 16 channels,
instantiated 4 times to cover all 64.

**Timing basis:** 4 cores, 16 channels each = 10 Msps/core = one sample every 10
clocks per core. Datapath latency is ~25 clocks, so about 3 samples are in flight per
core at once. Because a given channel's samples are 160 clocks apart (>> 25), the
same channel is never in the pipeline twice, so there is no same-channel state hazard.

**State that becomes channel-indexed RAM** (read at pipeline input by incoming channel
tag, written back at pipeline output by the tag that emerges):

- de Buda 2fc NCO phase accumulator
- Costas f1 NCO phase accumulator
- Costas f2 NCO phase accumulator
- common carrier PI accumulator
- f1 and f2 loop-filter accumulators
- lock-detect state (per channel) for common, f1, f2
- de Buda FIR 25-tap complex delay line (16 x 25 samples per core)
- any timing-recovery / symbol-clock state

**Structure:**

- Add a channel-tag pipeline that flows the channel index alongside the sample through
  all ~25 stages (this is the AXI TDEST carried inline).
- Replace state registers with dual-port RAM (1 read + 1 write per clock),
  addressed by channel index.
- Assign channels to cores in whatever pattern makes the channelizer output ordering
  and the state-RAM addressing simplest (e.g. core c serves channels c, c+4, ... or a
  contiguous block of 16; pick after inspecting the channelizer output schedule).

**Do NOT** change loop constants or filter math. The interleave preserves loop
dynamics exactly: each channel's feedback still round-trips in ~25 clocks against its
own 160-clock sample period, identical transport delay to the golden single-channel
loop. If a loop needs re-tuning after interleaving, something is wrong with the state
addressing, not the loop.

**Acceptance:** a 16-channel core produces output bit-identical to 16 independent
golden single-channel demods running the same 16 stimulus streams, all 16 channels
concurrently. Regress against the WP0 golden model. Then confirm 4 cores cover 64.

### WP2 - Share the power detector (64 parallel -> 1 time-shared)

Replace the 64 `power_detector` instances (~460 DSP) with one datapath plus a 64-entry
state RAM (~15 DSP).

**Function preserved:** the detector provides per-channel AGC normalization and a
per-channel activity/squelch flag. It taps the CONTINUOUS pre-demod round-robin
channelized sample stream, NOT the gated post-frame-sync AXI bursts (those go silent
between frames, which is exactly when the level estimate must be retained).

**Structure:**

- Channel counter k = 0..63 locked to the channelizer output schedule addresses the
  state RAM.
- Per sample: compute |x|^2 = I^2 + Q^2, read channel k's stored 2-stage EMA state,
  run the same `lowpass_ema` recurrence twice, write back to address k.
- Output per-channel power to (a) the per-channel normalization multiply at the demod
  core input and (b) the per-channel activity flag.

**Update rate is unchanged.** Each channel still produces one sample per frame, so a
shared detector visiting each channel once per frame updates at the identical rate a
parallel detector would. AGC responsiveness is not affected. This is a functionally
transparent change; it is only a resource change.

**Timing:** one-per-clock read-modify-write pipeline over the RAM; no cross-channel
feedback, so it closes trivially.

**Acceptance:** per-channel power estimates bit-match the 64-parallel version on the
same stimulus; AGC-normalized demod output is unchanged.

### WP3 - de Buda FIR symmetry fold (RESERVE, only if WP5 shows pressure)

The de Buda FIR is 46 DSP, direct-form, 25-tap, with symmetric (palindromic)
coefficients. Symmetry folding via the DSP48E2 pre-adder halves the multiplies to
~24 DSP per core WITHOUT adding pipeline latency (the pre-adder is same-cycle), which
matters because this FIR sits INSIDE the carrier loop and its latency must not grow.

**This is not required for the 16:1 baseline** (which already lands at ~76% on the
flight part). Hold it as a reserve lever for use only if WP5 reveals routing/timing
pressure or a later need for a fifth core or more channels.

**Do NOT** move this FIR to AI Engines. It is in the carrier feedback loop; AI Engine
transport latency would degrade loop phase margin. It stays in fabric.

**Acceptance (if executed):** folded FIR output bit-matches the unfolded within
rounding; loop acquisition and hold behavior unchanged versus golden.

### WP4 - DVB-S2 encoder integration

Integrate the dvb_fpga TX chain (BCH, LDPC, bit interleaver, mapper, PL framing,
pulse shaper). This is greenfield: the current build is receive-only.

- Budget ~64 DSP (almost all in the pulse-shaping filter), ~6.5k LUT, ~20 BRAM. The
  LDPC and BCH encoders are BRAM/LUT-resident, not DSP.
- Feed the encoder from the multiplexed 64-channel frame stream (TDM assembly of the
  demodulated OPV frames into DVB-S2 baseband frames).
- The pulse-shaper DSP number moves if rolloff/oversampling/tap count differ from the
  dvb_fpga default; re-measure on integration. It stays a small line item.

**Acceptance:** encoder output matches dvb_fpga reference vectors; end-to-end
OPV-frame-in to DVB-S2-baseband-out validated against a software reference.

### WP5 - Integration and budget verification on ZCU102

Assemble the full 64-channel receive+encode chain: channelizer, 4 x 16:1 demod cores,
shared power detector, frame sync, DVB-S2 encoder, AXI to the PS.

- Run `report_utilization -hierarchical` and `timing_summary` (post-route).
- Verify total DSP ~= 1,495 and within budget; verify WNS >= 0 at the target clock.
- Tally BRAM explicitly. New consumers: the interleaved demod state RAMs (per-channel
  NCO/PI/lock/delay-line state x 64), the shared-detector 64-entry state RAM, and the
  DVB-S2 LDPC tables. Confirm within the 912-tile budget (prior build was ~4%).
- Compare measured against the Section 3 target table; investigate any block that
  exceeds its projection by more than ~10%.

**Acceptance:** all 64 channels demodulate concurrently (ILA-verified with multi-
channel injected stimulus or on-air), DSP within budget, timing closed, BRAM within
budget.

### WP6 - Retarget to VCK190 / XQRVC1902 (flight de-risk)

Retarget the identical RTL to the VCK190 (XCVC1902, the commercial twin of the flight
XQRVC1902).

- Confirm ~1,495 DSP maps to ~76% of the 1,968 DSP58 and routes and closes timing.
- The AI Engine offload of the channelizer is explicitly OUT OF SCOPE here; it is a
  future growth lever. Keep the channelizer in fabric so one codebase serves both
  boards.
- Radiation mitigation (configuration scrubbing, TMR, SEFI recovery) is a SEPARATE
  flight work item and is NOT part of this SOW.

**Acceptance:** 16:1 build routes and closes timing on the VCK190 at the target clock.

---

## 6. What NOT to do (guardrails)

- Do not refold or re-optimize the channelizer filterbanks. They are already
  DSP-minimal via constant-coefficient pruning. Effort there yields nothing.
- Do not drive the power detector from the post-frame-sync AXI bursts. It must tap the
  continuous pre-demod stream or it loses the level estimate when a channel is quiet.
- Do not move the de Buda FIR (or any in-loop filter) to AI Engines. Loop latency.
- Do not change loop constants when interleaving. Preserved dynamics are a
  correctness check, not a tuning opportunity.
- Do not treat 8:1 as the safe fallback for the flight part. 8:1 is ~91% DSP on the
  XQRVC1902 and is not expected to route with margin. 16:1 is the baseline for both
  boards precisely so one codebase routes on both.

---

## 7. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| State-hazard bug in the WP1 interleave | Medium | High | Bit-exact regression vs golden; provable no same-channel collision (25 << 160) |
| BRAM blows up from per-channel state | Low | Medium | Explicit tally in WP5; state is small per channel |
| DVB-S2 pulse-shaper DSP higher than 64 | Low | Low | Small line item; re-measure on integration; WP3 reserve available |
| Timing not closing at 16:1 on Versal | Low | Medium | 1/clock datapath has margin; WP3 fold and pipeline registers in reserve |
| Scope creep into AIE / radiation work | Medium | Medium | Explicitly out of scope (WP6 note) |

---

## 8. Deliverables

1. Interleaved 16:1 demod core RTL + testbench + golden regression (WP1).
2. Shared power detector RTL + regression (WP2).
3. DVB-S2 encoder integrated into the datapath + reference-vector regression (WP4).
4. Full 64-channel build with hierarchical utilization and post-route timing reports
   on ZCU102 (WP5) and VCK190 (WP6).
5. Updated budget table (measured vs this SOW's projections) with any deltas explained.

---

## 9. One-line summary

When the single-channel de Buda demod is proven bit-accurate, interleave it to 16:1
(4 cores) and share the power detector; that alone lands the full 64-channel receiver
plus DVB-S2 at ~1,495 DSP, which routes with margin on both the ZCU102 and the VCK190,
with de Buda FIR folding held in reserve and AI Engine offload and radiation mitigation
deferred to later work.
