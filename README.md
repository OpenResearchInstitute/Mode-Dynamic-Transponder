# Mode-Dynamic-Transponder

A polyphase channelizer implementation in VHDL, designed for spectrum monitoring and digital communications applications.

## Overview

This project implements a polyphase channelizer that splits a wideband input signal into multiple narrowband frequency channels. The design supports two configurations:

| Configuration | Channels | Sample Rate | Target | Application |
|---------------|----------|-------------|--------|-------------|
| **MDT** | 4 | 40 ksps | iCE40 UltraPlus | FunCube+ transponder monitoring |
| **Haifuraiya** | 64 | 10 Msps | ZCU102 | Opulent Voice FDMA |

## What is a Polyphase Channelizer?

A polyphase channelizer efficiently splits a wideband signal into N frequency channels using:

1. **Polyphase Filterbank** - N parallel FIR filters, each processing every Nth sample
2. **FFT** - Converts filtered outputs to frequency domain

This is computationally efficient compared to running N separate bandpass filters, and is widely used in software-defined radio, satellite communications, and spectrum analyzers.

```
                    ┌─────────────────────────────────────────────┐
                    │         Polyphase Channelizer               │
                    │                                             │
 Wideband   ───────►│  ┌────────-────┐      ┌─────┐               │
 Input              │  │ Polyphase   │      │     │  Channel 0 ──►│
                    │  │ Filterbank  │─────►│ FFT │  Channel 1 ──►│
                    │  │ (N branches)│      │     │  Channel 2 ──►│
                    │  └───────────-─┘      └─────┘     ...    ──►│
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
├── README.md               # This file
├── docs/                   # Documentation and reference models
│   ├── polyphase_channelizer.ipynb  # Python reference implementation
│   └── mdt-model.ipynb              # Store-and-forward simulation
├── rtl/                    # Synthesizable VHDL
│   ├── README.md           # RTL documentation
│   ├── pkg/                # Packages
│   │   └── channelizer_pkg.vhd
│   ├── channelizer/        # Core modules
│   │   ├── coeff_rom.vhd
│   │   ├── delay_line.vhd
│   │   ├── mac.vhd
│   │   ├── fir_branch.vhd
│   │   ├── polyphase_filterbank.vhd
│   │   ├── fft_4pt.vhd
│   │   ├── fft_64pt.vhd
│   │   └── polyphase_channelizer_top.vhd
│   └── coeffs/             # Filter coefficients
│       ├── mdt_coeffs.hex
│       └── haifuraiya_coeffs.hex
├── sim/                    # Simulation
│   ├── README.md           # Testbench documentation
│   ├── run_tests.tcl       # Vivado TCL script
│   └── tb_*.vhd            # Testbenches
├── syn/                    # Synthesis
│   ├── ice40/              # iCE40 UltraPlus (Yosys/nextpnr)
│   │   ├── Makefile
│   │   ├── sic_top.pcf             # Pin constraints
│   │   ├── sic_top_ice40.vhd       # iCE40 top wrapper (SPI, LEDs)
│   │   ├── TOOLCHAIN_SETUP.md      # Yosys/nextpnr installation
│   │   └── WIRING_GUIDE.md         # Hardware connections
│   └── zcu102/             # Xilinx ZCU102 (Vivado) - future
│       └── README.md
└── firmware/               # MCU firmware
    └── stm32/              # STM32H7 driver
        ├── sic_fpga.h
        └── sic_fpga.c
```

## Quick Start

### Prerequisites

**For simulation:**
- Vivado 2022.2 (for simulation and Xilinx synthesis)
- Python 3.8+ with NumPy, SciPy, Matplotlib (for reference model)

**For iCE40 synthesis:**
- Yosys with GHDL plugin
- nextpnr-ice40
- IceStorm tools (icepack, iceprog)
- See `syn/ice40/TOOLCHAIN_SETUP.md` for detailed installation

**For STM32 firmware:**
- STM32CubeIDE or arm-none-eabi-gcc
- STM32H7 HAL libraries

### Running Simulations

```tcl
# In Vivado TCL console:
cd /path/to/Mode-Dynamic-Transponder
source sim/run_tests.tcl
create_sim_project channelizer_sim
run_all_tests
```

Or run a single testbench:

```tcl
run_test tb_mac
run_test_gui tb_fir_branch   # With waveform viewer
```

### Building for iCE40

```bash
cd syn/ice40
make            # Synthesize, place & route, generate bitstream
make prog       # Program the FPGA
```

Resource usage (iCE40UP5K):
- LUTs: 4847/5280 (92%)
- DSPs: 4/8 (50%)
- Fmax: 39 MHz (target: 12 MHz) ✓

### Hardware Setup

See `syn/ice40/WIRING_GUIDE.md` for connecting:
- iCE40UP5K-B-EVN (~$50)
- NUCLEO-H7B3ZI-Q (~$70)

### Generating Coefficients

The filter coefficients are generated by the Python reference model:

```bash
cd docs
jupyter notebook polyphase_channelizer.ipynb
# Run all cells - generates rtl/coeffs/*.hex files
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

### Data Flow

1. Input samples arrive one at a time
2. Samples are distributed round-robin to N filter branches
3. Each branch filters with its portion of the prototype lowpass filter
4. After N samples, all branch outputs feed the FFT
5. FFT produces **all N frequency channels simultaneously**

### Output Model

The channelizer outputs all N channels at once - there's no channel selection at this stage. For Haifuraiya, all 64 channels are packetized into DVB-S2/X frames and transmitted. Receivers get everything and filter locally for the channels they want to monitor.

This "broadcast everything" model supports:
- **Single operator** listening to one channel
- **Conference room** with multiple operators on different channels
- **Locus** (satellite repeater/conference room server) managing multiple simultaneous conversations

### Resource Estimates

| Resource | MDT (iCE40 UP) | Haifuraiya (ZCU102) |
|----------|----------------|---------------------|
| Flip-flops | ~1,500 | ~30,000 |
| LUTs | ~4,850 (actual) | ~15,000 |
| DSPs | 4 | 64 |
| Block RAM | 0 | 8 |

## Configuration

The design is parameterized via `channelizer_pkg.vhd`:

```vhdl
-- Use pre-defined configuration
constant CFG : channelizer_config_t := MDT_CONFIG;

-- Or customize
constant CFG : channelizer_config_t := (
    n_channels      => 8,
    taps_per_branch => 20,
    data_width      => 16,
    coeff_width     => 16,
    accum_width     => 38
);
```

## Design Notes

### Power Budget

The iCE40UP5K was chosen for its low power consumption (~5mW typical). The entire signal processing subsystem must fit within 0.5W for 2U CubeSat deployment.

### Magnitude Computation

Moved from FPGA to STM32 to save LUTs. The STM32H7's FPU computes `sqrt(I² + Q²)` faster than FPGA LUT-based approximations anyway.

### Filter Design

Uses Daniel Estévez's pm-remez library for prototype filter design, following fred harris's 1/f stopband weighting recommendation. See `docs/polyphase_channelizer.ipynb` for details and visualization.

## Documentation

- **[rtl/README.md](rtl/README.md)** - Detailed RTL documentation, module descriptions, timing diagrams
- **[sim/README.md](sim/README.md)** - Testbench descriptions, simulation setup, Vivado usage
- **[syn/ice40/TOOLCHAIN_SETUP.md](syn/ice40/TOOLCHAIN_SETUP.md)** - Yosys/nextpnr installation guide
- **[syn/ice40/WIRING_GUIDE.md](syn/ice40/WIRING_GUIDE.md)** - Hardware connections for prototype
- **[docs/polyphase_channelizer.ipynb](docs/polyphase_channelizer.ipynb)** - Python reference model with filter design, visualization, and coefficient export

## Project Status

### Completed
- [x] Python reference model with filter design (pm-remez)
- [x] Coefficient generation and export
- [x] All RTL modules (coeff_rom, delay_line, mac, fir_branch, polyphase_filterbank, fft_4pt, fft_64pt, top)
- [x] Testbenches for all modules (7/7 passing)
- [x] Vivado simulation scripts
- [x] Synthesize for iCE40 UltraPlus (MDT) — 92% LUT, 4 DSPs, 39 MHz Fmax
- [x] STM32 driver with magnitude computation
- [x] Documentation

### Next Steps
- [x] Order dev boards
- [ ] Hardware verification with dev boards
- [ ] I2S ADC integration
- [ ] Full I/Q SPI protocol
- [ ] Synthesize for ZCU102 (Haifuraiya)
- [ ] Integration with FunCube+ receiver
- [ ] Integration with Opulent Voice modem

## Related Projects

- [Martin Ling's dynamic-transponder](https://github.com/martinling/dynamic-transponder) - Hardware reference design
- [Opulent Voice Protocol](https://github.com/OpenResearchInstitute/pluto_msk) - Digital voice protocol that will use this channelizer
- AMSAT-UK FunCube+
- ORI Haifuraiya

## Contributing

This is an Open Research Institute project. Contributions are welcome!

1. Fork the repository!
2. Create a feature branch!
3. Submit a pull request!
4. Have fun!

For questions or discussion, join the [ORI community channels](https://openresearch.institute/getting-started)

## License

This project is open source, using CERN OHL 2.0 and other OSI approved licenses

## Acknowledgments

- Open Research Institute engineering team
- AMSAT-UK community for FunCube documentation, participation, and leadership
- Contributors to the Opulent Voice and Haifuraiya projects
- Daniel Estévez (EA4GPZ) for pm-remez library
- Martin Ling for hardware design reference
- F5OEO for filter design feedback

---

*Open Research Institute - Advancing open source digital radio for space and terrestrial use*
