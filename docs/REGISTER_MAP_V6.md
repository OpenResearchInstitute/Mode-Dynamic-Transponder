# Haifuraiya Demodulator Register Map v6 — Normative Reference

License: CERN-OHL-S v2. VERSION: 0x0006_0000.
Demod AXI-Lite: base 0x84A8_0000 (system_bd.tcl:306, ad_cpu_interconnect
0x44A80000 + ADI 0x4000_0000 translation), aperture 4 KB
(haifuraiya_rx_axi.vhd:41, C_S_AXI_DEMOD_ADDR_WIDTH=12). Demod registers
occupy 0x000-0x0FF by convention; 0x100+ deliberately unused so demod and
channelizer offset styles stay visually distinct in devmem transcripts.
Channelizer: separate slave at 0x84A7_0000 (system_bd.tcl:301) -- no
shared decode.

RULE (RM-1, normative): a status bit is documented only with a citation of
the RTL line that drives it. Bits without a generation citation may not
ship. (Lesson: v5 demod_sync_lock -- an elapsed-symbol latch wearing a
lock detector's name, msk_demodulator_mlse.vhd G_LOCK_SYM.)

## Charter
1. **Works untouched** — every writable field resets to the proven value;
   a reuser at OPV rates configures nothing.
2. **Adjustable at the reuse surface** — runtime registers for anything a
   different deployment would change; each field documents who turns it
   and why. No operational parameter lives only in a generic.
3. **Documented for strangers** — units, defaults, derivations, citations
   in the RDL; VHDL uses named engineering-unit constants with in-code
   derivations (no magic numbers; `G_INC32`-style literals prohibited).

## Address summary
| Addr | Register | Access | Default | Subsystem |
|------|----------|--------|---------|-----------|
| 0x000 | VERSION | R | 0x00060000 | identity |
| 0x004 | CONTROL | RW | 0x00000000 | rx_invert=0 (bit0); rest reserved |
| 0x008–0x03C | RESERVED (retired Costas) | R=0 | — | see Retirements |
| 0x040 | STATUS | R | — | bit dictionary below |
| 0x044 | FRAMES_RX | R | — | frame sync |
| 0x048 | FS_HUNT_THRESH | RW | 85 % | frame sync |
| 0x04C | FS_VERIFY_THRESH | RW | 70 % | frame sync |
| 0x050/54/58 | QUANT_THR_1..3 | RW | 4942/9884/14826 | soft path |
| 0x05C | DEMOD_INIT | RW | 0 | init bracket |
| 0x060–0x09C | RESERVED (retired Costas) | R=0 | — | see Retirements |
| 0x0A0 | SYM_LOCK_STATUS | R | — | symbol lock |
| 0x0A4 | SYM_LOCK_THRESH | RW | 25 % (C++ LOCK_THRESH, verbatim) | symbol lock |
| 0x0A8 | SYM_UNLOCK_THRESH | RW | 50 % (C++ UNLOCK_THRESH, verbatim) | symbol lock |
| 0x0AC | SYM_LOCK_WINDOW | RW | window_log2=6 (64 sym) | symbol lock |
| 0x0B0 | CFO_STATE | R | — | CFO acquisition |
| 0x0B0 | CFO_STATE | R | 0 IDLE / 1 SEARCH / 2 CORRECTING / 3 HELD / 4 LOST (cfo_afc.vhd; LOST->SEARCH = the anti-wedge) | CFO |
| 0x0B4 | CFO_ESTIMATE | R | Hz signed | CFO acquisition |
| 0x0B8 | CFO_CTRL | RW | auto=1 | CFO acquisition |
| 0x0BC | CFO_MANUAL | RW | 0 Hz | CFO acquisition |
| 0x0C0 | CFO_QUALITY | R | 0.25 dB LSB | CFO acquisition |
| 0x0B0 | CFO_STATE | R | 0 IDLE / 1 SEARCH / 2 CORRECTING / 3 HELD / 4 LOST (cfo_afc.vhd; LOST->SEARCH = the anti-wedge) | CFO |
| 0x0B4 | CFO_ESTIMATE | R | applied CFO correction, Hz signed (manual word or, from WP2 step 2, the AFC estimate) | CFO |
| 0x0B8 | CFO_CTRL | RW | 0x00060A01: b0 auto, [15:8] alpha_trk shift (10 = 2^-10 ~ C++ 0.001), [23:16] alpha_acq shift (6 = 16x, provisional) | CFO |
| 0x0BC | CFO_MANUAL | RW | Hz signed 16; applied when auto=0. The falsifiability knob (red-first bench, design doc s.6) | CFO |
| 0x0C0 | CFO_QUALITY | R | windowed dominant-tone gauge (|re|+|im| >> 4, 64-sym mean); locked ~6k-22k, dead air ~0, floor 512 | CFO |
| 0x0C4 | TIM_ALPHA | RW | 0x0148 (0.005 Q16, C++ verbatim) | timing loop |
| 0x0C8 | TIM_BETA | RW | 0x00A8 (1e-5 Q24, C++ verbatim) | timing loop |
| 0x0CC | SYM_CLK_OFFSET | R | Q24 samples/symbol, signed | timing loop |
| 0x0D0 | FS_LOCK_FRAMES | RW | 3 | frame sync cfg |
| 0x0D4 | FS_FLYWHEEL_TOL | RW | 2 | frame sync cfg |
| 0x0D8 | FS_ENERGY_FLOOR | RW | 12288 | frame sync cfg |
| 0x0DC | FS_STATE | R | — | frame sync obs |
| 0x0E0 | CHANNEL_SEL | RW | 5 | demux |

Symbol-lock statistic (design revision 2026-07-20): the detector operates
on the NORMALIZED early-late ratio -- windowed 100*S|L-E| vs PCT*S(L+E),
the CFAR pattern shared with frame sync -- which is the reference C++'s
exact TED, (el-ee)/(el+ee) (opv_demod.hpp ~365), per the normalized
early-late gate of Mengali & D'Andrea 1997. Thresholds are dimensionless
percent; the C++ constants transfer verbatim (25/50); the metric is
amplitude-invariant, so NO level calibration exists or is required.
SYM_LOCK_STATUS[15:8] = live ratio_pct is the quality gauge Bouro plots.

Timing loop (design revision 2026-07-20 #2): the raw-error PI (measured
~67x proportional / ~1000x integral hotter than the reference in
normalized terms, plus a 4x acquisition gear the reference lacks) is
replaced by the C++ law verbatim (opv_demod.hpp:197-199,377-380):
ted=(L-E)/(L+E) via exact Q15 serial divide, adj = ted*ALPHA + clk_off,
clk_off += ted*BETA, clamp +/-0.1 sample. SYM_CLK_OFFSET (0x0CC) exposes
the integrator: the estimated symbol-clock rate error, Q24 fractional
samples per symbol (ppm = val*2^-24/11.5314*1e6). Bouro plots it; on a
healthy link it sits near the true TX/RX clock ppm, not random-walking.
ACCEPTANCE (ratified 2026-07-20): census of soft_raw = zero weak softs
outside startup/tail; 6 frames metric 0; symbol lock behavior unchanged.

## STATUS bit dictionary (0x040)
| bit | name | meaning |
|-----|------|---------|
| 0 | fs_locked | frame-sync FSM in LOCKED |
| 1 | sym_locked | symbol-lock detector locked (sym_lock_detector.vhd locked_r -- windowed mean \|TED\| with hysteresis; INVARIANT: unconditionally gates fsync hunt; no bypass exists or may be added) |
| 2 | cfo_locked | CFO correction applied; residual within theta handoff |
| 3 | in_init | DEMOD_INIT asserted |
| 31:4 | reserved | read 0; no bit may be added without this table |

v5 debt closed: former undocumented b1/b2 (observed set on pure noise,
2026-07-18) are replaced by defined detector outputs.

## Retirements (with successors — nothing retires bare)
| Retired (v5) | Successor (v6) |
|---|---|
| FREQ_F1/F2, F1/F2_NCO_ADJUST | CFO block 0x0B0–0x0C0 (estimator-driven runtime frequency control; CFO_MANUAL = operator word) |
| SYM_CNT/SYM_THR + G_LOCK_SYM calendar | SYM_LOCK block 0x0A0–0x0AC (windowed \|TED\| + hysteresis) |
| LPF_*, F1/F2_ERROR, LPF_ACCUM, CST_* | theta/timing observability: SYM_LOCK_STATUS.avg_err live; further MLSE taps ride the same flow when exposed |
| GAIN_MANUAL/CURRENT | channelizer map (normalizer promotions tracked there) |
| LOOP_CTRL, RX_SAMPLE_DISCARD, legacy LOCK_STATUS | none needed (functions gone); addresses read 0 until ≥ v7 |

## Architecture notes (the two decisions this map encodes)
- **CFO correction placement (Option A, decided):** complex multiply at the
  demodulator input, per Mehlan/Chen/Meyr 1993 and the C++
  (`set_freq_offset` rotates input samples). The channelizer removes the
  *known* frequency (bin center); this stage removes the *measured* one.
  MLSE internals (incl. fixed tone reference) untouched. Tone reference is
  re-expressed as named constants (`TONE_DEV_HZ = SYMBOL_RATE_HZ/4`, etc.)
  — legibility fix, zero behavior change.
- **Pull-in spec (cited):** class range 0.15–0.25·Rb (Morelli & Mengali
  1998/1999) = ±8.1..±13.55 kHz at 54,200 baud; ceiling = R/4
  line-identification ambiguity. Operator statement: net carrier within
  ±13.5 kHz of channel center (±2.4 ppm at 5.6 GHz); receiver does the
  rest. Handoff: residual < ±200 Hz into PSP theta (clamp-derived).

## Consumers (regenerate, don't hand-edit)
- **Generated artifacts:** VHDL regblock (+pkg), markdown (this doc's
  table section), C header. All from the .rdl in one make target,
  committed together, per pluto_msk precedent.
- **Bouro:** forensics pane regenerates from the map: drops all RESERVED
  addresses (relic display bug closed); adds SYM_LOCK (locked + live
  avg_err trace), CFO (state, estimate in Hz, quality), FS_STATE.
  MQTT_TOPICS.md gains one topic per new register, names = register names.
- **Dialogus / other consumers:** consume the generated C header /
  machine-readable export (PeakRDL emits both); no hand-transcribed maps
  anywhere downstream.
- **bring-up.sh:** writes every RW register explicitly from the header's
  defaults (RESET-BRANCH-IS-TRUTH, enforced in software too), inside the
  DEMOD_INIT bracket; the 2026-07-18 rx_invert incident is the cautionary
  citation in its comment block.

## Verification plan — in sim, before any hardware claim
Bench = tb_haifuraiya_channelizer_axi extensions; every step is a
pass/fail assertion, runner-integrated.

- **RM-1 map conformance:** walk every address: reset readback = documented
  default; RESERVED reads 0 and swallows writes; RW write/readback; RO
  write-ignored. Generated from the .rdl (PeakRDL test emission) so the
  test can't drift from the map.
- **RM-2 VERSION gate:** readback 0x00060000.
- **SL-1 detector truth:** clean stimulus → sym_locked rises within one
  preamble (assert time bound); avg_err readback tracks a tb-computed
  reference of windowed |errg|.
- **SL-2 hysteresis:** noise-only → never locks; lock then inject timing
  jitter → unlocks at UNLOCK not LOCK threshold; no chatter across 1000
  window boundaries.
- **SL-3 threshold calibration:** sweep Eb/N0 at record-book points;
  choose LOCK/UNLOCK defaults; write them back into the .rdl as the
  documented defaults with the sweep cited.
- **FS-1 gate:** fs_gate_on_symlock=1 → zero hunt candidates before
  sym_locked (the insta-lock regression test, at last); =0 reproduces v5
  behavior.
- **FS-2 config promotion:** LOCK_FRAMES/FLYWHEEL_TOL/ENERGY_FLOOR sweeps
  change behavior as documented; defaults reproduce the proven 6/6 run
  bit-exactly (regression anchor).
- **CFO-1..n:** the missing axis, installed: --carrier-offset swept 0 →
  ±20 kHz both signs at record-book Eb/N0; per point assert
  CFO_ESTIMATE accuracy, lock time (target < 40 ms, Paul's spec),
  decode at record metrics. The measured failure edge is a bench OUTPUT
  recorded in the record book beside the citations. Red-first: CFO-1
  fails on today's DUT by design and gates WP2 completion.
- **CH-1:** CHANNEL_SEL retune via init bracket; decode on a second
  stimulus channel.

## Definition of done (per the directive)
1. .rdl compiles through PeakRDL; regblock replaces haifuraiya_demod_regs.
2. RM/SL/FS suites green in sim; CFO suite green through WP2.
3. Bitstream rebuilt from the migrated tree; RM-1 walked on hardware via
   devmem; Bouro (regenerated) displays the new subsystems live.
4. Handoff/handbook docs regenerated; fate table superseded by this map
   with a pointer.
Nothing else proceeds until 1–3 hold on hardware with Bouro. — per W5NYV.
