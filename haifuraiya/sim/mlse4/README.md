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
