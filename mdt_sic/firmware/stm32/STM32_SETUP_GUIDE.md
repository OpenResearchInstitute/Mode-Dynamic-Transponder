# STM32 Firmware Setup Guide

## Overview

This guide covers setting up and working with the STM32H7 firmware for the SIC receiver.
The complete STM32CubeIDE project is included in the repository at
`firmware/stm32/sic_receiver/` — you do not need to create a new project from scratch.

## What the Firmware Does

The STM32 has three jobs:

1. **Talk to the FPGA over SPI** — Send commands, receive channel I/Q data
2. **Compute magnitudes** — Convert I/Q samples to signal strength using the FPU
3. **Report results** — Print to serial terminal; eventually run the SIC algorithm

## Expected Serial Output

When everything is working, you should see:

```
=== SIC Receiver Starting ===
Waiting for FPGA...
SIC Receiver initialized
---
RAW: 00 00 AF 00 00 FF B7 FF AD 00 09 00 00 FF B7 00 52
CH0: I=   175 Q=     0  Mag=  175  (-50.0 dB) [PEAK]
CH1: I=   -73 Q=   -83  Mag=  119  (-50.0 dB)
CH2: I=     9 Q=     0  Mag=    9  (-50.0 dB)
CH3: I=   -73 Q=    82  Mag=  118  (-50.0 dB)
---
```

> Note: CH0 Q is currently always 0 — this is a known limitation of the FPGA
> channelizer (real-only processing). Complex I/Q support is the next milestone.

---

## Part 1: Opening the Project

The firmware project is already in the repository. Import it into STM32CubeIDE:

1. Open **STM32CubeIDE**
2. **File → Import → General → Existing Projects into Workspace**
3. Click **"Select root directory"** and browse to:
   `<repo>/firmware/stm32/sic_receiver/`
4. Make sure **"Copy projects into workspace"** is **unchecked**
   (you want to work directly in the repository)
5. The project `sic_receiver` should appear with a checkmark
6. Click **Finish**

> If you see "Some projects cannot be imported because they already exist",
> right-click the old project in Project Explorer → Delete (do NOT check
> "Delete project contents on disk"), then try Import again.

---

## Part 2: Building and Flashing

### Build
- **Project → Clean**, then **Project → Build**
- Watch the Console for errors
- Output: `firmware/stm32/sic_receiver/Debug/sic_receiver.elf`

### Flash
- Connect Nucleo USB (CN1 ST-Link connector)
- **Run → Run** (or click the green play button)
- First time: select "STM32 Cortex-M C/C++ Application", click OK
- Wait for "File download complete" in the Console

### Serial Terminal
Connect to the ST-Link virtual COM port at **115200 baud, 8N1**.

On Windows: use PuTTY (Serial mode, find COM port in Device Manager)
On Linux/macOS: `screen /dev/ttyACM0 115200`

---

## Part 3: Key Configuration (Already Set)

The project is pre-configured. These settings are documented for reference.

### SPI4 (spi.c)

| Parameter | Value | Notes |
|-----------|-------|-------|
| Mode | Full-Duplex Master | |
| Data Size | 8 bits | |
| CPOL | Low | Clock idles low (Mode 0) |
| CPHA | 1 Edge | Sample on rising edge (Mode 0) |
| Prescaler | 64 | ~1 MHz SPI clock |
| NSS | Software | CS controlled manually via PE11 |
| NSS Pulse | Disabled | No pulse between bytes |

### GPIO (gpio.c)

| Pin | Function | Mode | Pull | Notes |
|-----|----------|------|------|-------|
| PE11 | FPGA_CS_N | Output | None | Active low, idle high |
| PE12 | SPI4_SCK | AF5 | None | |
| PE13 | SPI4_MISO | AF5 | None | Connected to J3 22A on iCE40 |
| PE14 | SPI4_MOSI | AF5 | None | |
| PD0 | FPGA_RST_N | Output | None | Active low reset to FPGA |
| PD1 | FPGA_DONE | Input | Pull-down | High when channelizer ready |

> PD0 and PD1 are on **CN11** on the Nucleo board, not CN10.

### USART3 (115200 baud)
Connected to ST-Link virtual COM port via PD8 (TX) and PD9 (RX).

---

## Part 4: Project Structure

```
firmware/stm32/sic_receiver/
├── sic_receiver.ioc          ← CubeMX config — open this to modify peripherals
├── Core/
│   ├── Inc/
│   │   ├── main.h
│   │   ├── sic_fpga.h        ← SIC driver header (commands, data structures)
│   │   ├── spi.h
│   │   ├── gpio.h
│   │   └── usart.h
│   └── Src/
│       ├── main.c            ← Main loop, initialization, printf redirect
│       ├── sic_fpga.c        ← SIC driver (SPI protocol, magnitude, display)
│       ├── spi.c             ← SPI4 HAL configuration
│       ├── gpio.c            ← GPIO configuration
│       └── usart.c           ← USART3 configuration
├── Drivers/                  ← STM32H7 HAL + CMSIS (included for self-contained build)
└── .gitignore                ← Excludes Debug/, Release/, *.o etc.
```

### Key User Files

**`sic_fpga.h` / `sic_fpga.c`** — The SIC driver. Handles:
- SPI transactions (17 bytes: 1 command + 16 IQ data bytes)
- Magnitude computation (alpha-beta approximation, FPU sqrt, CORDIC)
- Channel data formatting and display

**`main.c`** — Initializes the driver, then polls for channel data:
```c
while (1) {
    if (sic_read_channels(&sic_drv, &channel_data, SIC_MAG_ALPHA_BETA) == 0) {
        for (int ch = 0; ch < 4; ch++) {
            printf("CH%d: I=%6d Q=%6d  Mag=%5u  (%d.%d dB)%s\r\n", ...);
        }
    }
    HAL_Delay(500);
}
```

---

## Part 5: Modifying Peripheral Configuration

If you need to change SPI speed, GPIO pins, or other peripheral settings:

1. Double-click `sic_receiver.ioc` to open STM32CubeMX
2. Make your changes in the graphical configurator
3. **Project → Generate Code** to regenerate HAL files
4. Your code in `/* USER CODE BEGIN */` / `/* USER CODE END */` blocks is preserved

> Always put custom code inside USER CODE blocks to survive code regeneration.

---

## Part 6: SPI Protocol Reference

### Transaction Structure (17 bytes)

```
STM32 TX: [CMD]  [0x00] [0x00] [0x00] ... (16 more bytes)
FPGA  RX: [0x00] [I0_H] [I0_L] [Q0_H] [Q0_L] [I1_H] [I1_L] [Q1_H] [Q1_L]
                 [I2_H] [I2_L] [Q2_H] [Q2_L] [I3_H] [I3_L] [Q3_H] [Q3_L]
```

### Commands

| Command | Value | Response |
|---------|-------|----------|
| READ_IQ | 0x01 | 16 bytes: 4 channels × (I_high, I_low, Q_high, Q_low) |
| READ_STATUS | 0x02 | 1 byte: bit0=chan_ready, bit1=iq_valid |

### Magnitude Methods

| Method | Function | Notes |
|--------|----------|-------|
| `SIC_MAG_ALPHA_BETA` | `max + min/2` | Fast, ~3% error |
| `SIC_MAG_SQRT` | `sqrtf(I²+Q²)` | Exact, uses FPU |
| `SIC_MAG_CORDIC` | CORDIC coprocessor | Placeholder, falls back to sqrt |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "SPI read error: 3" | FPGA not connected or not programmed | Check wiring, reprogram FPGA |
| "FPGA not responding" | PD1 (DONE) not connected or low | Check J3 29B to PD1 wire |
| All zeros | MISO not connected | Check MISO wire on J3 22A |
| Firmware crash (rapid red blink) | HAL_SPI_Init fails | Check DataSize=8BIT in spi.c |
| Garbage serial output | Wrong baud rate | Use 115200 baud |
| "Already exists in workspace" | Old project path cached | Delete old project, re-import |
| Q always zero for CH0 | Known limitation | Complex channelizer not yet implemented |

---

## Next Steps

Once basic communication is verified:

1. **Complex I/Q channelizer** — Update FPGA to process both sample_re and sample_im
2. **Real I2S ADC** — Replace FPGA test pattern with TLV320ADC6120 input
3. **SIC algorithm** — Implement peak detection, signal reconstruction, subtraction
4. **Performance optimization** — Profile SPI throughput, tune update rate
