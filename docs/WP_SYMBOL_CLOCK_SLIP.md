# WP: Symbol-clock slip tolerance (the 0.756-second metronome)

**Status:** mechanism identified 2026-07-21 from OTA capture forensics
(captures/fresh4.bin + /tmp/ppm_log.txt). Confirmation test specified below.
No implementation yet. This is mission-required behavior, not a bench bug.

## Evidence (all measured, one evening, free-running Pluto TX vs ADRV9002 RX)

- Bad-frame pockets recur with mean spacing 18.9 frames = 0.756 s
  (metronomic: spacings 15-24, not exponential -- deterministic drift,
  not random faults).
- SYM_CLK_OFFSET (0x0CC) read 11.5 ppm during calm HELD operation.
- Arithmetic: half-symbol slip period at Df ppm = 1/(2 * 54200 * Df*1e-6).
  0.756 s implies 12.2 ppm. Register said 11.5. Pocket rate measured
  1.36/s; predicted 1.25-1.32/s. Three instruments agree within a few %.
- 1 Hz samples of 0x0CC swing +/-16 ppm: the integrator SAWTOOTHS over the
  0.756 s slip cycle; 1 Hz sampling aliases the sawtooth. The estimate is
  faithful; the sampling cadence was wrong for the shape.
- Pocket anatomy: graded metrics (4, 10, 365 ... 2100) = slip position
  uniformly distributed within the frame; deinterleaver spreads damage
  proportionally to post-slip fraction. Metric-7 frame = resync edge.
- Eliminated by experiment/authority: Bouro/MQTT load (identical 21-22%
  error rate on vs off), OS heartbeat (idle top), TX gaps (Opus emits
  constant-rate frames regardless of speech), RF environment (quiet subband),
  format/plumbing (would be binary, not graded).

## Requirement (mission-derived)

The receiver SHALL decode with zero slip-induced frame loss under sustained
symbol-clock offset of at least +/-25 ppm, and SHALL degrade gracefully
(bounded, counted frame loss; no lock loss; no wedge) to +/-50 ppm.
Rationale: LEO Doppler rate + free-running oscillator budgets exceed the
11.5 ppm that tonight produced 22% frame loss. A shared reference exists on
no mission asset. Related standing requirements (2026-07-21): dead air shall
never cause radio issues; consumer behavior shall never affect demodulation.

## Confirmation test (before any implementation -- one variable)

Common 10 MHz reference between Pluto and ZCU102/ADRV9002. Prediction:
SYM_CLK_OFFSET mean -> ~0, sawtooth -> flat, pockets -> ~0/s, error rate
-> ~0% on continuous TX. If pockets persist referenced, the mechanism is
wrong and this WP halts for re-diagnosis. (Bench-only validation; the fix
below must then be proven under DELIBERATE offset.)

## Design direction (decide during implementation, sim-gated)

The timing loop tracks fractional error correctly; the failure is at whole/
half-symbol boundary crossings. Candidate mechanisms, not mutually exclusive:

1. **Resampler-domain slip absorption**: when the timing integrator crosses
   +/- half a symbol, insert/delete one channel-rate sample at the resampler
   (RX_SAMPLE_DISCARD's natural jurisdiction) and rebias the integrator --
   the loop then tracks indefinitely with no symbol-count discontinuity
   reaching the frame path.
2. **Slip-aware frame path**: fsync already recovers at the next sync word;
   reduce the damage window by allowing +/-1-symbol sync search in LOCKED
   (VERIFYING) state rather than full-frame loss on a one-symbol shift.
3. **Telemetry**: SLIP_COUNT register (events + direction); Bouro display.
   The sawtooth in 0x0CC becomes a monitored waveform, not an anomaly.

Sim gate: extend opv_stim.py with a --clock-offset-ppm knob (resample the
stimulus by 1 +/- ppm*1e-6) -- currently the generator has carrier offset
but NO symbol-rate offset, which is exactly why 11.5 ppm was never
simulated and this mechanism first appeared over the air. Acceptance:
0 bad frames at 25 ppm for >=60 s of stimulus; bounded counted loss at
50 ppm; gold baseline bit-exact at 0 ppm.

## Open question attached to this WP

fresh4.bin's final pocket begins at its final frame: the wedge fired
mid-pocket. Determine whether the wedge is a slip event that latches the
frame path (one mechanism, two severities -- in which case this WP and the
drop-FIFO WP share a root) or an independent stall. The FIFO WP's
soft_frame_buf overflow witness register will discriminate.
