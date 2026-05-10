# Mode-Dynamic-Transponder

A polyphase channelizer implementation in VHDL for the AMSAT-UK FunCube+ Mode Dynamic Transponder (MDT), designed for spectrum monitoring and SIC (Successive Interference Cancellation) signal processing.

## Overview

This project implements a polyphase channelizer that splits a wideband input signal into multiple narrowband frequency channels. The design supports two configurations:

| Configuration | Channels | Sample Rate | Target | Application |
|---------------|----------|-------------|--------|-------------|
| **MDT** | 4 | 40 ksps | iCE40 UltraPlus | FunCube+ transponder monitoring |
| **Haifuraiya** | 64 | 10 Msps | ZCU102 | Opulent Voice FDMA |

## What is a Polyphase Channelizer?

A polyphase channelizer efficiently splits a wideband signal into N frequency channels using:

1. **Polyphase Filterbank** — N parallel FIR filters, each processing every Nth sample
2. **FFT** — Converts filtered outputs to frequency domain

This is computationally efficient compared to running N separate bandpass filters, and is widely used in software-defined radio, satellite communications, and spectrum analyzers.

```
                    ┌─────────────────────────────────────────────┐
                    │         Polyphase Channelizer               │
                    │                                             │
 Wideband   ───────►│  ┌─────────────┐      ┌─────┐              │
 Input              │  │ Polyphase   │      │     │  Channel 0 ──►│
                    │  │ Filterbank  │─────►│ FFT │  Channel 1 ──►│
                    │  │ (N branches)│      │     │  Channel 2 ──►│
                    │  └─────────────┘      └─────┘     ...    ──►│
                    │                                             │
                    └─────────────────────────────────────────────┘
```

## System Architecture

The SIC (Successive Interference Cancellation) receiver splits processing between FPGA and MCU:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SIC Receiver System                               │
│                                                                         │
│  ┌─────────────────────────────────────────┐    ┌───────────────────┐  │
│  │           iCE40 FPGA                     │    │    STM32H7        │  │
│  │                                          │    │                   │  │
│  │  I2S ──► Polyphase ──► FFT ──► SPI ─────────► Magnitude ──► SIC  │  │
│  │  ADC     Filterbank    4pt     Slave     │    │ Computation  Algo │  │
│  │                                          │    │                   │  │
│  └─────────────────────────────────────────┘    └───────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

The FPGA handles real-time DSP (channelization), while the STM32 handles post-processing (magnitude, peak detection, SIC algorithm). This split keeps the FPGA within the 0.5W power budget for CubeSat deployment.

## Repository Structure

```
Mode-Dynamic-Transponder/
├── README.md                    # This file
├── docs/                        # Documentation and reference models
│   ├── polyphase_channelizer.ipynb  # Python reference implementation
│   └── mdt-model.ipynb              # Store-and-forward simulation
├── rtl/                         # Synthesizable VHDL
│   ├── README.md
│   ├── pkg/                     # Packages
│   │   └── channelizer_pkg.vhd
│   ├── channelizer/             # Core modules
│   │   ├── coeff_rom.vhd
│   │   ├── delay_line.vhd
│   │   ├── mac.vhd
│   │   ├── fir_branch.vhd
│   │   ├── polyphase_filterbank.vhd
│   │   ├── fft_4pt.vhd
│   │   ├── fft_64pt.vhd
│   │   └── polyphase_channelizer_top.vhd
│   └── coeffs/                  # Filter coefficients
│       ├── mdt_coeffs.hex
│       └── haifuraiya_coeffs.hex
├── sim/                         # Simulation
│   ├── README.md
│   ├── run_tests.tcl
│   └── tb_*.vhd
├── syn/                         # Synthesis
│   ├── ice40/                   # iCE40 UltraPlus (Lattice Radiant)
│   │   ├── sic_top_ice40.vhd   # iCE40 top wrapper (SPI, LEDs, synchronizers)
│   │   ├── TOOLCHAIN_SETUP.md  # Radiant + MSYS2/openFPGALoader setup
│   │   ├── WIRING_GUIDE.md     # Hardware connections (read this first!)
│   │   └── README.md
│   ├── radiant/                 # Lattice Radiant project
│   │   └── sic_receiver/
│   │       ├── sic_receiver.rdf         # Radiant project file
│   │       └── source/impl_1/sic_top.pdc  # Pin constraints
│   └── zcu102/                  # Xilinx ZCU102 (future)
│       └── README.md
└── firmware/                    # MCU firmware
    └── stm32/
        ├── sic_receiver/        # Complete STM32CubeIDE project
        │   ├── sic_receiver.ioc # CubeMX config (SPI4, GPIO, clocks)
        │   ├── Core/Src/        # User code (main.c, sic_fpga.c, spi.c)
        │   ├── Core/Inc/        # Headers (sic_fpga.h)
        │   └── Drivers/         # STM32H7 HAL (self-contained build)
        ├── HARDWARE_BRINGUP.md  # Step-by-step bringup checklist
        └── STM32_SETUP_GUIDE.md # STM32CubeIDE setup guide
```

## Quick Start

### Hardware Required

| Item | Part Number | Cost |
|------|-------------|------|
| FPGA Board | Lattice iCE40UP5K-B-EVN | ~$50 |
| MCU Board | STM32 NUCLEO-H753ZI | ~$70 |
| Jumper wires | Female-Female Dupont | ~$5 |

See `mdt_sic/syn/ice40/WIRING_GUIDE.md` for complete connection details.

### Programming the FPGA (Windows)

The FPGA is programmed using Lattice Radiant for synthesis and openFPGALoader via MSYS2 for flashing. See `mdt_sic/syn/ice40/TOOLCHAIN_SETUP.md` for full setup.

```bash
# In MSYS2 UCRT64 (after running Zadig to set WinUSB driver):
openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

### Opening the STM32 Firmware

The firmware is a complete STM32CubeIDE project stored in `mdt_sic/firmware/stm32/sic_receiver/`.

1. Open STM32CubeIDE
2. **File → Import → General → Existing Projects into Workspace**
3. Browse to `mdt_sic/firmware/stm32/sic_receiver/`
4. Uncheck "Copy projects into workspace"
5. Build and flash

### Running Simulations

```tcl
# In Vivado TCL console:
cd /path/to/Mode-Dynamic-Transponder
source mdt_sic/sim/run_tests.tcl
create_sim_project channelizer_sim
run_all_tests
```

### Generating Coefficients

```bash
cd docs
jupyter notebook polyphase_channelizer.ipynb
# Run all cells — generates rtl/coeffs/*.hex files
```

## Architecture

### Module Hierarchy

```
polyphase_channelizer_top
├── coeff_rom                 # Filter coefficients (Block RAM)
├── polyphase_filterbank      # N parallel FIR branches
│   └── fir_branch (×N)
│       ├── delay_line        # Sample history (shift register)
│       └── mac               # Multiply-accumulate
└── fft_4pt / fft_64pt        # Frequency separation
```

### SPI Protocol

The FPGA is a SPI slave (Mode 0). The STM32 reads 17 bytes per transaction:

```
TX: [CMD=0x01] [0x00] [0x00] ... (17 bytes)
RX: [0x00] [I0_H][I0_L][Q0_H][Q0_L][I1_H][I1_L][Q1_H][Q1_L]
            [I2_H][I2_L][Q2_H][Q2_L][I3_H][I3_L][Q3_H][Q3_L]
```

### Resource Usage (iCE40UP5K, MDT Configuration)

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUTs | ~4,850 | 5,280 | 92% |
| DSPs | 4 | 8 | 50% |
| Fmax | 39 MHz | — | target: 12 MHz ✓ |

### Design Notes

**Power Budget:** The iCE40UP5K was chosen for its low power (~5mW typical). The signal processing subsystem must fit within 0.5W for 2U CubeSat deployment.

**Magnitude Computation:** Moved from FPGA to STM32 to save LUTs. The STM32H7's FPU computes `sqrt(I² + Q²)` faster than FPGA LUT-based approximations.

**SPI Synchronizers:** All SPI inputs use 2-stage flip-flop synchronizers before entering FPGA logic, preventing metastability at the 12 MHz / 1 MHz clock domain crossing.

**Filter Design:** Uses Daniel Estévez's pm-remez library for prototype filter design, following fred harris's 1/f stopband weighting recommendation.

## Project Status

### Completed
- [x] Python reference model with filter design (pm-remez)
- [x] Coefficient generation and export
- [x] All RTL modules (coeff_rom, delay_line, mac, fir_branch, polyphase_filterbank, fft_4pt, fft_64pt, top)
- [x] Testbenches for all modules (7/7 passing)
- [x] Vivado simulation scripts
- [x] Synthesize for iCE40 UltraPlus — 92% LUT, 4 DSPs, 39 MHz Fmax
- [x] Lattice Radiant project with PDC pin constraints
- [x] STM32CubeIDE project with SPI4 driver (sic_fpga.c/h)
- [x] Hardware bringup complete — SPI link verified, real channelizer data flowing
- [x] Full I/Q SPI protocol (4 channels × I + Q, 17 bytes/transfer)
- [x] 2-stage input synchronizers for metastability protection
- [x] Documentation (WIRING_GUIDE, TOOLCHAIN_SETUP, HARDWARE_BRINGUP)

### In Progress
- [ ] Complex I/Q channelizer — polyphase_channelizer_top currently processes real part only (imaginary input hardwired to zero)

### Next Steps
- [ ] Complex I/Q filterbank — process both sample_re and sample_im
- [ ] I2S ADC integration — replace test pattern with TLV320ADC6120 input
- [ ] SIC algorithm on STM32 — peak detection, reconstruction, subtraction
- [ ] Synthesize for ZCU102 (Haifuraiya / Opulent Voice)
- [ ] Integration with FunCube+ receiver
- [ ] Integration with Opulent Voice modem

## Documentation

| Document | Location | Description |
|----------|----------|-------------|
| Wiring Guide | `mdt_sic/syn/ice40/WIRING_GUIDE.md` | Hardware connections, pin mapping, programming |
| Toolchain Setup | `mdt_sic/syn/ice40/TOOLCHAIN_SETUP.md` | Radiant, MSYS2, openFPGALoader setup |
| Hardware Bringup | `mdt_sic/firmware/stm32/HARDWARE_BRINGUP.md` | Step-by-step bringup checklist |
| STM32 Setup | `mdt_sic/firmware/stm32/STM32_SETUP_GUIDE.md` | STM32CubeIDE project guide |
| RTL Reference | `rtl/README.md` | Module descriptions and timing |
| Python Reference | `docs/polyphase_channelizer.ipynb` | Filter design and visualization |

## Related Projects

- [Martin Ling's dynamic-transponder](https://github.com/martinling/dynamic-transponder) — Hardware reference design
- [Opulent Voice Protocol](https://github.com/OpenResearchInstitute/pluto_msk) — Digital voice protocol
- AMSAT-UK FunCube+
- ORI Haifuraiya

## Contributing

This is an Open Research Institute project. Contributions are welcome!

1. Fork the repository
2. Create a feature branch
3. Submit a pull request
4. Have fun!

For questions or discussion, join the [ORI community channels](https://openresearch.institute/getting-started)

## License

This project is open source, using CERN OHL 2.0 and other OSI approved licenses.

## Acknowledgments

- Open Research Institute engineering team
- AMSAT-UK community for FunCube documentation, participation, and leadership
- David Bowman G0MRF for the MDT concept
- Martin Ling for hardware design reference
- Daniel Estévez EA4GPZ for the pm-remez library
- F5OEO for filter design feedback

---

*Open Research Institute — Advancing open source digital radio for space and terrestrial use*
