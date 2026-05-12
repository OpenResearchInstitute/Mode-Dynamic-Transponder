# Hardware Bringup Checklist

Step-by-step checklist for bringing up the SIC receiver prototype hardware.
**Read `mdt_sic/syn/ice40/WIRING_GUIDE.md` before starting** — it has critical notes
about pin locations and the FPGA programming workflow.

## Required Hardware

- [ ] Lattice iCE40UP5K-B-EVN evaluation board (~$50)
- [ ] STM32 NUCLEO-H753ZI board (~$70)
- [ ] 8× female-female jumper wires (6 signal + 2 ground)
- [ ] 2× Micro-USB cables (one for each board)
- [ ] Windows PC with Lattice Radiant installed
- [ ] MSYS2 with openFPGALoader installed (see TOOLCHAIN_SETUP.md)
- [ ] Zadig USB driver tool (https://zadig.akeo.ie/)
- [ ] Serial terminal software (PuTTY, CoolTerm, screen)

---

## Phase 1: FPGA Board Only

**Goal:** Verify FPGA board works and can be programmed.

### 1.1 Initial Power-Up
- [ ] Connect USB to iCE40 board (J6 USB connector)
- [ ] Verify power LED illuminates
- [ ] Board enumerates as USB device in Windows Device Manager

### 1.2 Set Up Zadig USB Driver
- [ ] Open Zadig
- [ ] Options → List All Devices
- [ ] Select **"USB Serial Converter A"** (Interface 0)
- [ ] Verify right side shows **WinUSB** — if not, click **Replace Driver**

> ⚠️ Windows reverts the FTDI driver to default on every USB reconnect.
> You must rerun Zadig every time you reconnect the iCE40 board.

### 1.3 Build Bitstream in Radiant
- [ ] Open `mdt_sic/syn/radiant/sic_receiver/sic_receiver.rdf` in Lattice Radiant
- [ ] Click the green Run button to synthesize, place & route, and export
- [ ] Wait for "Bitstream authenticated" in the log
- [ ] Verify no errors (warnings are OK)

### 1.4 Program the FPGA
- [ ] **Disconnect STM32 board** (SPI lines interfere with flash programming)
- [ ] Open **MSYS2 UCRT64** from Start Menu
- [ ] Run:

```bash
openFPGALoader -b ice40_generic -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

If you get `ff` JEDEC ID with no progress bar, try `--cable-index 1`:

```bash
openFPGALoader -b ice40_generic --cable-index 1 -f --unprotect-flash \
  /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
```

**Successful programming output:**
```
JEDEC ID: 0x20ba16
Detected: micron N25Q32 64 sectors size: 32Mb
Erasing: [==================================================] 100.00%
Done
Writing: [==================================================] 100.00%
Done
Wait for CDONE DONE
```

- [ ] Erasing and Writing progress bars appear ✓
- [ ] "Wait for CDONE DONE" at the end ✓

### 1.5 Verify MD5 (Optional but Recommended)
```bash
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 readback.bin
md5sum /c/Mode-Dynamic-Transponder/mdt_sic/syn/radiant/sic_receiver/impl_1/sic_receiver_impl_1.bin
md5sum readback.bin
# Both hashes must match
```

### 1.6 Power Cycle and Verify LEDs
- [ ] Unplug and replug iCE40 USB (cold boot loads new bitstream)
- [ ] RGB LED cycles green/blue (channelizer running)
- [ ] Red LED blinks at ~0.7 Hz (heartbeat)

**Phase 1 Pass Criteria:** RGB LED shows green/blue cycling, red blinks.

---

## Phase 2: STM32 Board Only

**Goal:** Verify STM32 board works and serial output functions.

### 2.1 Open the Firmware Project
- [ ] Open STM32CubeIDE
- [ ] **File → Import → General → Existing Projects into Workspace**
- [ ] Browse to `mdt_sic/firmware/stm32/sic_receiver/`
- [ ] Uncheck "Copy projects into workspace"
- [ ] Click Finish

### 2.2 Build and Flash
- [ ] **Project → Clean**
- [ ] **Project → Build** — verify no errors
- [ ] Connect Nucleo USB (CN1 ST-Link connector)
- [ ] **Run → Run** to flash

### 2.3 Open Serial Terminal
Connect at **115200 baud** to the ST-Link virtual COM port.

Press RESET on Nucleo. You should see:
```
=== SIC Receiver Starting ===
Waiting for FPGA...
ERROR: FPGA not responding (check wiring and FPGA programming)
SIC Receiver initialized

SPI read error: 3
```
- [ ] Serial output appears
- [ ] "SPI read error" is expected — FPGA not connected yet

**Phase 2 Pass Criteria:** Serial output visible, errors expected.

---

## Phase 3: Connect the Boards

**Goal:** Establish SPI communication between FPGA and STM32.

### 3.1 Power Down Both Boards
- [ ] Unplug USB from both boards

### 3.2 Wire Connections

> ⚠️ MISO is on **J3 pin 22A**, NOT on J52 pin labeled "MISO".
> J52 MISO (site 14) is a dedicated hardware SPI pin that does not
> function as GPIO output in Radiant. Use J3 22A (site 12).

| Signal | STM32 Pin | STM32 Connector | iCE40 EVN Location | Notes |
|--------|-----------|-----------------|-------------------|-------|
| CS | PE11 | CN12 | J52 labeled SS | Active low |
| SCK | PE12 | CN12 | J52 labeled SCK | |
| **MISO** | **PE13** | **CN12** | **J3 pin 22A** | **NOT J52 MISO!** |
| MOSI | PE14 | CN12 | J52 labeled MOSI | |
| RST | PD0 | CN11 | J3 pin 18A | |
| DONE | PD1 | CN11 | J3 pin 29B | |
| GND | GND | CN11 | GND | |
| GND | GND | CN11 | GND | Use 2 wires |

- [ ] All 6 signal wires connected
- [ ] 2 GND wires connected (important for signal integrity!)
- [ ] MISO wire is on **J3 pin 22A** (not J52)
- [ ] Double-check no wires are swapped

### 3.3 Power Up Sequence
1. [ ] Plug in FPGA board first
2. [ ] Verify RGB LED shows green/blue cycling
3. [ ] Plug in Nucleo board
4. [ ] Open serial terminal at 115200 baud

### 3.4 Verify Communication
Press RESET on Nucleo. You should see:
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

- [ ] Channel data streaming ✓
- [ ] All 4 channels show data ✓
- [ ] CH1 and CH3 show non-zero Q values ✓
- [ ] One channel marked [PEAK] ✓

> Note: CH0 Q is always 0. This is a known limitation — the channelizer
> currently processes only the real part of the input. Complex I/Q
> channelizer processing is the next development milestone.

**Phase 3 Pass Criteria:** All 4 channels streaming data.

---

## Phase 4: Functional Tests

### 4.1 Reset Test
- [ ] Press RESET on Nucleo
- [ ] Data streaming resumes within 1 second
- [ ] All 4 channels present

### 4.2 Power Cycle Test
- [ ] Unplug both USB cables
- [ ] Reconnect FPGA first, then Nucleo
- [ ] Verify everything comes up correctly

### 4.3 Verify FPGA Bitstream Integrity
After any FPGA programming, verify the flash contents match:
```bash
openFPGALoader -b ice40_generic --dump-flash --file-size 104156 readback.bin
md5sum sic_receiver_impl_1.bin
md5sum readback.bin
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `ff` JEDEC ID, no progress bar | Zadig driver reverted | Rerun Zadig, set WinUSB on Interface 0 |
| `ff` JEDEC ID with WinUSB set | STM32 board connected | Disconnect STM32 before programming FPGA |
| `ff` JEDEC ID, try cable index | Cable index mismatch | Try `--cable-index 1` or `--cable-index 0` |
| CDONE FAIL after programming | Synthesis error in bitstream | Check Radiant log for errors, rebuild |
| No RGB LED activity | FPGA not booted | Power cycle iCE40 board after programming |
| All zeros from SPI | MISO wire on wrong pin | Move MISO wire to J3 pin 22A |
| `0x0F` repeating | MISO floating high | Check MISO wire connection to J3 22A |
| "FPGA not responding" | DONE wire issue | Check J3 pin 29B to PD1 |
| STM32 red LED rapid blink | Firmware crash | Check DataSize=8BIT in spi.c |
| Q always zero for all channels | Known limitation | Complex I/Q channelizer not yet implemented |

---

## Success Checklist

- [ ] FPGA RGB LED: red blinks (~0.7 Hz), green/blue cycling
- [ ] Serial shows 4 channels of data streaming
- [ ] CH1 and CH3 show non-zero Q values
- [ ] Peak channel identified correctly
- [ ] System survives reset and power cycle
- [ ] MD5 verified after FPGA programming

🎉 **Congratulations!** The SIC receiver prototype is operational.

---

## Next Steps After Bringup

1. **Complex I/Q channelizer** — Update polyphase_channelizer_top.vhd to process sample_im
2. **Connect real I2S ADC** — Replace test pattern with TLV320ADC6120 input
3. **Implement SIC algorithm** — Peak detection, reconstruction, subtraction on STM32
4. **RF testing** — Inject test signal, verify channel separation

---

## Hardware Versions

- iCE40UP5K-B-EVN rev: ______
- NUCLEO-H753ZI rev: ______
- Radiant version: 2025.2
- Bringup date: ____________

## Notes / Observations

*(Record anything unexpected during bringup)*
