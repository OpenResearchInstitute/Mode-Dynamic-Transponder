# STM32 Firmware Setup Guide

## Overview

This guide walks you through setting up the STM32H7 firmware for the SIC receiver. By the end, you'll have a working system that reads channel data from the FPGA and displays it over serial.

## What We're Building

The STM32 has three jobs:

1. **Talk to the FPGA over SPI** — Send commands, receive channel data
2. **Compute magnitudes** — Convert I/Q samples to signal strength
3. **Report results** — Print to serial terminal for debugging (later: run SIC algorithm)

## How to Tell It's Working

| What You See | What It Means |
|--------------|---------------|
| iCE40 red LED blinking (~1 Hz) | FPGA is running |
| iCE40 green LED solid on | Channelizer is ready |
| Serial terminal shows channel data | SPI communication working |
| Numbers change | Signal processing is live |

Example serial output when working:
```
SIC FPGA initialized
SIC Channels @ 1234 ms:
  CH0: I=  1234 Q=     0  Mag= 1234 (-12.3 dB) [PEAK]
  CH1: I=   567 Q=     0  Mag=  567 (-18.7 dB)
  CH2: I=   890 Q=     0  Mag=  890 (-15.2 dB)
  CH3: I=   123 Q=     0  Mag=  123 (-24.1 dB)
```

---

## Part 1: Install STM32CubeIDE

### Download

1. Go to: https://www.st.com/en/development-tools/stm32cubeide.html
2. Click "Get Software" 
3. Select your OS (macOS, Windows, or Linux)
4. You'll need to create a free ST account or login
5. Download and install

### First Launch

1. Open STM32CubeIDE
2. Choose a workspace location (e.g., `~/STM32Projects`)
3. Let it initialize (downloads some packages on first run)

---

## Part 2: Create a New Project

### Start the Project

1. **File → New → STM32 Project**
2. Wait for the board database to load

### Select Your Board

1. Click the **"Board Selector"** tab (not "MCU/MPU Selector")
2. In the search box, type: `NUCLEO-H7B3ZI`
3. Select **NUCLEO-H7B3ZI-Q** from the list
4. Click **Next**

### Name Your Project

1. Project name: `sic_receiver`
2. Leave other options as default
3. Click **Finish**
4. When asked "Initialize all peripherals with their default Mode?", click **Yes**
5. When asked to open the Device Configuration Tool perspective, click **Yes**

You should now see a graphical view of the chip with pins.

---

## Part 3: Configure Peripherals

### 3.1 Configure SPI4 (FPGA Communication)

1. In the **Pinout & Configuration** tab, expand **Connectivity** in the left panel
2. Click **SPI4**
3. Set Mode to: **Full-Duplex Master**
4. In the Configuration panel below:
   - Frame Format: **Motorola**
   - Data Size: **8 Bits**
   - First Bit: **MSB First**
   - Prescaler: adjust to get ~10 MHz (check the calculated Baud Rate)
   - CPOL: **Low**
   - CPHA: **1 Edge**
   - NSS: **Disable** (we'll control CS manually via GPIO)

### 3.2 Verify SPI4 Pins

The default pins should be on Port E:
- **PE12** = SPI4_SCK
- **PE13** = SPI4_MISO
- **PE14** = SPI4_MOSI

If not assigned, click on each pin in the chip view and assign the function.

### 3.3 Configure GPIO for Chip Select (PE11)

1. Click on pin **PE11** in the chip diagram
2. Select **GPIO_Output**
3. In the left panel, expand **System Core → GPIO**
4. Click on **PE11** in the pin list
5. Configure:
   - GPIO output level: **High** (CS is active low, so start deselected)
   - GPIO mode: **Output Push Pull**
   - GPIO Pull-up/Pull-down: **No pull-up and no pull-down**
   - Maximum output speed: **High**
   - User Label: `FPGA_CS`

### 3.4 Configure GPIO for FPGA Reset (PD0)

1. Click on pin **PD0** in the chip diagram
2. Select **GPIO_Output**
3. Configure in GPIO panel:
   - GPIO output level: **High** (not in reset)
   - GPIO mode: **Output Push Pull**
   - Maximum output speed: **Low**
   - User Label: `FPGA_RST`

### 3.5 Configure GPIO for FPGA Done (PD1)

1. Click on pin **PD1** in the chip diagram
2. Select **GPIO_Input**
3. Configure in GPIO panel:
   - GPIO mode: **Input mode**
   - GPIO Pull-up/Pull-down: **Pull-up**
   - User Label: `FPGA_DONE`

### 3.6 Enable UART for printf (Serial Output)

The Nucleo board has a built-in ST-Link that provides a virtual COM port. We'll use USART3 which is connected to it.

1. Expand **Connectivity** in the left panel
2. Click **USART3**
3. Set Mode to: **Asynchronous**
4. Configuration:
   - Baud Rate: **115200**
   - Word Length: **8 Bits**
   - Stop Bits: **1**
   - Parity: **None**

The pins should auto-assign to PD8 (TX) and PD9 (RX).

### 3.7 Save and Generate Code

1. **File → Save** (or Ctrl+S / Cmd+S)
2. When asked "Do you want to generate Code?", click **Yes**
3. Wait for code generation to complete

---

## Part 4: Add the SIC Driver Files

### 4.1 Copy Driver Files

1. In the Project Explorer (left panel), expand your project
2. Find the **Core/Src** folder
3. Copy `sic_fpga.c` into **Core/Src**
4. Find the **Core/Inc** folder
5. Copy `sic_fpga.h` into **Core/Inc**

You can do this by:
- Dragging files from Finder into the Project Explorer
- Or right-click folder → Import → File System

### 4.2 Verify Files Appear

Your project structure should now include:
```
sic_receiver/
├── Core/
│   ├── Inc/
│   │   ├── main.h
│   │   ├── sic_fpga.h      ← Our driver header
│   │   └── ...
│   └── Src/
│       ├── main.c
│       ├── sic_fpga.c      ← Our driver implementation
│       └── ...
└── ...
```

---

## Part 5: Enable printf Over Serial

By default, printf doesn't work on STM32. We need to redirect it to UART.

### 5.1 Open main.c

In Project Explorer, open **Core/Src/main.c**

### 5.2 Add Include at Top

Find the `/* USER CODE BEGIN Includes */` section (around line 20-25) and add:

```c
/* USER CODE BEGIN Includes */
#include "sic_fpga.h"
#include <stdio.h>
/* USER CODE END Includes */
```

### 5.3 Add Printf Redirect

Find `/* USER CODE BEGIN 0 */` section and add:

```c
/* USER CODE BEGIN 0 */

/* Redirect printf to UART3 */
int _write(int file, char *ptr, int len)
{
    HAL_UART_Transmit(&huart3, (uint8_t*)ptr, len, HAL_MAX_DELAY);
    return len;
}

/* SIC driver instance */
static sic_driver_t sic_drv;

/* USER CODE END 0 */
```

### 5.4 Add Initialization Code

Find the `/* USER CODE BEGIN 2 */` section (after all the MX_xxx_Init() calls) and add:

```c
  /* USER CODE BEGIN 2 */

  printf("\r\n\r\n=== SIC Receiver Starting ===\r\n");

  /* Initialize the FPGA driver */
  sic_error_t err = sic_init(&sic_drv, &hspi4,
                              GPIOE_BASE, GPIO_PIN_11,   /* CS: PE11 */
                              GPIOD_BASE, GPIO_PIN_0,    /* RST: PD0 */
                              GPIOD_BASE, GPIO_PIN_1);   /* DONE: PD1 */

  if (err != SIC_OK) {
      printf("ERROR: sic_init failed (%d)\r\n", err);
      Error_Handler();
  }

  /* Check if FPGA is ready */
  if (!sic_is_ready(&sic_drv)) {
      printf("Waiting for FPGA...\r\n");
      
      /* Try resetting the FPGA */
      err = sic_reset(&sic_drv, 2000);
      if (err != SIC_OK) {
          printf("ERROR: FPGA not responding (check wiring and FPGA programming)\r\n");
          /* Continue anyway for debugging */
      }
  }

  if (sic_is_ready(&sic_drv)) {
      printf("FPGA ready!\r\n");
  }

  printf("SIC Receiver initialized\r\n\r\n");

  /* USER CODE END 2 */
```

### 5.5 Add Main Loop Code

Find the `/* USER CODE BEGIN 3 */` section inside the `while(1)` loop and add:

```c
    /* USER CODE BEGIN 3 */
    
    sic_channel_data_t ch_data;
    
    /* Read channels with fast magnitude approximation */
    err = sic_read_channels(&sic_drv, &ch_data, SIC_MAG_ALPHA_BETA);
    
    if (err == SIC_OK) {
        /* Print channel data */
        sic_print_channels(&ch_data);
        
        /* Simple threshold detection example */
        if (ch_data.mag[ch_data.peak_ch] > 1000) {
            printf(">>> Signal detected on CH%d! <<<\r\n\r\n", ch_data.peak_ch);
        }
    } else {
        printf("SPI read error: %d\r\n", err);
    }
    
    /* Update rate: 10 Hz */
    HAL_Delay(100);
    
  }
  /* USER CODE END 3 */
```

**Important:** Make sure this code is INSIDE the `while(1) { }` loop, before the closing brace.

---

## Part 6: Build the Project

### 6.1 Build

1. **Project → Build Project** (or Ctrl+B / Cmd+B)
2. Watch the Console panel at the bottom for errors
3. First build takes a while (compiling HAL libraries)

### 6.2 Fix Any Errors

Common issues:

**"undefined reference to sic_xxx"**
- Make sure `sic_fpga.c` is in `Core/Src/`
- Make sure it's included in the build (right-click file → Properties → check "Exclude from build" is NOT checked)

**"hspi4 undeclared"**
- Make sure SPI4 is enabled in the .ioc file and code was regenerated

**"huart3 undeclared"** 
- Make sure USART3 is enabled in the .ioc file and code was regenerated

### 6.3 Successful Build

You should see:
```
Finished building: sic_receiver.elf
```

---

## Part 7: Flash and Run

### 7.1 Connect the Nucleo Board

1. Plug the Nucleo board into your Mac via USB (use the ST-Link USB port, not the user USB)
2. You should see a new drive appear called "NODE_H7B3ZI" or similar

### 7.2 Flash the Firmware

1. **Run → Run** (or click the green Play button)
2. First time: select "STM32 Cortex-M C/C++ Application"
3. Click OK to accept defaults
4. Wait for programming to complete

You should see in Console:
```
Download verified successfully
```

### 7.3 Open Serial Terminal

**On Mac:**

1. Open Terminal
2. Find the serial port:
   ```bash
   ls /dev/cu.usbmodem*
   ```
3. Connect with screen:
   ```bash
   screen /dev/cu.usbmodem14203 115200
   ```
   (Replace `14203` with your actual number)

**Or use a GUI terminal:**
- CoolTerm (free): https://freeware.the-meiers.org/
- Serial (Mac App Store)

### 7.4 See Output

Press the black RESET button on the Nucleo board. You should see:

```
=== SIC Receiver Starting ===
Waiting for FPGA...
ERROR: FPGA not responding (check wiring and FPGA programming)
SIC Receiver initialized

SPI read error: 3
SPI read error: 3
...
```

**This is expected if the FPGA isn't connected yet!**

---

## Part 8: Connect the FPGA

### 8.1 Wire It Up

Follow `syn/ice40/WIRING_GUIDE.md`:

| STM32 Pin | Signal | iCE40 EVN Pin |
|-----------|--------|---------------|
| PE11 | CS | 16 |
| PE12 | SCK | 15 |
| PE13 | MISO | 14 |
| PE14 | MOSI | 17 |
| PD0 | RST | 18 |
| PD1 | DONE | 19 |
| GND | GND | GND |
| GND | GND | GND (use 2 wires) |

### 8.2 Program the FPGA

```bash
cd ~/Mode-Dynamic-Transponder/syn/ice40
make prog
```

### 8.3 Power Cycle and Test

1. Unplug both USB cables
2. Plug in FPGA board first
3. Plug in Nucleo board
4. Open serial terminal
5. Press RESET on Nucleo

You should now see:

```
=== SIC Receiver Starting ===
FPGA ready!
SIC Receiver initialized

SIC Channels @ 100 ms:
  CH0: I=  1234 Q=     0  Mag= 1234 (-12.3 dB) [PEAK]
  CH1: I=   567 Q=     0  Mag=  567 (-18.7 dB)
  CH2: I=   890 Q=     0  Mag=  890 (-15.2 dB)
  CH3: I=   123 Q=     0  Mag=  123 (-24.1 dB)
```

---

## Troubleshooting (from forums and lessons learned in Remote Lab)

### "FPGA not responding"

1. Check wiring — especially GND connections
2. Is the FPGA programmed? Red LED should be blinking
3. Check that RST and DONE wires aren't swapped

### "SPI read error: 2" (SIC_ERR_SPI_FAIL)

1. Check SPI wiring (SCK, MISO, MOSI, CS)
2. Verify SPI4 is configured correctly in STM32CubeIDE
3. Try slower SPI clock (increase prescaler)

### All channels read zero?

1. FPGA might not be generating test pattern — check `sic_top_ice40.vhd`
2. Verify SPI clock polarity/phase match FPGA expectations

### Serial terminal shows garbage?

1. Check baud rate is 115200
2. Make sure you're connected to the right port!
3. Reset the Nucleo board after connecting terminal

### Build fails with many errors

1. Make sure you saved the .ioc file and regenerated code
2. Right-click project → Refresh
3. Clean and rebuild: Project → Clean, then Build

---

## Next Steps

Once basic communication is working:

1. **Add real I2S input** — Replace test pattern generator in FPGA
2. **Implement full I/Q protocol** — Update FPGA to send both I and Q components  
3. **Add SIC algorithm** — Use peak detection to identify and cancel strong signals
4. **Log to SD card** — For field testing without laptop

---

## Quick Reference

### Pin Assignments

| Function | STM32 Pin | GPIO | Direction |
|----------|-----------|------|-----------|
| SPI4_SCK | PE12 | - | Output |
| SPI4_MISO | PE13 | - | Input |
| SPI4_MOSI | PE14 | - | Output |
| FPGA_CS | PE11 | GPIOE.11 | Output |
| FPGA_RST | PD0 | GPIOD.0 | Output |
| FPGA_DONE | PD1 | GPIOD.1 | Input |
| USART3_TX | PD8 | - | Output |
| USART3_RX | PD9 | - | Input |

### SPI Settings

| Parameter | Value |
|-----------|-------|
| Mode | Full-Duplex Master |
| Data Size | 8 bits |
| First Bit | MSB |
| CPOL | Low |
| CPHA | 1 Edge |
| Baud Rate | ~10 MHz |

### Serial Settings

| Parameter | Value |
|-----------|-------|
| Baud Rate | 115200 |
| Data Bits | 8 |
| Stop Bits | 1 |
| Parity | None |
| Flow Control | None |
