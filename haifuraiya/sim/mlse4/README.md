# msk_mlse4 -- second fabric block: 4-state MLSE with per-survivor phase

Consumes the symbol engine's Y stream, emits int16 soft decisions.
Streaming traceback depth 64; no divides/sqrt/CORDIC anywhere.
Model gates (full-integer, streaming, shift-normalized PSP):
24/24 @ 12 dB, 24/24 @ 6, 22/24 @ 4.5, interop 10/10 -- reference parity.

CHAINED VERIFICATION: the input golden IS block 1's bit-exact verified
output (golden_engine.txt); mlse_golden.txt is produced from it by
gen_mlse_golden.py (the executable spec). Run:
    vivado -mode batch -source run_mlse4.tcl
Expect: "BIT-EXACT over all 5138 decisions. GO."
Debug taps: best-state and all four theta words per decision -- a theta
divergence localizes PSP bugs; a soft divergence with matching thetas
localizes traceback/history bugs. Files: msk_mlse4.vhd, tb, tcl,
check_mlse.py, gen_mlse_golden.py, lut16.txt (shared table),
golden_engine.txt (block-1 output), mlse_golden.txt.
73

## VERIFICATION RESULT (2026-07-15, keroppi, Vivado 2022.2 xsim)

  first 100 steps IDENTICAL (per-step metric+theta trace)
  compared 5138 decisions: 5138 exact
  BIT-EXACT over all 5138 decisions. GO.

Chained verification: input = msk_symbol_engine's bit-exact verified
output. Blocks 1+2 together now prove: int16 samples -> soft decisions,
integer for integer against the model.

Shakedown ledger:
  1. identifiers ending in underscore (analyzer; python accent)
  2. input files not copied / gitignore lost its dot (environment)
  3. sp*wvr double-width product (runtime abort) -- the block-1 trap's
     SIBLING, pre-registered as suspect #1 before first run
  4. rotation sum width 41-vs-42 (runtime abort; resize products first)
  5. wholesale theta divergence traced to the TB loading Y via
     golden_engine.txt whose pos column exceeds integer'high for later
     rows -> dedicated y_stream.txt, offset-encoded, all values < 2^25
     (textio immunity now doctrine for ALL bench data files)
  6. dbg_best tap defined as traceback END state vs the spec's START
     argmax -- diagnosed STATISTICALLY: 1302/5138 = 25.3% ~ 1/4 chance
     agreement over four states; softs matched throughout
Algorithm errors: ZERO. The design survived translation intact again.
