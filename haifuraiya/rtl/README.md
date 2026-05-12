# RTL - Haifuraiya (ZCU102)

Synthesizable VHDL for the Haifuraiya polyphase channelizer, the Opulent
Voice ground-station front end targeting the Xilinx ZCU102.  Vendor-agnostic
design (no Xilinx LogiCORE IP).

## Architecture

Parallel-MAC: each FIR branch instantiates one multiplier per tap, producing
a single-cycle convolution output.  The serial-MAC architecture used by
MDT-SIC is reusable in concept but the implementations are independent.

```
haifuraiya/rtl/
├── channelizer/
│   ├── fir_branch_parallel.vhd            # 24 parallel MACs per branch
│   ├── polyphase_filterbank_parallel.vhd  # 64 instances + commutator
│   ├── fft_64pt.vhd                       # radix-2 DIT, ping-pong buffers
│   └── haifuraiya_channelizer_top.vhd     # I/Q filterbanks + P2S + FFT
└── coeffs/
    └── haifuraiya_coeffs.hex              # 1536 coeffs (64 ch x 24 taps)
```

Each `fir_branch_parallel` reads its own coefficient slice from
`haifuraiya_coeffs.hex` at elaboration time via textio -- there is no
runtime coefficient-load handshake, no `coeff_rom` instance, and no
dependency on `channelizer_pkg`.

## Configuration

| Parameter         | Value         |
|-------------------|---------------|
| Channels (N)      | 64            |
| Taps per branch   | 24            |
| Sample width      | 16 bits (Q1.14) |
| Coefficient width | 16 bits (Q1.14) |
| Accumulator width | 40 bits       |
| FFT size          | 64-point      |

## Build

Simulation: see [`../sim/`](../sim/) -- the integration testbench
`tb_haifuraiya_channelizer_top.vhd` covers six self-checking tests
(smoke, DC, swept tones, off-bin split, alias rejection, carrier capture).
Run via `cd haifuraiya/sim && source run_haifuraiya_channelizer_test.tcl`
in the Vivado xsim Tcl Console.

Synthesis: see [`../syn/zcu102/`](../syn/zcu102/) (in progress).
