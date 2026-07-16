# chain -- Phase 0 integration bench (THE FINAL SIMULATION GATE)

Full RTL signal path on the canonical stimulus:
  chan5_iq.cs16 (C++ opv-mod -> verified channelizer, 276132 samples)
  -> msk_symbol_engine (RTL, verified bit-exact)
  -> msk_mlse4 (RTL, verified bit-exact)
  -> soft stream -> proven model frame path -> frames
  vs cxx_frames.bin (byte-for-byte).

PRE-FLIGHT (python, identical integer arithmetic): 10/10 byte-identical,
ALL DECODE METRICS ZERO. That is the expected verdict.

Run:  vivado -mode batch -source run_chain.tcl   (10-30 min)
Expect: "PHASE 0 COMPLETE ... GO."

Two-phase bench (engine first, capture Ys, then feed mlse4): the bench
memory makes the engine unrealistically fast; in the real fabric it is
sample-rate-bound (~1840 clk/sym at 100 MHz) and no FIFO is needed.

After this GO, Phase 0 (design + simulation verification) is complete.
Remaining phases use existing infrastructure: synthesis/timing on the
ZCU102, integration with the channelizer/ring buffer/normalizer, frame
sync + K=7 fabric blocks (already proven), then over the air.
73

## FINAL GATE RESULT (2026-07-15, keroppi, Vivado 2022.2 xsim)

  fabric soft stream: 23881 decisions
  frames byte-identical to C++ reference: 10/10
  decode metrics: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  PHASE 0 COMPLETE. GO.

First-run pass. No shakedown required: both blocks entered this bench
already bit-exact, and composition held.
