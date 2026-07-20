# WP2 — Carrier Frequency Offset Acquisition & Correction
## Design document, for review before RTL. Status: DRAFT (W5NYV to ratify)

License: CERN-OHL-S v2. Normative register map: REGISTER_MAP_V6.md
(CFO block 0x0B0-0x0C0, reserved since v6 draft).

---

## 1. Requirement (restated from the ratified plan)

The receiver must acquire and correct carrier frequency offset
autonomously, to at least the C++ reference's performance, targeting the
literature ceiling for the modulation:

| bound | value | source |
|---|---|---|
| floor (reference parity, MEASURED) | +/-5..6 kHz practical, seconds-scale lock, wedge-prone | KB5MU RF bench 2026-07-07 (full dataset in appendix B) |
| reference internals (source as cloned) | +/-1.5 kHz one-shot first-chunk search; AFC clamp +/-2.0 kHz | opv_demod.hpp:214, :402; opv-demod.cpp:255 (first_chunk only). DISCREPANCY with the measured +/-6 k flagged in appendix B -- constants may differ from the 07-07 build, or the uncalibrated RX reference shifted the window; either way our +/-27.1 kHz discriminator ambit covers both readings |
| target ceiling | +/-13.55 kHz (R/4) | line-identification ambiguity; Morelli & Mengali 1998 ("~25% of bit rate"), 1999 ("15%") |
| lock time | < 40 ms (one preamble) | KB5MU lab spec 2026-07-07 |
| handoff residual | < +/-200 Hz into PSP theta | msk_mlse4 slew clamp, +/-211.7 Hz (measured from source) |
| operator statement | net carrier within +/-13.5 kHz of channel center (+/-2.4 ppm at 5.6 GHz) | this doc |

Additional acceptance (from the anomaly campaign): slip-census
regression -- decoded-bit events at corrected offset-10 Hz must equal
the offset-0 baseline (zero outside startup).

## 2. Reference algorithm (transcribed from source, opv_demod.hpp)

Two mechanisms:

**(a) estimate_offset (coarse, one-shot, ~line 214):** hypothesis search
offset in [-1500,+1500] step 25: dual tone correlators at
(+/-FREQ_DEV + offset) over up to 1000 symbols; score = sum
|corr_f1|^2+|corr_f2|^2; argmax; fine pass +/-30 step 5.

**(b) AFC (per-symbol tracking, ~line 390):** dominant = larger-|.|
of the two per-symbol tone correlations;
    pd   = arg( dom * conj(prev_dom) )        -- phase advance per symbol
    ferr = pd * SYMBOL_RATE / 2pi             -- Hz
    freq_offset += 0.001 * ferr;  clamp +/-2000
Correction applied by shifting both tone LO increments (equivalent to
derotating the input).

## 3. Key analysis: the discriminator IS the estimator

The AFC discriminator's unambiguous range is |pd| < pi per symbol
= +/- R/2 = **+/-27.1 kHz** -- exceeding the R/4 spec ceiling. For a
static offset df, the dominant tone's correlation rotates at exactly df:
pd = 2pi*df/R, so ferr reads df directly, first symbol pair. The C++'s
coarse search is therefore NOT required in fabric for the spec range;
it exists in software for cold-start robustness at low SNR. Hardware
plan: the delta-phase discriminator (Mehlan/Chen/Meyr 1993 structure:
"the phase of the smoothed signal is an estimate of the carrier
frequency offset") serves as both estimator and tracker, with a
two-gear gain (fast slew during acquisition, C++'s 0.001 in tracking).
Tone identification holds while |df| < R/4 = the documented ceiling --
the spec and the ambiguity limit coincide, as the papers say they must.

**Inputs already exist:** the engine exports per-symbol e_y1(r,i) /
e_y2(r,i) (added 2026-07-20 for the anomaly probes). No new correlators.

## 4. Architecture (Option A, ratified 2026-07-19)

    channel samples (625 ksps, TARGET_CHANNEL)
        |
    [ CFO ROTATOR ]  <- phase inc from CFO word (auto/manual mux)
        |                 NCO 32-bit; complex multiply via lut16q QROM
    [ ring buffer -> msk_symbol_engine -> msk_mlse4 ]   (UNTOUCHED)
        |                          |
        |                     e_y1/e_y2 per symbol
        |                          v
        +----------------< [ CFO ESTIMATOR/AFC ] -- dominant-tone
                              delta-phase discriminator; PI-free
                              alpha accumulation per C++ law

  * Channelizer removes the KNOWN frequency; rotator removes the
    MEASURED one; theta absorbs the residual. Partition per Mehlan-Meyr
    and per the C++ (set_freq_offset rotates input samples).
  * MLSE internals untouched: fixed tone reference stays legitimate
    because the input is centered before it arrives.

### Phase detector in fixed point (no atan2 needed for tracking)
cross = y_r*prev_y_i - y_i*prev_y_r; dot = y_r*prev_y_r + y_i*prev_y_i.
Small-angle (tracking): pd ~ cross/dot after lock. Acquisition (large
pd): quadrant-resolved via signs of (dot,cross) + one cross/dot divide
(the sym-lock serial divider pattern, 16 cycles) -- full +/-pi range.

### State machine (CFO_STATE, 0x0B0)
IDLE (init) -> SEARCH (energy floor gate: sum|y| over 64 sym above
CFO_QUALITY floor) -> CORRECTING (fast gear: alpha_acq until |ferr|
small for N sym) -> HELD (alpha = C++ 0.001 equivalent) -> LOST (quality
collapse -> SEARCH). Autonomous re-acquisition; no PS in the loop.

## 5. Registers (map v6 block, now specified exactly)

| addr | name | access | definition |
|---|---|---|---|
| 0x0B0 | CFO_STATE | R | 0 IDLE / 1 SEARCH / 2 CORRECTING / 3 HELD / 4 LOST |
| 0x0B4 | CFO_ESTIMATE | R | applied correction, Hz, signed 16 (readback of the accumulator scaled to Hz) |
| 0x0B8 | CFO_CTRL | RW | b0 auto (default 1); b1..: reserved |
| 0x0BC | CFO_MANUAL | RW | Hz signed 16; drives rotator when auto=0. The falsifiability knob: operator can null a known stimulus offset by hand and watch decode clean |
| 0x0C0 | CFO_QUALITY | R | windowed sum|y_dom| gauge (energy floor + Bouro) |
| -- | CFO_ALPHA_ACQ / _TRK | RW (0x0B8[15:8]/[23:16] packed or two regs -- W5NYV pick) | gains, defaults: track = C++ 0.001 equivalent (derivation in code); acq = 16x |

STATUS(0x040) bit 2 = cfo_locked (STATE==HELD) -- reserved since v6,
now driven. Bouro: derived/demod/cfo/{state,estimate_hz,quality}.

## 6. Build order (each step bench-gated)

1. **Rotator + CFO_MANUAL** (smallest useful unit): NCO + complex mult,
   manual word only. Bench: stimulus at -offset X, write CFO_MANUAL=+X,
   assert 6/6 decode + zero slip census. Proves the correction path
   in isolation. RED-FIRST: same bench at CFO_MANUAL=0 must FAIL at
   X beyond theta range -- the axis exists before the fix.
2. **AFC estimator** on e_y exports, auto mode: same bench, auto=1,
   CFO_MANUAL=0; assert lock time < 40 ms, CFO_ESTIMATE ~ -X +/- CRB.
3. **Sweep to the measured edge**: X from 0 to +/-20 kHz; record the
   pass curve; the failure edge is the datasheet number beside the
   citations. Slip-census regression at 10/50/500/5000 Hz corrected.
4. Registers walked (RM-1 pattern), Bouro topics live, hardware devmem.

## 6b. What the reference bench data demands of us (KB5MU 2026-07-07)

Paul's dataset (appendix B) sets three empirical bars and exposes two
reference defects our design must not inherit:

1. RANGE: reliable lock to ~+/-5-6 kHz near threshold; degrading,
   SNR-dependent locks to +/-8-9. Our target (+/-13.55 kHz) exceeds it;
   our floor is his +/-6 k, not the source's +/-1.5 k.
2. SPEED: his method could only resolve "seconds"; he states outright
   the sub-40 ms question was UNMEASURABLE on the RF bench. The CFO
   bench axis (section 6, step 3) measures lock time per offset point
   in simulation -- closing the measurement gap he named.
3. THE WEDGE (his "0 again: no lock even at high SNR until restart"):
   mechanism now identified from source -- estimate_offset runs on the
   FIRST CHUNK ONLY (opv-demod.cpp ~255); afterwards the sync-gated AFC
   is the sole corrector, so a large excursion strands freq_offset_
   where no signal can pull it home. Restart is the only recovery.
   Our CFO_STATE machine's LOST -> SEARCH transition exists precisely
   to make this failure mode impossible: acquisition is a standing
   capability, not a boot event. Acceptance test: mid-run offset step
   from 0 to +5 kHz and back; receiver must re-lock both times with
   no intervention (the anti-wedge test, named for this dataset).

## 7. Provenance appendix
June de Buda lineage: commit f357133 (proven 5/5 metric-0) removed by
8e26233 (MLSE swap; diff = rx_top -130 lines + 3 new files). The June
implementation is REFERENCE material for the rotator/NCO idioms; the
estimator here follows the C++/Mehlan-Meyr delta-phase form instead of
the spectral-line form because its inputs (e_y) already exist and its
range covers the spec. debuda_rx_model.py / line tracker remain the
golden models for any spectral cross-check.


## Appendix B -- KB5MU RF bench dataset, 2026-07-07 (verbatim summary)
Pluto 0.39 TX -> attenuation chain -> Pluto RX, C++ modem, near
threshold (metric ~2 digits), AGC railed 73. Offsets dialed at TX;
"df=0" not absolute (RX uncalibrated). Results: 0/+1/+2 quick lock;
+3 after a while; +4/+5 quick; +6 no lock at 22 dB, long-wait lock at
20 dB; +7 slow; +8 slow/unstable, clean at 18 dB; +9 stuck metric ~300
at all attenuations; RETURN TO 0: no lock at ANY attenuation until
receiver restart (the wedge). Negative side: -1..-5 lock with
increasing delay (to ~30 s); -6/-7 unstable-eventual. His summary:
~6 kHz practical range, seconds-scale, sub-40 ms unmeasurable by this
method.
