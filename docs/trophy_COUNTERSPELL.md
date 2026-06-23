# Trophy case: the half-blind de Buda demod (two stacked findings)

Open Research Institute - Haifuraiya / MDT receive chain - msk_demodulator
(complex-baseband-rx / decouple-carrier-loops)

Two root causes, found from two directions, and they STACK rather than conflict:

- Cast REDUCE  - the INPUT FLOOR: the De Buda input is hard-clipped (100% of
  steady-state samples railed) with a large DC bias. Squaring it does not make
  clean +/-R/2 lines. Found in the measured rx dump.
- Cast COUNTERSPELL - the ARCHITECTURE CEILING: the shared carrier loop hands
  an inverted correction to the Costas NCOs (doubles the offset instead of
  nulling it), and the de Buda front end tracks only one of the two squared
  lines where de Buda needs both. Found in the RTL + golden model.

The clipping sits UPSTREAM of the architecture. It has to clear first, or none
of the architecture experiments can be trusted. Clean circle first, THEN judge
one-line vs two-line on valid data.

---

## STATUS

- Cast REDUCE (input floor): MEASURED from debuda_rx_dump.txt. Not inference.
- Cast COUNTERSPELL (carrier sign + single line): PROVEN in analysis (sign
  algebra + bit-frequency numeric model). These are code facts, independent of
  the input data.
- Hardware GREEN: PENDING. Run the ladder below in order and fill [FILL].

---

## READ FIRST - validate in THIS order (the ordering is the finding)

Every experiment below runs through the squarer. On a clipped input the squarer
output is a forest of harmonics, so any experiment run before the input is clean
is reading tea leaves. Do experiment 0 first. It is the cheapest of all of them
(constants + re-sim, no RTL change, no synthesis) and it gates the rest.

0. CLEAN, CENTERED CIRCLE (gate; no rebuild).
   Lower the stimulus amplitude (opv_chan_stim_dc.txt level, or OUTPUT_SHIFT /
   gain_manual) until the sat16 at rx_top (~line 213) stops saturating, AND
   remove the DC bias (de-mean ahead of the squarer; the signal lives in
   channelizer bin 0 = DC, so DC/LO leakage lands right on it). Re-run the
   dbu_rx_dump and confirm the trace is a circle INSIDE +/-2048, centered on
   the origin. Only now is the input valid.
   PASS when: dump rails 0% in steady state; centroid ~ (0,0); |z| ~ constant.

1. CARRIER SIGN (cheap; bank it, but read it only AFTER 0).
   Negate the exported common_adjust (Cast COUNTERSPELL fix 1). On a clean
   input, lock should survive a deliberate carrier offset, and f1_nco_adjust /
   f2_nco_adjust (0x068 / 0x06C) should converge to ~ -Delta together instead
   of wandering apart.

3. SECOND DE BUDA LINE (the architecture fix; end here).
   Add lp_lo and combine (Cast COUNTERSPELL fix 2). DANGER: if you run this on
   a clipped input, f1 can stay flappy because the INPUT is garbage, and you
   will wrongly conclude "the second line did not help" and abandon the correct
   fix. Run it only after 0 shows a clean circle, so that "f1 went solid" means
   "the second line helped," not "we finally stopped feeding it a square."

(The earlier "experiment 2, de-mean" is folded into experiment 0 - de-mean is
the same category as de-clip: make the input a clean, centered circle.)

---

# Cast REDUCE - the De Buda input was clipping the squarer

TL;DR: bring the stimulus back inside the +/-2048 box and center it. The
measured rx dump is railed 100% of the time in steady state and carries a large
negative Q DC bias. Squaring a clipped, DC-shifted signal raises the spurs to or
above the wanted +/-R/2 lines, so the carrier tracker is locking to junk.

## Measured (debuda_rx_dump.txt, 1024 samples, fs = 625 ksps)

| metric                                   | value                         |
|------------------------------------------|-------------------------------|
| at least one component railed (all)      | 95.1%                         |
| at least one component railed (steady)   | 100.0% (samples 64..1024)     |
| fully inside the box                     | 50 of 1024 (4.9%, startup only) |
| I mean / std                             | -427 / 1602                   |
| Q mean / std                             | -1437 / 869   (DC bias ~70% FS) |
| Q max                                    | +580 (never swings positive)  |
| |z| over the box (steady)                | min 2048, median 2373, max 2896 |

The trajectory traces the SQUARE box, not a circle (see figure). The negative Q
bias shoves the circle down into the -2048 rail, so a large part of the clipping
is DC-driven - de-meaning is not a 1% refinement here, it is co-responsible for
the rail. Reduce amplitude AND remove DC together.

## What clipping does to the squared spectrum (measured vs clean)

z^2 spectrum, dB relative to peak:

| component                         | freq      | measured (clipped) | clean circle |
|-----------------------------------|-----------|--------------------|--------------|
| +R/2  WANTED de Buda line         | +27100 Hz | -0.4 dB            |  0.0 dB      |
| -R/2  WANTED                      | -27100 Hz | -0.4 dB            | -0.5 dB      |
| +/-R/4  spur (DC-bias cross term) | +/-13550  |  0.0 dB            | -2.4 dB      |
| +3R/4  clip harmonic              | +40650 Hz | -6.7 dB            | (absent)     |
| DC  (dc^2 spur)                   | 0 Hz      | -26.2 dB           | -35.9 dB     |
| wanted line vs strongest spur     |           | -0.4 dB (BELOW)    | +2.4 dB (above) |

On a clean circle the de Buda line is the dominant feature (+2.4 dB over the
spur). On the measured input it is 0.4 dB BELOW the spur. Worse, after the de
Buda +R/2 down-mix the +R/4 spur lands at -13550 and the +3R/4 clip harmonic
lands at +13550 - both at the FIR passband edge (cutoff ~R/4) - so they leak
straight into the CORDIC and corrupt the carrier phase estimate.

Figure: debuda_input_clipping.png  (left: railed trajectory vs the box;
right: squared spectra, clean vs clipped).

## Fix

- Amplitude: drop the stimulus / OUTPUT_SHIFT / gain_manual so sat16 stops
  saturating. Constants + re-sim. No RTL, no synthesis.
- DC: de-mean ahead of dbu_square_proc (running-mean subtract, or one-pole DC
  block with corner well BELOW R/4). This is Cast COUNTERSPELL fix 3, promoted
  to load-bearing.
- Re-dump and confirm a centered circle inside +/-2048 before trusting any
  carrier experiment.

## Lesson

A squarer is a harmonic amplifier for anything that is not a clean circle. Clip
the constant-envelope input and you do not get +/-R/2 lines, you get the corners
of the clip box smeared across the band. The dangerous part is downstream logic
whose pass/fail test ("did f1 lock?") cannot tell "the architecture is wrong"
from "the input is garbage." Gate the architecture tests on a clean input, or a
false negative will make you throw away the right fix.

---

# Cast COUNTERSPELL - the carrier loop was pushing the wrong way

TL;DR: the shared de Buda carrier loop computes its correction in a down-mix
frame (e^-j) and hands it to two Costas NCOs that mix in an up-mix frame (e^+j).
Opposite handedness = wrong sign: instead of nulling a carrier offset it DOUBLES
it. And the de Buda front end tracks only ONE of the two squared lines, where de
Buda needs both.

## Defect 1 (symmetric): inverted carrier correction

- Costas mixer (costas_loop.vhd, mix_proc):
  (rx_cos + j rx_sin) = (rx_i + j rx_q) * (car_cos + j car_sin) = x * e^(+j theta)   UP-mix
  LUT confirmed positive-sin (sin_cos_lut.vhd), so the freq word that centers a
  tone is the NEGATIVE of that tone.
- de Buda mixer (msk_demodulator.vhd, dbu_mix_proc):
  (re + j im) = (sq_re + j sq_im) * (cos - j sin) = s * e^(-j psi)                    DOWN-mix

For an injected offset +Delta the de Buda loop yields pi_out = +2 Delta and, as
wired, common_adjust = +pi_out>>1 = +Delta. The Costas e^(+j) mixer needs
-Delta. So the tone lands at +2 Delta - doubled, wrong direction. Symmetric
across f1/f2, so it does not pick a loser; it makes the whole carrier loop
fragile: it only "works" when Delta ~ 0 (clean loopback), and amplifies any real
offset (LO error, drift, Doppler).

## Defect 2 (structural): single-line de Buda

The golden model recovers the carrier from BOTH squared lines:

    docs/debuda_rx_model.py:
        w     = z*z
        lp_hi = lpf(w * exp(-j 2pi fline n/fs))   # +R/2 line
        lp_lo = lpf(w * exp(+j 2pi fline n/fs))   # -R/2 line
        car2  = lp_hi/|lp_hi| + lp_lo/|lp_lo|     # sum of unit phasors -> e^(j2 theta_c)
        theta = 0.5 * angle(car2)
        beat  = lp_hi * conj(lp_lo)               # clock from the DIFFERENCE
    docs/debuda_line_tracker.py: two trackers Tp(+R/2), Tm(-R/2); clock = Tp - Tm.

The RTL builds only lp_hi (one fixed mixer at +DBU_MIX_FREQ = +R/2; the -R/2
line goes to -54200 and the FIR rejects it). No lp_lo, no two-line combination.
The single line is matched to one tone and biased for the other; the two-line
average is exactly what would cancel the differential channel/FIR/DC response.

## Sign table (demod input frame; fs=625000, R/4=13550, R/2=27100)

| stage        | operation                  | handedness     |
|--------------|----------------------------|----------------|
| Costas mix   | x * (car_cos + j car_sin)  | e^(+j theta) up |
| de Buda mix  | s * (mix_cos - j mix_sin)  | e^(-j psi) down |

| loop | freq word (625 ksps) | value     | centers tone at        |
|------|----------------------|-----------|------------------------|
| f1   | 0xFA732DF5           | -13550 Hz | +R/4 = de Buda anchor  |
| f2   | 0x058CD20B           | +13550 Hz | -R/4 = rejected by FIR |

| quantity                              | value                          |
|---------------------------------------|--------------------------------|
| de Buda measures (offset +Delta)      | +2 Delta                       |
| common_adjust as wired (+pi_out>>1)   | +Delta                         |
| what the Costas e^(+j) mixer needs    | -Delta                         |
| residual as wired                     | +2 Delta (doubled)             |
| residual with the fix (-pi_out>>1)    | 0                              |

Numeric proof (bit-frequency exact): offset +300 Hz -> as wired both tones at
+600 Hz; with the fix both at 0 Hz.

## Fix 1 - correct the carrier-correction sign (one line; do this first)

Negate the EXPORTED correction only. Do NOT use INVERT_FADJ on the shared PI:
pi_out is dual-use (dbu_phase <= dbu_phase + pi_out advances the de Buda 2fc
NCO). Negating pi_out reverses that internal integrator and the de Buda loop
runs away.

    -- msk_demodulator.vhd, after u_carrier_filter
    -- was:  common_adjust <= std_logic_vector(shift_right( signed(pi_out), 1));
    -- now:
    common_adjust <= std_logic_vector(shift_right(-signed(pi_out), 1));

dbu_phase <= dbu_phase + pi_out stays as is.

## Fix 2 - restore the second de Buda line (structural cure)

Add the lp_lo path and combine (mirror of debuda_rx_model.py /
debuda_line_tracker.py). Skeleton; widths/gains to be BUDGETED, not guessed:

    -- second fixed mixer NCO at -DBU_MIX_FREQ (brings -R/2 line to DC)
    U_dbu_mix_nco_lo : ENTITY work.nco
        GENERIC MAP ( NCO_W => NCO_W, PHASE_INIT => (OTHERS => '0') )
        PORT MAP ( ..., freq_word => std_logic_vector(-signed(DBU_MIX_FREQ)),
                   freq_adj_zero => '1', phase => dbu_mix_phase_lo, ... );
    -- mix s * e^(+j psi)  (opposite sign from the hi path)
    dbu_mix_re_lo <= dbu_sq_re*mix_cos_lo - dbu_sq_im*mix_sin_lo;
    dbu_mix_im_lo <= dbu_sq_im*mix_cos_lo + dbu_sq_re*mix_sin_lo;
    -- second FIR + second CORDIC -> dbu_angle_lo
    -- carrier = angle( unit(hi) + unit(lo) ) / 2 ; clock from (hi - lo) phase difference

When the second line is in, the differential that lands on the orphaned tone is
cancelled, f1/f2 are on equal footing, and the symbol clock comes from the line
difference (no per-symbol dump), which retires the decision-directed lock gating
below.

## What this entry does NOT claim (honest boundary)

The verified conventions show the single line co-aligns with f1, so the
single-line defect alone would, if anything, privilege f1 - opposite to the
bench. The f1-vs-f2 direction comes from the one genuinely non-mirror part, the
data/lock path:

    data_f2_signed <= NOT data_f2 + 1 WHEN cclk = '0' ELSE data_f2;  -- f2 negated by cclk
    data_f1_signed <= data_f1;                                       -- f1 is not
    error_valid_f1 <= tclk_dly(1) AND NOT data_bit_dec;              -- f1 detector on bit=0
    error_valid_f2 <= tclk_dly(1) AND     data_bit_dec;              -- f2 detector on bit=1

error_valid feeds each loop's lock-detector acc_valid, so a biased pre-lock
decision stream starves one detector. This is the data-modulated, chicken-and-egg
pathology debuda_line_tracker.py was written to kill. REASONED, not simulated;
fix 2 removes it structurally; treat the direction as empirical until the bench
says so. NOTE: this can only be evaluated on a clean (de-clipped) input.

## Ruled out (so nobody re-chases these)

- NCO negative-word handling: CORRECT. nco.vhd line 159 signed-adds freq_word +
  freq_adjust; 0xFA732DF5 advances by exactly -13550 Hz; wraps mod 2^32. f1
  tunes down, not to +61 MHz. (demod-plan open-risk #2: closed.)
- pi_controller: standard P+I, integral saturation, symmetric. Carrier instance
  shared; per-loop copies frozen. Not the cause.
- sin_cos_lut: positive-sin; pins every mixer sign above.

## Lesson

Two mixers, opposite handedness, one shared correction. A loop filter does not
know which frame its error was measured in - it integrates. Cross a correction
from a down-mix estimator to an up-mix actuator and the sign flips; a feedback
loop with a flipped sign does not merely fail to help, it amplifies the thing it
was meant to remove. The tell: lock held on a zero-offset loopback and died on
any real offset - a sign-inverted carrier loop is invisible exactly when
Delta = 0. And the de Buda corollary: track one of the two squared lines and you
are running half of de Buda - the missing half is the half that makes it
symmetric. Check the golden model. It had two lines all along.

---

## Carry-forward / hardware notes

- Order is load-bearing: experiment 0 (clean circle) gates 1 and 3. Do not
  judge one-line vs two-line on clipped input.
- bring-up.sh observers: f1_nco_adjust (0x068) vs f2_nco_adjust (0x06C) wander
  check; LOCK scoreboard (0x088). After fix 1 on a clean input, both adjusts
  should converge to ~ -Delta and track together.
- Re-verify WNS after fix 2 (extra mixer + FIR + CORDIC). Channelizer already
  ~1536/2520 DSP.
- I/Q swap in haifuraiya_rx_top.vhd (rx_i<=gq, rx_q<=gi) is common-mode to de
  Buda and Costas, so it does not break their sign relationship - pin it in the
  version stack next to the de Buda mix sign anyway.
- Narrow line-loop pull-in is tens of Hz (debuda_line_tracker.py); real carrier
  offset needs the FFT coarse aid (reuse the channelizer FFT) even after fixes.

## Files touched

| file                                  | change                                    |
|---------------------------------------|-------------------------------------------|
| opv_chan_stim_dc.txt / TB constants   | REDUCE: drop amplitude below sat16 rail   |
| msk_demodulator.vhd (dbu_square_proc) | REDUCE/fix 3: de-mean ahead of squarer    |
| msk_demodulator.vhd                   | COUNTERSPELL fix 1: negate exported common_adjust |
| msk_demodulator.vhd                   | COUNTERSPELL fix 2: add lp_lo + combine; clock from difference |

## Version stack

| component            | version / SHA               | notes                         |
|----------------------|-----------------------------|-------------------------------|
| msk_demodulator      | [FILL SHA]                  | REDUCE + COUNTERSPELL base    |
| rx dump analyzed     | debuda_rx_dump.txt          | 100% steady-state rail, Q DC -1437 |
| nco                  | confirmed signed-add        | neg-word OK; risk #2 closed   |
| pi_controller        | confirmed standard PI       | INVERT_FADJ NOT used on carrier loop (trap) |
| sin_cos_lut          | confirmed positive-sin      | pins mixer handedness         |
| de Buda golden model | docs/debuda_rx_model.py     | two-line reference            |
| de Buda line tracker | docs/debuda_line_tracker.py | two-line reference + FFT aid  |
| Vivado / PetaLinux   | 2022.2                      | unchanged                     |
