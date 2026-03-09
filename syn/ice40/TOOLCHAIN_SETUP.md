# iCE40 Toolchain Setup Guide

## Overview

This guide covers installing and using the open-source FPGA toolchain for the iCE40UP5K. Unlike Vivado, this toolchain is completely free, fast, and runs on Linux, macOS, and Windows using WSL.

**Toolchain Components:**

| Tool | Purpose | Equivalent in Vivado |
|------|---------|---------------------|
| **Yosys** | Synthesis (VHDL/Verilog to netlist) | Vivado Synthesis |
| **GHDL** | VHDL frontend for Yosys | Built into Vivado |
| **nextpnr-ice40** | Place and Route | Vivado Implementation |
| **icepack** | Bitstream generation | write_bitstream |
| **iceprog** | Programming | Hardware Manager |
| **icetime** | Timing analysis | Timing Reports |

All tools are part of **Project IceStorm** and are well-maintained.

---

## Installation

### Ubuntu / Debian (Recommended)

```bash
# Update package list
sudo apt update

# Install pre-built packages (Ubuntu 22.04+, Debian 12+)
sudo apt install -y fpga-icestorm yosys nextpnr-ice40

# Install GHDL (for VHDL support)
sudo apt install -y ghdl

# Install the GHDL plugin for Yosys
# This may require building from source - see "Building GHDL Plugin" below
```

**Verify installation:**

```bash
yosys --version
# Yosys 0.38 (or similar)

nextpnr-ice40 --version
# nextpnr-ice40 -- Next Generation Place and Route

icepack --help
# Usage: icepack [options] input.asc output.bin

iceprog --help
# Simple programming tool for FTDI-based Lattice iCE programmers

ghdl --version
# GHDL 3.0.0 (or similar)
```

### Building GHDL Plugin for Yosys (If Needed)

The GHDL plugin allows Yosys to synthesize VHDL directly. If your distribution doesn't include it:

```bash
# Install dependencies
sudo apt install -y build-essential clang bison flex \
    libreadline-dev gawk tcl-dev libffi-dev git \
    graphviz xdot pkg-config python3 libboost-system-dev \
    libboost-python-dev libboost-filesystem-dev zlib1g-dev \
    gnat ghdl

# Clone Yosys with GHDL plugin support
git clone https://github.com/ghdl/ghdl-yosys-plugin.git
cd ghdl-yosys-plugin
make
sudo make install
```

**Test GHDL plugin:**

```bash
yosys -m ghdl -p "ghdl --version"
# Should show GHDL version without errors
```

### macOS (Homebrew)
```bash
# Create a directory for FPGA tools
cd ~
mkdir fpga-tools
cd fpga-tools

# Install IceStorm tools (not in Homebrew, build from source)
brew install libftdi pkg-config
git clone https://github.com/YosysHQ/icestorm.git
cd icestorm
make -j$(sysctl -n hw.ncpu)
sudo make install
cd ..

# Verify IceStorm
which icepack
icepack --help

# Install GHDL
brew install ghdl

# Install Yosys
brew install yosys

# Install nextpnr (not in Homebrew, build from source)
brew install cmake boost python3 eigen
git clone https://github.com/YosysHQ/nextpnr.git
cd nextpnr
cmake -DARCH=ice40 \
      -DICESTORM_INSTALL_PREFIX=/usr/local \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DBUILD_PYTHON=OFF \
      -DBUILD_GUI=OFF \
      -B build
cmake --build build -j$(sysctl -n hw.ncpu)
sudo cmake --install build

# Verify nextpnr
nextpnr-ice40 --version

# Install GHDL plugin
cd ~/fpga-tools
git clone https://github.com/ghdl/ghdl-yosys-plugin.git
cd ghdl-yosys-plugin
make
sudo make install

# verify install
yosys -m ghdl -p "ghdl --version"
```

### Windows (WSL2 Recommended)

1. Install WSL2 with Ubuntu 22.04
2. Follow the Ubuntu instructions above
3. For USB programming, install usbipd-win:

```powershell
# In PowerShell (admin)
winget install usbipd
```

```bash
# In WSL, attach the iCE40 programmer
# (Run in Windows first: usbipd wsl attach --busid <BUS-ID>)
sudo apt install linux-tools-generic hwdata
```

---

## Project Structure (Expected)

```
syn/ice40/
├── Makefile              # Build automation
├── sic_top.pcf           # Pin constraints
├── sic_top_ice40.vhd     # iCE40 top-level wrapper
├── WIRING_GUIDE.md       # Hardware connections
├── build/                # Generated files (gitignored)
│   ├── sic_receiver.json # Synthesis output
│   ├── sic_receiver.asc  # Place & route output
│   ├── sic_receiver.bin  # Bitstream
│   └── sic_receiver.rpt  # Reports
└── README.md             # This file
```

---

## Build Commands

All commands run from `syn/ice40/`:

### Full Build

```bash
make
```

This runs synthesis, then place & route, then bitstream generation.

### Individual Steps

```bash
# Synthesis only (VHDL → JSON netlist)
make build/sic_receiver.json

# Place and Route only (JSON → ASC)
make build/sic_receiver.asc

# Bitstream only (ASC → BIN)
make build/sic_receiver.bin
```

### Programming

```bash
# Program to flash (persistent)
make prog

# Program to SRAM (volatile, for testing)
make prog-sram
```

### Analysis

```bash
# View timing report
make timing

# View resource utilization
make resources
```

### Clean

```bash
make clean
```

---

## Understanding the Build Flow

### Step 1: Synthesis (Yosys + GHDL)

```
VHDL Source Files
       │
       ▼
   ┌───────┐
   │ GHDL  │  Parses VHDL, checks syntax
   └───┬───┘
       │
       ▼
   ┌───────┐
   │ Yosys │  Optimizes logic, maps to iCE40 primitives
   └───┬───┘
       │
       ▼
  JSON Netlist (build/sic_receiver.json)
```

**What Yosys does:**
- Reads VHDL via GHDL plugin
- Performs technology mapping to iCE40 LUTs, flip-flops, block RAM
- Optimizes logic (constant propagation, dead code removal)
- Outputs a JSON netlist

### Step 2: Place and Route (nextpnr)

```
JSON Netlist + PCF Constraints
              │
              ▼
      ┌──────────────┐
      │ nextpnr-ice40│  Places cells, routes wires
      └──────┬───────┘
              │
              ▼
   ASC File (build/sic_receiver.asc)
   + Report (build/sic_receiver.rpt)
```

**What nextpnr does:**
- Places logic cells in the FPGA fabric
- Routes connections between cells
- Respects pin constraints from PCF file
- Reports timing and utilization

### Step 3: Bitstream Generation (icepack)

```
ASC File
    │
    ▼
┌─────────┐
│icepack │  Converts to binary format
└────┬────┘
     │
     ▼
BIN File (build/sic_receiver.bin)
```

### Step 4: Programming (iceprog)

```
BIN File
    │
    ▼
┌─────────┐
│iceprog │  Transfers via FTDI USB
└────┬────┘
     │
     ▼
iCE40 FPGA (configured!)
```

---

## Pin Constraints (PCF Format)

The PCF file maps signal names to physical pins:

```
# Format: set_io <signal_name> <pin_number>

set_io clk_12m     35    # 12 MHz oscillator
set_io spi_cs_n    16    # SPI chip select
set_io spi_sclk    15    # SPI clock
set_io spi_mosi    17    # SPI data in
set_io spi_miso    14    # SPI data out
```

**Key differences from Vivado XDC:**
- No `PACKAGE_PIN` keyword
- No `IOSTANDARD` (iCE40UP5K is always LVCMOS33)
- Pin numbers are ball numbers, not names
- Much simpler syntax

---

## Common Build Errors and Solutions

### "ghdl: command not found"

```bash
# Install GHDL
sudo apt install ghdl
```

### "ERROR: Unable to find module 'ghdl'"

The GHDL plugin isn't installed. Build it from source:

```bash
git clone https://github.com/ghdl/ghdl-yosys-plugin.git
cd ghdl-yosys-plugin
make
sudo make install
```

### "ERROR: cell type 'XXX' is unsupported"

The design uses a VHDL construct that doesn't map to iCE40. Common fixes:
- Avoid `ieee.math_real` in synthesizable code (simulation only?)
- Replace division with shifts where possible
- Check for unsupported block RAM configurations

### "ERROR: pin 'XXX' is unconstrained"

Add the pin to the PCF file:

```
set_io signal_name PIN_NUMBER
```

### "nextpnr: Timing failure"

The design doesn't meet timing. Options:
- Add `--timing-allow-fail` to continue anyway (for debug)
- Reduce clock frequency
- Add pipeline registers
- Check for long combinational paths

### "iceprog: Can't find iCE FTDI USB device"

1. Check USB connection
2. Add udev rules (Linux):

```bash
# Create /etc/udev/rules.d/53-lattice-ftdi.rules
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0660", GROUP="plugdev"
```

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
# Unplug and replug the board
```

3. Add yourself to plugdev group:

```bash
sudo usermod -a -G plugdev $USER
# Log out and back in
```

---

## Timing Analysis

Run timing analysis:

```bash
make timing
```

Example output:

```
// Reading input .asc file..
// Reading chipdb file..
// Creating timing netlist..

icetime topance report for sic_top_ice40

Total path delay: 12.34 ns (80.91 MHz)

Path details:
  Source: spi_state_FSM_FF_0
  Destination: spi_tx_data_7
  Delay: 12.34 ns
```

**Key metrics:**
- **Total path delay**: Longest combinational path
- **Max frequency**: 1 / (total path delay)
- Aim for 10-20% margin below your target clock

---

## Resource Utilization

View resource usage:

```bash
make resources
```

Example output:

```
Device utilisation:
   ICESTORM_LC:   876/ 5280    16%
   ICESTORM_RAM:    2/   30     6%
   SB_IO:          18/   96    18%
   SB_GB:           1/    8    12%
   ICESTORM_PLL:    0/    1     0%
   SB_WARMBOOT:     0/    1     0%
```

**Resource types:**
- **ICESTORM_LC**: Logic cells (LUTs + flip-flops)
- **ICESTORM_RAM**: Block RAM (4 Kbit each)
- **SB_IO**: I/O pins
- **SB_GB**: Global buffers (for clocks)
- **ICESTORM_PLL**: PLLs

---

## Comparison: Yosys/nextpnr vs Vivado

| Aspect | Yosys/nextpnr | Vivado |
|--------|---------------|--------|
| **Cost** | Free, open source | Free for WebPACK devices |
| **Build time** | ~5-30 seconds | ~1-5 minutes |
| **GUI** | None (command line) | Full IDE |
| **VHDL support** | Via GHDL plugin | Native |
| **Simulation** | GHDL or other tools | Built-in |
| **Debug** | External tools | ILA, VIO |
| **Device support** | iCE40 only (for this flow) | Xilinx only |

**Why we use it:**
- Martin's hardware uses iCE40UP5K (Lattice)
- Vivado doesn't support Lattice parts
- Fast iteration
- Scriptable and we believe CI/CD friendly

---

## Quick Reference Card

```bash
# Build everything
make

# Program flash
make prog

# Program SRAM (volatile)
make prog-sram

# View timing
make timing

# View resources
make resources

# Clean build
make clean

# Manual synthesis (debug)
yosys -m ghdl -p "ghdl --std=08 *.vhd -e top_module; synth_ice40 -json out.json"

# Manual place & route (debug)
nextpnr-ice40 --up5k --package sg48 --json out.json --pcf pins.pcf --asc out.asc

# Manual bitstream (debug)
icepack out.asc out.bin

# Manual program (debug)
iceprog out.bin
```

---

## Getting Help

- **Yosys documentation**: https://yosyshq.readthedocs.io/
- **nextpnr documentation**: https://github.com/YosysHQ/nextpnr
- **Project IceStorm**: https://clifford.at/icestorm/
- **GHDL manual**: https://ghdl.github.io/ghdl/
- **iCE40 family handbook**: Lattice website

---

## Next Steps

1. Install the toolchain
2. Verify with `make` in `syn/ice40/`
3. Connect our hardware per `WIRING_GUIDE.md`
4. Program with `make prog`
5. Test SPI communication from STM32a
