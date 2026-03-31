# iCE40 Toolchain Setup Guide

## Overview

This guide covers installing and using the toolchain for the iCE40UP5K. Two
toolchains are supported:

| Toolchain | Platform | Use Case |
|-----------|----------|----------|
| **Lattice Radiant** | Windows | Synthesis, place & route, bitstream generation |
| **Yosys/nextpnr** | Linux, macOS, WSL2 | Open-source alternative |

For **programming** the FPGA on Windows, we use **openFPGALoader via MSYS2**
because the Lattice Radiant Programmer GUI is broken on some Windows
configurations.

---

## Windows Workflow (Radiant + MSYS2)

This is the current working workflow for the prototype development environment.

### Step 1: Install Lattice Radiant

Download from https://www.latticesemi.com/radiant (free, requires registration).

Use Radiant for:
- Editing VHDL source
- Synthesis and place & route
- Generating the bitstream (`.bin` file)

The output bitstream will be at:
```
syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

### Step 2: Install MSYS2

MSYS2 provides a Unix-like environment on Windows that openFPGALoader runs in.

1. Download from https://www.msys2.org/
2. Install with default settings
3. Open **MSYS2 UCRT64** from the Start Menu (yellow icon)
4. Install openFPGALoader:

```bash
pacman -S mingw-w64-ucrt-x86_64-openFPGALoader
```

Verify installation:

```bash
openFPGALoader --version
```

### Step 3: Install Zadig (USB Driver)

openFPGALoader requires the WinUSB driver on the iCE40 FTDI interface.

1. Download Zadig from https://zadig.akeo.ie/
2. Keep it somewhere easy to find — **you will need it repeatedly**

> ⚠️ **Windows reverts the FTDI driver to the default on every USB reconnect.**
> You must run Zadig and set WinUSB every time you reconnect the iCE40 board.

### Step 4: Program the FPGA

Every time you want to program the FPGA:

1. **Disconnect the STM32 Nucleo board** (unplug its USB)
   - The SPI lines are shared with the flash programming interface
   - The STM32 driving these lines will prevent flash programming

2. **Run Zadig:**
   - Open Zadig
   - Options → List All Devices
   - Select **"USB Serial Converter A"** (Interface 0)
   - Verify right side shows **WinUSB**
   - If it shows FTDI, click **Replace Driver**

3. **Open MSYS2 UCRT64** from Start Menu

4. **Run the programming command:**

```bash
openFPGALoader -b ice40_generic -f --unprotect-flash /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

**Successful output looks like this:**
```
empty
write to flash
Can't read iSerialNumber field from FTDI: considered as empty string
Jtag frequency : requested 6.00MHz   -> real 6.00MHz
Parse file DONE
JEDEC ID: 0x20ba16
Detected: micron N25Q32 64 sectors size: 32Mb
Erasing: [==================================================] 100.00%
Done
Writing: [==================================================] 100.00%
Done
Wait for CDONE DONE
```

> ⚠️ If you see `Jedec ID: ff` with **no progress bar**, the driver has reverted.
> Go back to step 2 and run Zadig again.

5. **Verify the flash contents** (optional but recommended):

```bash
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/readback.bin
md5sum /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
md5sum /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/readback.bin
```

Both MD5 hashes must match. If they don't match, the flash was not written
correctly — run Zadig again and retry.

6. **Reconnect the STM32 board** after programming is complete.

---

## Windows Path Syntax in MSYS2

In MSYS2, Windows paths use forward slashes with a leading `/c/` instead of `C:\`:

| Windows | MSYS2 |
|---------|-------|
| `C:\Mode-Dynamic-Transponder\` | `/c/Mode-Dynamic-Transponder/` |
| `C:\Users\Kindl\` | `/c/Users/Kindl/` |

---

## Radiant Synthesis Notes

### Clean Rebuild

Radiant does not have a "Clean and Rebuild" button in the GUI. To force a
full rebuild:

1. Navigate to `syn/radiant/sic_receiver/impl_1/` in Windows Explorer
2. Delete all files in that folder
3. Click the green triangle in Radiant to rebuild

### PDC Constraint File

The post-synthesis constraint file is at:
```
syn/radiant/sic_receiver/impl_1/sic_top.pdc
```

This maps signal names to physical FPGA pin numbers. Changes here require
a full rebuild.

### Verifying Synthesis Results

After synthesis, open the **Device Constraint Editor** in Radiant
(Tools → Device Constraint Editor) to verify that signals are placed on
the expected physical pins.

---

## Open-Source Toolchain (Linux/macOS/WSL2)

For the Yosys/nextpnr open-source toolchain, see below. This produces
bitstreams using the `.pcf` pin constraint format (nextpnr syntax) rather
than Radiant's `.pdc` format.

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y fpga-icestorm yosys nextpnr-ice40 ghdl
```

### macOS (Homebrew)

```bash
# Install IceStorm tools
brew install libftdi pkg-config
git clone https://github.com/YosysHQ/icestorm.git
cd icestorm && make -j$(sysctl -n hw.ncpu) && sudo make install

# Install GHDL, Yosys, nextpnr
brew install ghdl yosys cmake boost python3 eigen
git clone https://github.com/YosysHQ/nextpnr.git
cd nextpnr
cmake -DARCH=ice40 -DICESTORM_INSTALL_PREFIX=/usr/local \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF -B build
cmake --build build -j$(sysctl -n hw.ncpu)
sudo cmake --install build
```

### Build Commands (Yosys/nextpnr)

```bash
cd syn/ice40
make          # Synthesize, place & route, generate bitstream
make prog     # Program to flash (persistent)
make prog-sram  # Program to SRAM (volatile, faster for testing)
make timing   # View timing report
make resources  # View resource utilization
make clean    # Clean build outputs
```

---

## Toolchain Comparison

| Aspect | Radiant (Windows) | Yosys/nextpnr |
|--------|-------------------|---------------|
| Cost | Free (registration required) | Free, open source |
| Build time | ~30–60 seconds | ~5–30 seconds |
| GUI | Full IDE | Command line |
| VHDL support | Native | Via GHDL plugin |
| Programmer | Broken — use openFPGALoader | iceprog (works) |
| Constraint format | PDC | PCF |
| Status | Current workflow | Alternative |

---

## Quick Reference

### Windows (Current Workflow)

```bash
# Open MSYS2 UCRT64 from Start Menu, then:

# Program FPGA (STM32 must be disconnected, Zadig WinUSB must be set)
openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin

# Verify flash contents
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 readback.bin
md5sum /c/Mode-Dynamic-Transponder/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
md5sum readback.bin

# Bulk erase (if programming fails due to protection)
openFPGALoader -b ice40_generic --bulk-erase --unprotect-flash
```

### Linux/macOS (Yosys/nextpnr)

```bash
cd syn/ice40
make          # Full build
make prog     # Program flash
make prog-sram  # Program SRAM
make timing   # Timing analysis
make resources  # Resource usage
make clean    # Clean build
```

---

## Getting Help

- **openFPGALoader**: https://trabucayre.github.io/openFPGALoader/
- **Zadig**: https://zadig.akeo.ie/
- **MSYS2**: https://www.msys2.org/
- **Yosys**: https://yosyshq.readthedocs.io/
- **nextpnr**: https://github.com/YosysHQ/nextpnr
- **Project IceStorm**: https://clifford.at/icestorm/
- **GHDL**: https://ghdl.github.io/ghdl/
- **iCE40 UltraPlus Family Data Sheet**: Lattice website
