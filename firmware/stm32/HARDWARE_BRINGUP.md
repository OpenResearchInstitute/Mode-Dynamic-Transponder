# Hardware Bringup Checklist

Step-by-step checklist for bringing up the SIC receiver prototype hardware.

## Required Hardware

- [ ] Lattice iCE40UP5K-B-EVN evaluation board (~$50)
- [ ] STM32 NUCLEO-H7B3ZI-Q board (~$70)
- [ ] 6× female-female jumper wires
- [ ] 2× USB cables (one for each board)
- [ ] Serial terminal software (screen, CoolTerm, etc.)

## Phase 1: FPGA Board Only

**Goal:** Verify FPGA board works and can be programmed.

### 1.1 Initial Power-Up
- [ ] Connect USB to iCE40 board (J6 USB connector)
- [ ] Verify power LED illuminates
- [ ] Board should enumerate as USB device

### 1.2 Program the FPGA
```bash
cd Mode-Dynamic-Transponder/syn/ice40
make prog
```
- [ ] Programming completes without error
- [ ] Red LED starts blinking (~1 Hz heartbeat)
- [ ] Green LED turns on (channelizer ready)

### 1.3 Verify Build Report
```bash
make report
```
- [ ] LUT usage ~87%
- [ ] Timing shows ✓ PASS

**Phase 1 Pass Criteria:** Red LED blinking, green LED solid on.

---

## Phase 2: STM32 Board Only

**Goal:** Verify STM32 board works and serial output functions.

### 2.1 Initial Power-Up
- [ ] Connect USB to Nucleo board (CN1 ST-Link connector)
- [ ] Board power LED illuminates
- [ ] ST-Link LED blinks then goes solid

### 2.2 Find Serial Port
```bash
ls /dev/cu.usbmodem*
```
- [ ] Serial port appears (e.g., `/dev/cu.usbmodem14203`)

### 2.3 Create and Flash Test Project

Follow `firmware/stm32/STM32_SETUP_GUIDE.md` Parts 1-7.

- [ ] STM32CubeIDE installed
- [ ] Project created for NUCLEO-H7B3ZI-Q
- [ ] SPI4 configured
- [ ] GPIOs configured (PE11=CS, PD0=RST, PD1=DONE)
- [ ] USART3 configured (115200 baud)
- [ ] Driver files added (`sic_fpga.c`, `sic_fpga.h`)
- [ ] Main loop code added
- [ ] Project builds without errors
- [ ] Flash succeeds

### 2.4 Serial Output Test
```bash
screen /dev/cu.usbmodem14203 115200
```
Press RESET button on Nucleo. You should see:
```
=== SIC Receiver Starting ===
Waiting for FPGA...
ERROR: FPGA not responding (check wiring and FPGA programming)
SIC Receiver initialized

SPI read error: 3
```
- [ ] Serial output appears
- [ ] "SPI read error" is expected (FPGA not connected yet)

**Phase 2 Pass Criteria:** Serial output visible, errors are expected.

---

## Phase 3: Connect the Boards

**Goal:** Establish SPI communication between FPGA and STM32.

### 3.1 Power Down Both Boards
- [ ] Unplug USB from both boards

### 3.2 Wire Connections

Refer to `syn/ice40/WIRING_GUIDE.md` for exact pin locations.

| Signal | STM32 Pin | iCE40 EVN Pin | Wire Color (suggested) |
|--------|-----------|---------------|------------------------|
| CS     | PE11      | 16            | White                  |
| SCK    | PE12      | 15            | Yellow                 |
| MISO   | PE13      | 14            | Orange                 |
| MOSI   | PE14      | 17            | Blue                   |
| RST    | PD0       | 18            | Green                  |
| DONE   | PD1       | 19            | Purple                 |
| GND    | GND       | GND           | Black                  |
| GND    | GND       | GND           | Black                  |

- [ ] All 6 signal wires connected
- [ ] 2 GND wires connected (important for signal integrity!)
- [ ] Double-check no wires are swapped
- [ ] No bare wire touching adjacent pins

### 3.3 Power Up Sequence
1. [ ] Plug in FPGA board first
2. [ ] Verify red LED blinking, green LED on
3. [ ] Plug in Nucleo board
4. [ ] Open serial terminal

### 3.4 Verify Communication
Press RESET on Nucleo. You should see:
```
=== SIC Receiver Starting ===
FPGA ready!
SIC Receiver initialized

SIC Channels @ 100 ms:
  CH0: I=  1234 Q=  -567  Mag= 1358 (-11.5 dB) [PEAK]
  CH1: I=   456 Q=   234  Mag=  512 (-19.0 dB)
  CH2: I=  -890 Q=   123  Mag=  898 (-15.1 dB)
  CH3: I=   100 Q=   -50  Mag=  111 (-24.3 dB)
```
- [ ] "FPGA ready!" message appears
- [ ] Channel data streaming (values will differ)
- [ ] All 4 channels show non-zero I values
- [ ] Q values are non-zero (full I/Q working)
- [ ] One channel marked `[PEAK]`

**Phase 3 Pass Criteria:** Channel data streaming with I and Q values.

---

## Phase 4: Functional Tests

**Goal:** Verify the channelizer is processing signals correctly.

### 4.1 Test Pattern Verification

The FPGA generates a test pattern (incrementing counter). Observe:
- [ ] Channel values change over time
- [ ] Values follow a pattern (wrapping around)

### 4.2 Reset Test
- [ ] Press RESET on Nucleo
- [ ] Verify "FPGA ready!" appears quickly (<1 sec)
- [ ] Data streaming resumes

### 4.3 Power Cycle Test
- [ ] Unplug both USB cables
- [ ] Reconnect FPGA first, then Nucleo
- [ ] Verify everything comes up correctly

### 4.4 SPI Speed Test (Optional)

Edit `sic_fpga.h` to try different SPI speeds:
```c
#define SIC_SPI_CLOCK_HZ  20000000  // Try 20 MHz
```
- [ ] Rebuild and flash
- [ ] Verify data still correct at higher speed

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| No red LED blink | FPGA not programmed | Run `make prog` |
| "FPGA not responding" | Wiring issue | Check RST/DONE wires |
| "SPI read error" | SPI wiring issue | Check SCK/MISO/MOSI/CS |
| All zeros | SPI polarity wrong | Check CPOL/CPHA in CubeIDE |
| Garbage data | Baud rate wrong | Verify 115200 |
| Q always zero | Old FPGA bitstream | Reprogram FPGA |

---

## Success Checklist

When everything works:

- [ ] FPGA red LED blinking (heartbeat)
- [ ] FPGA green LED on (channelizer ready)
- [ ] Serial shows "FPGA ready!"
- [ ] All 4 channels have I and Q data
- [ ] Magnitudes computed correctly
- [ ] Peak channel identified
- [ ] System survives reset and power cycle

🎉 **Congratulations!** The SIC receiver prototype is operational.

---

## Next Steps After Bringup

1. **Connect real I2S ADC** — Replace test pattern with actual signal
2. **Test with RF input** — Inject test signal, verify channel separation
3. **Implement SIC algorithm** — Add interference cancellation logic
4. **Optimize** — Profile performance, tune SPI timing
5. **Document** — Record any lessons learned

---

## Notes / Observations

*(Use this space to record anything unexpected during bringup)*

Date: ____________

Hardware versions:
- iCE40UP5K-B-EVN rev: ______
- NUCLEO-H7B3ZI-Q rev: ______

Notes:
