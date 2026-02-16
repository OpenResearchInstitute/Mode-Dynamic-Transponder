# Simulation - Testbenches

This directory contains testbenches for verifying the polyphase channelizer modules.

## Testbench Summary

| Testbench | Module Under Test | What It Verifies |
|-----------|-------------------|------------------|
| `tb_coeff_rom.vhd` | `coeff_rom` | ROM initialization from hex file, sequential read |
| `tb_delay_line.vhd` | `delay_line` | Shift operation, hold behavior, reset |
| `tb_mac.vhd` | `mac` | Dot product, mixed signs, timing (M cycles) |
| `tb_fir_branch.vhd` | `fir_branch` | Complete FIR filtering, coefficient routing |
| `tb_polyphase_filterbank.vhd` | `polyphase_filterbank` | N branches, round-robin distribution, output sync |
| `tb_fft_4pt.vhd` | `fft_4pt` | DC, Nyquist, positive/negative frequency tones |
| `tb_fft_64pt.vhd` | `fft_64pt` | DC, impulse response, cosine tone |

## Running with Vivado

### Quick Start

```tcl
# From Vivado TCL console:
cd /path/to/Mode-Dynamic-Transponder
source sim/run_tests.tcl

# Run all tests:
run_all_tests

# Run single test:
run_test tb_coeff_rom
```

### Manual Setup

1. Create a new Vivado project (or use existing)
2. Add RTL sources from `rtl/` directory
3. Add simulation sources from `sim/` directory
4. Set the testbench as top module
5. Run behavioral simulation

### File Dependencies

Each testbench requires these files to be compiled first:

```
tb_coeff_rom         ← coeff_rom
tb_delay_line        ← delay_line
tb_mac               ← mac
tb_fir_branch        ← fir_branch, delay_line, mac
tb_polyphase_filterbank ← polyphase_filterbank, fir_branch, delay_line, mac
tb_fft_4pt           ← fft_4pt
tb_fft_64pt          ← fft_64pt
```

All modules depend on `channelizer_pkg.vhd` (compile first).

## Test Descriptions

### tb_coeff_rom

Reads all coefficients from ROM and prints values. Verifies hex file was loaded correctly at elaboration time.

**Required files:**
- `rtl/coeffs/mdt_coeffs.hex` (must be in simulation working directory or path adjusted)

**Expected output:**
```
=== Coefficient ROM Testbench ===
Configuration: 4 channels, 16 taps/branch
Addr 0: 0xFF9F = -97 (-0.00296)
Addr 1: 0xFFF8 = -8 (-0.00024)
...
```

### tb_delay_line

Tests shift register behavior:
1. Reset clears all taps to zero
2. Values shift correctly through delay line
3. Hold behavior (shift_en=0 preserves state)
4. Oldest value discarded when new one enters

### tb_mac

Tests multiply-accumulate:
1. Simple sum: coeffs=[1,1,1,1], samples=[1,2,3,4] → 10
2. Weighted: coeffs=[2,4,4,2], samples=[100,200,300,400] → 3000
3. Mixed signs: coeffs=[1,-1,1,-1], samples=[10,20,30,40] → -20
4. Timing: verifies M cycles to completion

### tb_fir_branch

Tests complete FIR branch:
1. Load samples, verify weighted sum
2. Add more samples, verify shift behavior
3. Test with negative coefficients
4. Verify timing from sample_valid to result_valid

### tb_polyphase_filterbank

Tests full filterbank:
1. Coefficient loading completes
2. Round-robin sample distribution
3. All branches compute correct results
4. outputs_valid synchronization

**Test case:** With coeffs=[1,1,1,1] and samples 1-16:
- Branch 0 sees [1,5,9,13] → sum = 28
- Branch 1 sees [2,6,10,14] → sum = 32
- Branch 2 sees [3,7,11,15] → sum = 36
- Branch 3 sees [4,8,12,16] → sum = 40

### tb_fft_4pt

Tests 4-point FFT with known DFT results:
1. DC input [1,1,1,1] → X[0]=4, others=0
2. Nyquist [1,-1,1,-1] → X[2]=4, others=0
3. Positive freq [1,j,-1,-j] → X[1]=4
4. Negative freq [1,-j,-1,j] → X[3]=4

### tb_fft_64pt

Tests 64-point FFT:
1. DC input (all 100) → energy in bin 0
2. Impulse (x[0]=1000) → flat spectrum
3. Cosine at bin 8 → energy in bins 8 and 56

## Simulation Tips

### Waveform Signals to Watch

**coeff_rom:**
- `addr`, `coeff` - verify sequential read

**delay_line:**
- `shift_en`, `data_in`, `delay_reg` - watch values shift

**mac:**
- `state`, `tap_idx`, `accum` - watch accumulation progress

**fir_branch:**
- `sample_valid`, `delay_taps`, `result`, `result_valid`

**polyphase_filterbank:**
- `branch_select`, `branch_sample_valid`, `branch_outputs`, `outputs_valid`

**fft_4pt / fft_64pt:**
- `valid_in`, `valid_out`, input/output arrays

### Common Issues

1. **Coefficient file not found:** Ensure hex file path is correct relative to simulation working directory

2. **Simulation hangs:** Check that `sample_valid` or `start` signals are being asserted

3. **Wrong results:** Verify bit widths match between modules, check for sign extension issues

## Running with Other Simulators

### GHDL (Open Source)

```bash
# Analyze (compile) all files
ghdl -a --std=08 ../rtl/pkg/channelizer_pkg.vhd
ghdl -a --std=08 ../rtl/channelizer/*.vhd
ghdl -a --std=08 *.vhd

# Elaborate and run a testbench
ghdl -e --std=08 tb_coeff_rom
ghdl -r --std=08 tb_coeff_rom --wave=tb_coeff_rom.ghw

# View waveform
gtkwave tb_coeff_rom.ghw
```

### ModelSim / QuestaSim

```tcl
vlib work
vcom -2008 ../rtl/pkg/channelizer_pkg.vhd
vcom -2008 ../rtl/channelizer/*.vhd
vcom -2008 *.vhd

vsim -gui work.tb_coeff_rom
run -all
```
