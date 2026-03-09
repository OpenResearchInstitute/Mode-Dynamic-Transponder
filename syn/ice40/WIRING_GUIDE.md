# SIC Receiver Prototype Wiring Guide

## Hardware Required

| Item | Part Number | Approx Cost |
|------|-------------|-------------|
| FPGA Board | Lattice iCE40UP5K-B-EVN | ~$50 |
| MCU Board | NUCLEO-H7B3ZI-Q | ~$70 |
| Jumper wires | Female-Female Dupont | ~$5 |
| USB cables | 2× Micro-USB | ~$5 |

**Total: ~$130**

## Pin Connections

### SPI Interface (Primary Data Path)

| Signal | STM32 Pin | STM32 Function | iCE40 EVN Pin | iCE40 Ball |
|--------|-----------|----------------|---------------|------------|
| SCLK | PE12 | SPI4_SCK | J52.15 | 15 |
| MISO | PE13 | SPI4_MISO | J52.14 | 14 |
| MOSI | PE14 | SPI4_MOSI | J52.17 | 17 |
| CS_N | PE11 | SPI4_NSS / GPIO | J52.16 | 16 |

### Control Signals

| Signal | STM32 Pin | Direction | iCE40 EVN Pin | iCE40 Ball |
|--------|-----------|-----------|---------------|------------|
| FPGA_RST_N | PD0 (or free GPIO) | STM32 to FPGA | J52.18 | 18 |
| FPGA_DONE | PD1 (or free GPIO) | FPGA to STM32 | J52.19 | 19 |

### Ground (CRITICAL)

| Connection | Notes |
|------------|-------|
| STM32 GND | Connect to iCE40 EVN GND |
| Use at least 2 ground wires | Signal integrity |

### Power

Both boards are powered independently via their USB connectors. Do NOT connect 3.3V between boards unless you know what you're doing.

## Physical Wiring Diagram

```
  NUCLEO-H7B3ZI-Q                    iCE40UP5K-B-EVN
  ================                    ===============
  
  CN10 (Morpho Left)                 J52 (PMOD/GPIO)
  ┌─────────────────┐                ┌─────────────────┐
  │                 │                │                 │
  │  PE11 (SPI4_NSS)├───────────────►│ Pin 16 (CS_N)   │
  │  PE12 (SPI4_SCK)├───────────────►│ Pin 15 (SCLK)   │
  │  PE13 (SPI4_MISO)◄───────────────┤ Pin 14 (MISO)   │
  │  PE14 (SPI4_MOSI)├──────────────►│ Pin 17 (MOSI)   │
  │                 │                │                 │
  │  PD0 (GPIO)     ├───────────────►│ Pin 18 (RST_N)  │
  │  PD1 (GPIO)     ◄────────────────┤ Pin 19 (DONE)   │
  │                 │                │                 │
  │  GND            ├───────────────►│ GND             │
  │  GND            ├───────────────►│ GND             │
  │                 │                │                 │
  └─────────────────┘                └─────────────────┘
```

## STM32CubeMX Configuration

### SPI4 Settings

1. Open STM32CubeMX or STM32CubeIDE
2. Enable SPI4 in **Full-Duplex Master** mode
3. Configure:
   - Prescaler: Adjust for ~10 MHz (APB2 / prescaler)
   - CPOL: Low (idle low)
   - CPHA: 1 Edge (sample on rising edge)
   - Data Size: 8 Bits
   - MSB First
   - NSS: Software (we control CS via GPIO)

### GPIO Settings

| Pin | Mode | Pull | Speed | Label |
|-----|------|------|-------|-------|
| PE11 | GPIO_Output | None | High | FPGA_CS_N |
| PD0 | GPIO_Output | None | Low | FPGA_RST_N |
| PD1 | GPIO_Input | Pull-Up | - | FPGA_DONE |

### Clock Configuration

- Use HSE with the Nucleo's 8 MHz crystal
- Configure PLL for 280 MHz system clock (or as needed)
- SPI4 is on APB2; ensure reasonable clock divider

## iCE40 EVN Board Notes

1. **J52 Header**: This is the main GPIO/PMOD header. Pin numbering matches ball numbers in the PCF file.

2. **Power**: The EVN board runs at 3.3V I/O by default, which matches STM32H7.

3. **12 MHz Clock**: The EVN has a 12 MHz oscillator. Our design uses this directly (no PLL for initial testing).

4. **RGB LED**: Used for status indication (might work, might not work, let's try it)
   - Red: Heartbeat (0.7 Hz blink)
   - Green: Channelizer ready
   - Blue: Data valid pulses

## Testing Procedure

### Step 1: Program the FPGA

```bash
cd syn/ice40
make prog
```

### Step 2: Program the STM32

1. Open the project in STM32CubeIDE
2. Build and flash to the Nucleo board
3. Connect a serial terminal to the ST-Link VCP (115200 baud)

### Step 3: Verify Communication

1. Press reset on STM32
2. Should see "SIC Init OK" on terminal
3. RGB LED on iCE40 should show:
   - Red blinking (heartbeat)
   - Green on (ready)

### Step 4: View Spectrum Data

The STM32 will print channel magnitudes over the serial port!

```
CH[0]=12345 CH[1]=  234 CH[2]=  567 CH[3]=  890  Peak=CH0 (-12.3 dB)
```

## Troubleshooting (anticipated and encountered)

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| No LED activity on iCE40 | Not programmed | Run `make prog` |
| "FPGA not ready" on STM32 | RST_N stuck low | Check wiring |
| All zeros from SPI | CS not toggling | Verify PE11 config |
| Garbage data | Clock/phase mismatch | Check SPI settings |
| Intermittent errors | Ground bounce | Add more GND wires |

## Next Steps

Once basic SPI communication is verified:

1. **Add I2S input**: Connect an I2S ADC or use the test pattern generator
2. **Real RF testing**: Feed actual RF through SDR dongle to I2S to FPGA
3. **Port to Martin's PCB**: Once validated, build the proper hardware

## References

- [iCE40UP5K-B-EVN User Guide](https://www.latticesemi.com/products/developmentboardsandkits/ice40ultraplusbreakoutboard)
- [NUCLEO-H7B3ZI User Manual](https://www.st.com/resource/en/user_manual/um2616-stm32h7b3zi-nucleo144-board-stmicroelectronics.pdf)
- [Martin Ling's dynamic-transponder schematic](https://github.com/martinling/dynamic-transponder)
