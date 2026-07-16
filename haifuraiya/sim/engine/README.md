# msk_symbol_engine -- first VHDL block of the Phase 0 MSK receiver

Correlator + V-bank TED + PI timing loop, raw integer windows, one NCO,
integer arithmetic throughout. Architecture and every constant proven in
the fixed-point model (see demod_phase0/README.md sessions 5-7):
gates 24/24 @ 12 dB, 24/24 @ 6, 22/24 @ 4.5, interop 10/10.

Files:
  msk_symbol_engine.vhd     the block (VHDL-2008)
  tb_msk_symbol_engine.vhd  bench: serves stim, dumps per-symbol outputs
  run_symbol_engine.tcl     xsim runner (house style)
  check_engine.py           integer-for-integer compare vs golden
  lut16.txt                 Q1.15 sin/cos table -- SINGLE SOURCE OF TRUTH
                            shared by model and fabric (65536 x 2)
  stim_engine.txt           first 60000 samples of the canonical clean
                            chan5 stimulus (int16 I Q per line)
  golden_engine.txt         model trajectory: k pos wlen y1r y1i y2r y2i
                            for 5202 symbols

Run:
  cd <this dir>  (or copy into haifuraiya/sim/engine/)
  vivado -mode batch -source run_symbol_engine.tcl
Expected: "compared 5202 symbols: 5202 exact / BIT-EXACT ... GO."

Known first-run risk items (where the bench will bite, by design):
  - memory data timing: the TB serves samples combinationally; if the
    DUT's MAC consumes a stale address cycle, the FIRST window will be
    off by one sample and the diff will fail at symbol 0 -- the compare
    output shows exactly where.
  - shift semantics: model uses python arithmetic shifts (floor);
    VHDL shift_right on signed is arithmetic -- believed matched, the
    bench will confirm.
Fix-and-rerun until BIT-EXACT; no block advances with a nonzero diff.
73

## VERIFICATION RESULT (2026-07-15, keroppi, Vivado 2022.2 xsim)

  first 69 MAC cycles IDENTICAL (per-clock trace)
  compared 5202 symbols: 5202 exact
  BIT-EXACT over all 5202 symbols. GO.

Coverage in the single run: 2437 x wlen-11 windows, 2765 x wlen-12,
all four length-transition patterns (incl. 365 x 12->12 and 36 x 11->11,
runs up to four 12s), acquisition gear downshift at symbol 1000, closed
TED/PI feedback throughout, position words past the 2^31 boundary.

Shakedown ledger (first day of existence, all caught by the bench):
  1. TB textio silently dropped negative integers  -> offset-encoded files
  2. checker declared GO on a truncated 1-symbol run -> completeness gate
  3. RTL: signed*integer sign multiply = double-width product (runtime
     abort at first bank() call) -> conditional negation (better idiom)
  4. TB printed 48-bit pos through 32-bit to_integer -> two 24-bit halves
Score: RTL logic bugs 1, scaffold bugs 3, weeks lost 0.
