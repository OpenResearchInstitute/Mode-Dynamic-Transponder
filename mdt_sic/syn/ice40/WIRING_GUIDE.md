# SIC Receiver Prototype Wiring Guide

## Hardware Required

| Item | Part Number | Approx Cost |
|------|-------------|-------------|
| FPGA Board | Lattice iCE40UP5K-B-EVN | ~$50 |
| MCU Board | NUCLEO-H753ZI | ~$70 |
| Jumper wires | Female-Female Dupont | ~$5 |
| USB cables | 2× Micro-USB | ~$5 |

**Total: ~$130**

---

## Critical Notes Before You Start

### FPGA Programming
- The Zadig WinUSB driver for the iCE40 FTDI interface **reverts to FTDI on every USB reconnect** on Windows.
- **Always run Zadig and verify WinUSB is set before programming the FPGA.**
- Successful programming shows the Micron N25Q32 flash chip identified and a progress bar:
  ```
  JEDEC ID: 0x20ba16
  Detected: micron N25Q32 64 sectors size: 32Mb
  Erasing: [==================================================] 100.00%
  Writing: [==================================================] 100.00%
  Done
  Wait for CDONE DONE
  ```
- If you see `Jedec ID: ff` with no progress bar, the driver has reverted. Run Zadig again.

### STM32 Must Be Disconnected When Programming FPGA
- The SPI lines between the STM32 and FPGA boards share signals with the FPGA's flash programming interface.
- **Disconnect the STM32 board (unplug USB) before running openFPGALoader.**
- Reconnect after programming is complete.

### Verify Programming with MD5
After programming, verify the flash contents match the bitstream:
```bash
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 readback.bin
md5sum sic_receiver_impl_1.bin
md5sum readback.bin
# Both hashes must match
```

---

## Pin Connections

### SPI Interface (Primary Data Path)

> ⚠️ **IMPORTANT:** MISO is NOT on J52. It is on **J3, pin labeled 22A**.
> J52 pin 14 (labeled MISO) is the dedicated hardware SPI_SO pin and does not
> function as a general-purpose GPIO output in our design.

| Signal | STM32 Pin | STM32 Connector | iCE40 EVN Location | iCE40 Ball/Site |
|--------|-----------|-----------------|-------------------|-----------------|
| SCLK   | PE12      | CN12 pin 38     | J52, labeled SCK  | Site 15         |
| **MISO** | **PE13** | **CN12 pin 40** | **J3, labeled 22A** | **Site 12**   |
| MOSI   | PE14      | CN12 pin 42     | J52, labeled MOSI | Site 17         |
| CS_N   | PE11      | CN12 pin 36     | J52, labeled SS   | Site 16         |

### Control Signals

| Signal | STM32 Pin | STM32 Connector | iCE40 EVN Location | iCE40 Ball/Site |
|--------|-----------|-----------------|-------------------|-----------------|
| FPGA_RST_N | PD0  | CN11 (labeled PD0) | J3, labeled 18A | Site 18     |
| FPGA_DONE  | PD1  | CN11 (labeled PD1) | J3, labeled 29B | Site 19     |

### Ground (CRITICAL)

| Connection | Notes |
|------------|-------|
| STM32 GND  | Connect to iCE40 EVN GND |
| Use at least 2 ground wires | Signal integrity |

### Power

Both boards are powered independently via their USB connectors. Do NOT connect 3.3V between boards.

---

## Physical Wiring Diagram

```
  NUCLEO-H753ZI                      iCE40UP5K-B-EVN
  =============                      ===============

  CN12 (Morpho Right)
  ┌─────────────────┐                J52 Header
  │                 │                ┌─────────────────┐
  │  PE11 (CS_N)    ├───────────────►│ SS  (site 16)   │
  │  PE12 (SCK)     ├───────────────►│ SCK (site 15)   │
  │  PE14 (MOSI)    ├───────────────►│ MOSI(site 17)   │
  │                 │                └─────────────────┘
  └─────────────────┘
                                      J3 Header
  CN12 (Morpho Right)                ┌─────────────────┐
  ┌─────────────────┐                │                 │
  │  PE13 (MISO)    ◄────────────────┤ 22A (site 12)   │◄── MISO HERE
  └─────────────────┘                │                 │
                                     └─────────────────┘
  CN11
  ┌─────────────────┐                J3 Header
  │  PD0 (RST_N)    ├───────────────►│ 18A (site 18)   │
  │  PD1 (DONE)     ◄────────────────┤ 29B (site 19)   │
  │  GND            ├───────────────►│ GND             │
  │  GND            ├───────────────►│ GND             │
  └─────────────────┘                └─────────────────┘
```

---

## FPGA Programming Command

```bash
# Always run Zadig first to set WinUSB on Interface 0 of the FTDI device
# Then, with STM32 board DISCONNECTED:

openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

---

## STM32CubeMX / spi.c Configuration

### SPI4 Settings (in spi.c)

```c
hspi4.Init.Mode = SPI_MODE_MASTER;
hspi4.Init.Direction = SPI_DIRECTION_2LINES;
hspi4.Init.DataSize = SPI_DATASIZE_8BIT;
hspi4.Init.CLKPolarity = SPI_POLARITY_LOW;       // CPOL=0, idle low
hspi4.Init.CLKPhase = SPI_PHASE_1EDGE;            // CPHA=0, sample on rising
hspi4.Init.NSS = SPI_NSS_SOFT;
hspi4.Init.BaudRatePrescaler = SPI_BAUDRATEPRESCALER_64;  // ~1 MHz (safe for FPGA 12 MHz)
hspi4.Init.NSSPMode = SPI_NSS_PULSE_DISABLE;     // No CS pulse between bytes
```

### GPIO Settings (in gpio.c)

| Pin | Mode | Pull | Label |
|-----|------|------|-------|
| PE11 | GPIO_Output | NOPULL | FPGA_CS_N |
| PD0  | GPIO_Output | NOPULL | FPGA_RST_N |
| PD1  | GPIO_Input  | PULLDOWN | FPGA_DONE |

> Note: PD0 and PD1 are on **CN11**, not CN10 as originally documented.
> They are labeled PD0 and PD1 on the Nucleo silkscreen.

### SPI4 GPIO Alternate Function (in spi.c HAL_SPI_MspInit)

```c
// PE12 = SPI4_SCK, PE13 = SPI4_MISO, PE14 = SPI4_MOSI
// Alternate function: GPIO_AF5_SPI4
GPIO_InitStruct.Pin = GPIO_PIN_12|GPIO_PIN_13|GPIO_PIN_14;
GPIO_InitStruct.Alternate = GPIO_AF5_SPI4;
```

---

## iCE40 EVN Board Notes

1. **J52 Header**: Carries SS, SCK, MOSI signals. Pin labeled MISO on J52 is the
   dedicated hardware SPI slave output (IOB_32A_SPI_SO, site 14) and does NOT
   work as a regular GPIO output in Radiant synthesis. Use J3 pin 22A instead.

2. **J3 Header**: Bank 0 GPIO header. Contains MISO (22A, site 12), RST (18A, site 18),
   and DONE (29B, site 19).

3. **J6 Jumpers**: Must be in **horizontal** position for flash boot. This is the
   default for normal operation.

4. **Power**: The EVN board runs at 3.3V I/O.

5. **12 MHz Clock**: Connected via J51 jumper (must be installed).

6. **RGB LED Status**:
   - Red (slow blink ~0.7 Hz): Heartbeat, FPGA running
   - Green (steady): `chan_ready` high, channelizer running
   - Blue: `iq_valid` signal

---

## Power-Up Sequence

1. Unplug both boards
2. Plug in iCE40 board first
3. Verify RGB LED shows green/blue (channelizer running)
4. Plug in Nucleo board
5. Open serial terminal at 115200 baud
6. Press RESET on Nucleo

Expected serial output:
```
=== SIC Receiver Starting ===
Waiting for FPGA...
SIC Receiver initialized
RAW: xx xx xx xx ...
CH0: I= XXXX Q= XXXX  Mag= XXXX  (-XX.X dB)
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| openFPGALoader shows `ff` JEDEC ID | Zadig driver reverted to FTDI | Run Zadig, set WinUSB on Interface 0 |
| openFPGALoader shows `ff` with WinUSB set | STM32 board is connected | Disconnect STM32 before programming FPGA |
| "FPGA not responding" | PD1 not connected or FPGA not programmed | Check J3 29B wire and FPGA programming |
| All zeros from SPI | MISO wire on wrong pin | Move MISO wire to J3 pin 22A |
| `0x0F` repeating | MISO floating high (pullup), not driven | Check MISO wire connection |
| 1-bit offset in data (`0x4B` instead of `0xA5`) | SPI clock phase alignment issue | Under investigation |
| Three red blinks on Nucleo | ST-LINK low power mode warning | Normal behavior, ignore |
| Firmware crashes (rapid red blink) | HAL_SPI_Init fails | Check DataSize = 8BIT in spi.c |

---

## Known Issues / Under Investigation

- **1-bit SPI alignment**: Received bytes appear to be `0xA5` shifted right by 1
  (`0x4B`). The STM32 appears to miss the first MISO bit. Root cause not yet
  confirmed — scope investigation of MISO behavior at CS falling edge is needed.
  Workaround: none yet; real channelizer data still flows but byte values are shifted.

---

## References

- [iCE40UP5K-B-EVN User Guide](https://www.latticesemi.com/products/developmentboardsandkits/ice40ultraplusbreakoutboard)
- [NUCLEO-H753ZI User Manual](https://www.st.com/resource/en/user_manual/um2616-stm32h7b3zi-nucleo144-board-stmicroelectronics.pdf)
- [Martin Ling's dynamic-transponder schematic](https://github.com/martinling/dynamic-transponder)
- [openFPGALoader](https://trabucayre.github.io/openFPGALoader/)
- [Zadig USB driver tool](https://zadig.akeo.ie/)
