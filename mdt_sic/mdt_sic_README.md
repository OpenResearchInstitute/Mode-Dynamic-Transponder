# MDT-SIC — Successive Interference Cancellation Receiver

The iCE40 + STM32 implementation of the Mode-Dynamic-Transponder
successive interference cancellation (SIC) receiver, targeting the
AMSAT-UK FunCube+ satellite. A 4-channel polyphase channelizer that
splits a 40 kHz uplink into 10 kHz bins, paired with an STM32 host
that runs the SIC algorithm in software.

For an introduction to polyphase channelizers in general, see the
top-level repository [`README.md`](../README.md). For the separate
64-channel ZCU102 + ADRV9002 ground-station channelizer (the other
subproject in this repo), see [`../haifuraiya/README.md`](../haifuraiya/README.md).
For the FunCube+ mission concept this implementation serves, see
[`../docs/funcube-mission-concept.md`](../docs/funcube-mission-concept.md).

---

## System architecture

The SIC receiver splits processing between FPGA and MCU:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SIC Receiver System                              │
│                                                                         │
│  ┌─────────────────────────────────────────┐    ┌───────────────────┐   │
│  │           iCE40 FPGA                    │    │    STM32H7        │   │
│  │                                         │    │                   │   │
│  │  I2S ──► Polyphase ──► FFT ──► SPI ──────────► Magnitude ──► SIC │   │
│  │  ADC     Filterbank    4pt     Slave    │    │ Computation  Algo │   │
│  │                                         │    │                   │   │
│  └─────────────────────────────────────────┘    └───────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

The FPGA handles real-time DSP (channelization) at the cubesat power
budget (~5 mW typical for the iCE40UP5K). The STM32H7 handles
post-processing — magnitude computation, peak detection, and the SIC
algorithm itself — using its hardware FPU. Splitting it this way keeps
the FPGA within the 0.5 W envelope a 2U CubeSat allows for the entire
signal-processing subsystem.

---

## Prerequisites

### Hardware

| Item | Part Number | Approx. cost |
|---|---|---|
| FPGA board | Lattice iCE40UP5K-B-EVN | ~$50 |
| MCU board | STM32 NUCLEO-H753ZI | ~$70 |
| Jumper wires | Female-Female Dupont | ~$5 |

See [`syn/ice40/WIRING_GUIDE.md`](syn/ice40/WIRING_GUIDE.md) for
complete connection details and pin mappings.

### Tools

| Tool | Purpose | Notes |
|---|---|---|
| Lattice Radiant | iCE40 synthesis + place-and-route | Windows; produces the `.bin` flashed to the FPGA |
| openFPGALoader (via MSYS2 UCRT64) | Flashing the bitstream to the iCE40 | Windows; requires Zadig to install WinUSB driver |
| STM32CubeIDE | STM32 firmware development + flashing | Cross-platform; project at `firmware/stm32/sic_receiver/` |
| Vivado | Simulation (testbenches) | Cross-platform; only the xsim simulator is used, not synthesis |
| Jupyter | Coefficient regeneration | Only if changing the filter design — see [`../docs/README.md`](../docs/README.md) |

See [`syn/ice40/TOOLCHAIN_SETUP.md`](syn/ice40/TOOLCHAIN_SETUP.md) for
the full Radiant + MSYS2 + openFPGALoader setup walkthrough.

---

## Quick start

### Program the FPGA

In MSYS2 UCRT64 (after running Zadig to set the WinUSB driver):

```bash
openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

### Build and flash the STM32 firmware

The firmware is a complete STM32CubeIDE project at
`firmware/stm32/sic_receiver/`:

1. Open STM32CubeIDE
2. **File → Import → General → Existing Projects into Workspace**
3. Browse to `mdt_sic/firmware/stm32/sic_receiver/`
4. **Uncheck** "Copy projects into workspace"
5. Build and flash to the NUCLEO-H753ZI

See [`firmware/stm32/STM32_SETUP_GUIDE.md`](firmware/stm32/STM32_SETUP_GUIDE.md)
for the full STM32CubeIDE project guide and
[`firmware/stm32/HARDWARE_BRINGUP.md`](firmware/stm32/HARDWARE_BRINGUP.md)
for the step-by-step bring-up checklist.

### Run the simulations

From the Vivado TCL console:

```tcl
cd /path/to/Mode-Dynamic-Transponder
source mdt_sic/sim/run_tests.tcl
create_sim_project channelizer_sim
run_all_tests
```

All seven module-level testbenches should pass. See
[`sim/README.md`](sim/README.md) for the testbench summary.

### Regenerate the filter coefficients

The committed coefficients are authoritative; you only need to
regenerate them if you change the filter design. See
[`../docs/README.md`](../docs/README.md) for the venv setup and
notebook workflow.

---

## Architecture

### Module hierarchy

```
polyphase_channelizer_top
├── coeff_rom                 # Filter coefficients (Block RAM)
├── polyphase_filterbank      # N parallel FIR branches
│   └── fir_branch (× N)
│       ├── delay_line        # Sample history (shift register)
│       └── mac               # Multiply-accumulate
└── fft_4pt                   # Frequency separation
```

The serial-MAC architecture (one multiplier per branch) was chosen
to fit the iCE40UP5K's DSP block budget. The Haifuraiya channelizer
uses a parallel-MAC architecture (one multiplier per tap) because the
ZCU102 has plenty of DSPs.

### SPI protocol

The FPGA is a SPI slave (Mode 0). The STM32 reads 17 bytes per
transaction:

```
TX: [CMD=0x01] [0x00] [0x00] ... (17 bytes)
RX: [0x00] [I0_H][I0_L][Q0_H][Q0_L][I1_H][I1_L][Q1_H][Q1_L]
            [I2_H][I2_L][Q2_H][Q2_L][I3_H][I3_L][Q3_H][Q3_L]
```

Four channels, I and Q for each, big-endian 16-bit values, with one
leading status byte.

### Resource utilization (iCE40UP5K, MDT configuration)

| Resource | Used | Available | % |
|---|---|---|---|
| LUTs | ~4,850 | 5,280 | 92% |
| DSPs | 4 | 8 | 50% |
| F_max | 39 MHz | — | target 12 MHz ✓ |

LUT utilization is the binding constraint. DSP headroom exists for
adding additional channels if traded against LUTs (e.g., parallel-MAC
on a subset of branches).

### Design notes

**Power budget.** The iCE40UP5K was chosen for its ~5 mW typical power
draw. The signal processing subsystem must fit within 0.5 W total for
the 2U CubeSat deployment.

**Magnitude computation off-FPGA.** Computing `sqrt(I² + Q²)` was moved
from the FPGA to the STM32 to save LUTs. The STM32H7's hardware FPU
executes this faster than LUT-based CORDIC or polynomial approximations
on the iCE40.

**SPI synchronizers.** All SPI inputs use 2-stage flip-flop
synchronizers before entering FPGA logic, preventing metastability at
the 12 MHz FPGA clock vs. 1 MHz SPI clock domain crossing.

**Filter design.** Uses Daniel Estévez's
[pm-remez](https://github.com/maitbayev/pm-remez) library for the
prototype filter, following fred harris's 1/f stopband weighting
recommendation.

---

## Project status

### Completed

- [x] Python reference model with filter design (pm-remez)
- [x] Coefficient generation and export
- [x] All RTL modules (coeff_rom, delay_line, mac, fir_branch,
      polyphase_filterbank, fft_4pt, polyphase_channelizer_top)
- [x] Testbenches for all modules (7/7 passing)
- [x] Vivado simulation scripts
- [x] iCE40 UltraPlus synthesis (92% LUT, 4 DSPs, 39 MHz F_max)
- [x] Lattice Radiant project with PDC pin constraints
- [x] STM32CubeIDE project with SPI4 driver (`sic_fpga.c`/`.h`)
- [x] Hardware bring-up complete — SPI link verified, real channelizer
      data flowing
- [x] Full I/Q SPI protocol (4 channels × I + Q, 17 bytes/transfer)
- [x] 2-stage input synchronizers for metastability protection
- [x] Documentation (WIRING_GUIDE, TOOLCHAIN_SETUP, HARDWARE_BRINGUP,
      STM32_SETUP_GUIDE)

### In progress

- [ ] Complex I/Q channelizer — `polyphase_channelizer_top` currently
      processes the real part only (imaginary input is hardwired to
      zero)

### Next

- [ ] Complex I/Q filterbank — process both `sample_re` and `sample_im`
- [ ] I2S ADC integration — replace the test pattern with TLV320ADC6120 input
- [ ] SIC algorithm on STM32 — peak detection, signal reconstruction,
      subtraction
- [ ] Integration with FunCube+ payload bus
- [ ] Wire-format detection record emission (see
      [`../docs/mdt-sic-wire-protocol.md`](../docs/mdt-sic-wire-protocol.md))

---

## Documentation

| Document | Path | Description |
|---|---|---|
| Wiring Guide | [`syn/ice40/WIRING_GUIDE.md`](syn/ice40/WIRING_GUIDE.md) | Hardware connections, pin mapping, programming |
| Toolchain Setup | [`syn/ice40/TOOLCHAIN_SETUP.md`](syn/ice40/TOOLCHAIN_SETUP.md) | Radiant, MSYS2, openFPGALoader |
| Hardware Bring-up | [`firmware/stm32/HARDWARE_BRINGUP.md`](firmware/stm32/HARDWARE_BRINGUP.md) | Step-by-step bring-up checklist |
| STM32 Setup | [`firmware/stm32/STM32_SETUP_GUIDE.md`](firmware/stm32/STM32_SETUP_GUIDE.md) | STM32CubeIDE project guide |
| RTL Reference | [`rtl/README.md`](rtl/README.md) | Module descriptions and timing |
| Simulation | [`sim/README.md`](sim/README.md) | Testbench summary |
| Filter Design Notebook | [`../docs/polyphase_channelizer.ipynb`](../docs/polyphase_channelizer.ipynb) | Filter design and visualization |
| Mission Concept | [`../docs/funcube-mission-concept.md`](../docs/funcube-mission-concept.md) | FunCube+ payload mission concept |
| Wire Protocol | [`../docs/mdt-sic-wire-protocol.md`](../docs/mdt-sic-wire-protocol.md) | Detection record format |

---

## Repository layout (mdt_sic/)

```
mdt_sic/
├── README.md                          (this file)
├── rtl/
│   ├── pkg/channelizer_pkg.vhd
│   ├── channelizer/                   Serial-MAC channelizer (one MAC per branch)
│   │   ├── coeff_rom.vhd
│   │   ├── delay_line.vhd
│   │   ├── mac.vhd
│   │   ├── fir_branch.vhd
│   │   ├── polyphase_filterbank.vhd
│   │   ├── fft_4pt.vhd
│   │   └── polyphase_channelizer_top.vhd
│   └── coeffs/mdt_coeffs.hex          (committed coefficient file)
├── sim/                               Module-level testbenches + run_tests.tcl
├── syn/
│   ├── ice40/                         Open-source flow (Yosys + GHDL + nextpnr)
│   │                                  and Radiant top wrapper, constraints,
│   │                                  and toolchain documentation
│   └── radiant/sic_receiver/          Lattice Radiant project (.rdf, .pdc, etc.)
└── firmware/stm32/                    STM32CubeIDE project for the SPI host MCU
```

---

## See also

- [`../README.md`](../README.md) — top-level overview and the
  polyphase channelizer introduction.
- [`../docs/README.md`](../docs/README.md) — coefficient generation
  notebook: environment setup and what it produces.
- [`../haifuraiya/README.md`](../haifuraiya/README.md) — the parallel
  Haifuraiya subproject (64-channel ZCU102 + ADRV9002 channelizer
  for Opulent Voice FDMA).
