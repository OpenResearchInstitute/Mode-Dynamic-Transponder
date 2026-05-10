# iCE40 Synthesis — Lattice Radiant

This directory contains the iCE40-specific top-level VHDL for the MDT SIC receiver,
targeting the **Lattice iCE40UP5K-B-EVN** evaluation board.

## Files

| File | Description |
|------|-------------|
| `sic_top_ice40.vhd` | Top-level VHDL wrapper (SPI slave, synchronizers, LEDs, channelizer integration) |
| `WIRING_GUIDE.md` | Hardware connections — **read this before connecting anything** |
| `TOOLCHAIN_SETUP.md` | Radiant synthesis and MSYS2/openFPGALoader programming setup |

The Radiant project files live in `../radiant/sic_receiver/`.

---

## Synthesis Results (Lattice Radiant 2025.2)

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUTs (ICESTORM_LC) | ~4,850 | 5,280 | 92% |
| DSPs | 4 | 8 | 50% |
| Block RAM | 0 | 30 | 0% |
| I/O Pins | ~20 | 96 | — |
| Fmax | 39 MHz | — | target: 12 MHz ✓ |

---

## Building with Radiant

1. Open `../radiant/sic_receiver/sic_receiver.rdf` in Lattice Radiant
2. Click the green **Run** button (runs synthesis → place & route → export)
3. Bitstream output: `../radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin`

The PDC pin constraints are in `../radiant/sic_receiver/source/impl_1/sic_top.pdc`.

---

## Programming (Windows — MSYS2/openFPGALoader)

The Lattice Radiant Programmer GUI does not work reliably on Windows.
Use openFPGALoader via MSYS2 instead. See `TOOLCHAIN_SETUP.md` for setup.

**Before programming:**
1. Disconnect STM32 board (SPI lines interfere with flash programming)
2. Run Zadig — set WinUSB on Interface 0 of the FTDI device

**Program command:**
```bash
openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

If you get `ff` JEDEC ID, try adding `--cable-index 1`.

**Verify programming:**
```bash
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 readback.bin
md5sum /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
md5sum readback.bin
# Hashes must match
```

---

## Key Design Notes

### SPI MISO Pin

MISO is on **J3 pin 22A** (site 12, IOB_22A), NOT on J52 pin labeled "MISO".
J52 pin 14 (IOB_32A_SPI_SO, site 14) is the dedicated hardware SPI slave output
and does not function as a general-purpose GPIO output in Radiant synthesis.

### 2-Stage Input Synchronizers

All SPI inputs (spi_sclk, spi_cs_n, spi_mosi) pass through 2-stage flip-flop
synchronizers before use in any logic. This prevents metastability when
asynchronous SPI signals cross into the 12 MHz clk_sys domain. At 12:1
oversampling (12 MHz FPGA / 1 MHz SPI), MTBF is astronomically high.

Without these synchronizers, occasional false clock edge detections caused
random bit rotations in the received data. This was confirmed by scope
measurement and corrected.

### RGB LED Primitive

iCE40UP5K pins 39/40/41 (RGB LED) require the `RGB` primitive. Direct
`std_logic` assignment to these pins does not work — the `RGB` primitive
must be instantiated explicitly.

### Known Limitation

`polyphase_channelizer_top.vhd` currently processes only the real part of
the complex input (`sample_re`). The imaginary input (`sample_im`) is ignored
and FFT imaginary inputs are hardwired to zero. This means CH0 Q is always
zero and channels are not fully utilizing complex I/Q processing.

Complex I/Q channelizer support is the next development milestone.

---

## Open-Source Alternative (Linux/macOS)

A Yosys/nextpnr open-source toolchain is also supported via the `Makefile`
in this directory. See `TOOLCHAIN_SETUP.md` for details. The pin constraints
for the open-source flow use the `sic_top.pcf` file (nextpnr format) rather
than the Radiant `.pdc` format.
