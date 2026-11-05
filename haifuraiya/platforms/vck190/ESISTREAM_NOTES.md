# ESIstream on the VCK190 — package review and plan

_Status 2026-10-31. Everything marked **verified** was read from the named
document or measured in Vivado; everything marked **estimate** is our
arithmetic and still has to be confirmed by Teledyne or by a measurement._

## 1. Where this sits

Tier 1 (memory loopback: DDR → DMA → pacer → receiver → DMA → DDR) passed on
2026-10-25: 24/24 frames decodable, 0.00–0.56% pre-FEC BER, flat, matching
xsim. The receiver, the Xilinx AXI DMA and the PetaLinux image are the
baseline. The next two tiers put the Teledyne e2v EV12AQ600 ADC's serial
interface in front of the receiver:

- **Tier 2 — digital loopback.** Same `opv_play`, same stimulus, same
  receiver; the ESIstream link spliced into the sample path:
  DDR → DMA → ESIstream TX → GTY → (loopback) → GTY → ESIstream RX →
  reassembler → pacer → receiver → DMA → DDR. No ADC.
- **Tier 3 — RF loopback.** Opulent Voice transmitter → EV12AQ600 on the
  FMC evaluation module → ESIstream RX → digital downconverter → receiver.

## 2. The package (verified)

`Package_ESIstream_Xilinx_xcvc1902-vsva2197-2mp-e-s-main.zip` from
esistream.com ("esistream-14b16b-packages", VCK190). The 14b/16b package is
the right one: the EV12AQ600 speaks ESIstream 14b/16b (14 payload bits per
16-bit frame + 1 disparity bit + 1 clock bit; 87.5 % efficient). The 62b/64b
package is the newer encoding for the next generation of converters
(EV12DD700, transmit side, later).

- **License: public domain** (Unlicense-style dedication in every source
  file; "this disclaimer must be retained"). Can go in the open repo verbatim.
- **Pure VHDL**, 101 files, ~6,200 lines of IP: `src_rx` (lane decoding,
  frame alignment, descrambler, output buffer), `src_tx` (encoder,
  scrambler, disparity), `src_tx_rx` (both around the transceiver),
  `src_tx_emulator` (fake-ADC data generator for the loopback example),
  `src_common` (register map, UART, SPI master for the ADC), per-example
  xsim testbenches. Three examples: `xm107` (loopback card), `aq600` (ADC
  EVM), `aq600max`. A Python/UART GUI we will not use.
- **Link as configured:** GTY, 8 lanes, 10.0 Gb/s, 156.25 MHz reference,
  64-bit transceiver datapath, raw encoding (ESIstream does its own
  alignment, comma `0x00FFFF00`, and descrambling). Fabric sees, per lane,
  **4 × 14-bit samples per 156.25 MHz clock** — 5 G samples/s over 8 lanes.
- **Interfaces we meet:** `rx_esistream.data_out` (per lane 4 × 14 bits),
  `valid_out` per lane, `lanes_ready`; `tx_esistream.data_in` of the same
  shape. The IP does not care what the 14 bits mean.
- **Vivado 2021.1** scripts and block designs; VCK190 board file 2.2 (same as
  ours). Expect an IP-upgrade pass under 2022.2 (transceiver and CIPS block
  designs). First step of the port: run `xm107/script_64b.tcl` under 2022.2
  untouched, into a scratch directory, and read the log.
- **No user guide in the zip** — requested from Teledyne.

## 3. Pins (verified in Vivado 2022.2, `get_package_pins`, and UG1366)

The package's constraints (`xm107/xdc`, `aq600/xdc`, identical lane pins):

| Signal | Pins | Pin function | Quad |
|---|---|---|---|
| lanes 0–3 (`rxp[0..3]`) | AB2 AA4 Y2 W4 | MGTYRXP0..3_201 | GTY201 |
| lanes 4–7 (`rxp[4..7]`) | V2 U4 T2 R4 | MGTYRXP0..3_202 | GTY202 |
| reference `sso_p/n` | M15 / M14 | MGTREFCLKP1/N1_**201** | GTY201 refclk1 |

UG1366 ("GTY Transceivers" table; section "GTY201–GTY203: FMCP1 and
GTY204–GTY206: FMCP2"):

| Quad | Lanes | refclk0 (board) | refclk1 (card) |
|---|---|---|---|
| GTY201 | FMC1 DP0–DP3 | SI570_8A34001_MUX_BUF0 | FMC1_GBTCLK0 |
| GTY202 | FMC1 DP4–DP7 | none | FMC1_GBTCLK1 |
| GTY204 | FMC2 DP0–DP3 | SI570_8A34001_MUX_BUF1 | FMC2_GBTCLK0 |
| GTY205 | FMC2 DP4–DP7 | SI570_8A34001_MUX_BUF2 | FMC2_GBTCLK1 |

So the package as shipped targets **FMCP1 (J51)**: lanes on GTY201/202, the
ADC's SSO on GTY201 refclk1 = FMC1_GBTCLK0. Teledyne's e-mail of 2026-09-11
said the validation was done "in the VCK190's FMCP2 slot". The two slots are
electrically equivalent for this purpose; a bitstream is not — its
constraints name one slot. **Open question to Teledyne (see §7).** Until
answered: use the package's constraints as shipped and put the card in
**J51**.

EVM ↔ FMC pin mapping (EV12AQ600-FMC-EVM user guide, June 2017): the eight
lanes are `DP0..DP7_M2C` = B SL0, B SL1, A SL0, A SL1, D SL0, C SL1, C SL0,
D SL1 (two links per ADC core, link 0 = even samples, link 1 = odd); SSO on
`GBTCLK0_M2C`; ADC/PLL SPI, resets and mode selects on LA pins at 1.8 V;
the card does not use VADJ.

Board clock pins for tier 2 (quad 201 refclk0): **AB11 / AB10**
(MGTREFCLKP0/N0_201).

## 4. Tier 2 design (digital loopback)

- **Reference clock:** the board's, on GTY201 refclk0 (AB11/AB10), set to
  156.25 MHz by the System Controller ("User1 FMC1 Si570" / 8A34001 block in
  the Board User Interface; jumper selects which). Slot J51 stays **empty**.
- **Loopback:** the transceivers' internal near-end loopback. No XM107 card
  required (optional later, for a physical loop on the real pins).
- **Data path:** replace the package's `tx_emulator` with our DMA source;
  take `rx_esistream.data_out` into a **reassembler** that rebuilds 32-bit
  I/Q beats for the pacer. Frame layout is ours on both ends: one 16-bit I,
  one 16-bit Q, a valid flag and a sequence number per 56-bit lane slot
  (4 frames × 14 bits), samples sent round-robin over the 8 lanes so a lane
  order or alignment error scrambles the sample order and the receiver fails
  loudly. Lossless: the receiver must produce the same grade table as tier 1.
  Do **not** imitate the ADC's 12-bit format here — the ADC never quantizes
  our baseband; the downconverter hands the receiver its samples (§5).
- **Clock domains:** two async FIFOs, 100 MHz (DMA/pacer/receiver) ↔
  156.25 MHz (ESIstream). The receiver is consume-on-arrival and never knows
  the link exists.
- **Control:** the package's UART/register-map/Python GUI replaced by a few
  AXI-Lite registers on our control plane (lane enables, sync, `lanes_ready`,
  error counters), as for everything else.
- **Simulation first:** the package has xsim testbenches for the link; the
  reassembler gets its own bench; then the system bench with the link in.

### 4.1 Tier 2 in simulation — PASS 2026-11-05

What exists (all under `haifuraiya/platforms/vck190/` unless noted):

| File | What it is |
|---|---|
| `../../third_party/esistream_vck190/` | Teledyne's zip, verbatim; `README_ORI.md` there records origin, md5 and license. Not a submodule (Teledyne ships a zip, not a repository). |
| `rtl/esi/esi_loop_pkg.vhd` | The slot layout: per lane per link clock, 4 × 14-bit frames carry VALID, I[15:0], Q[15:0], a 9-bit marker (0x155) and a 14-bit sequence number. |
| `rtl/esi/esi_sample_packer.vhd` | AXI-Stream in (100 MHz) → one sample per link clock, rotating over the lanes, idle slots elsewhere → `tx_esistream.data_in`. |
| `rtl/esi/esi_sample_reassembler.vhd` | `rx_esistream.data_out` → the one valid slot per clock → AXI-Stream out (100 MHz); counts `seq_errors`, `marker_errors`, `multi_errors`, `samples_rcvd`. |
| `rtl/esi/esi_link_loop.vhd` | packer → `tx_esistream` → link → `rx_esistream` → reassembler, plus bring-up (ip_ready, one sync pulse, wait for `lanes_ready`, release). Generic `IDEAL_LINK`: true = TX words wired to RX words (simulation); false = words out/in on `xcvr_*` ports for the GTY block (hardware). |
| `sim/esi/tb_esi_link_loop.vhd`, `run_esi_link_nvc.sh` | Link-level bench (nvc; `rx_xpm_async_fifo_sim.vhd` stands in for the one XPM wrapper — never in a Vivado project). |
| `sim/tb_haifuraiya_vck190_esi.vhd` | **Copy** of the shared bench with the loop spliced in; header records the source md5; `diff` against the shared bench shows only `ESI:` hunks. The ZCU102 bench is untouched. |
| `sim/run_mdt_vck190_esi_sim.tcl` | Sets `ESI_LOOP 1` and sources the tier-1 runner, which then adds the 22 link files (gate 54) and uses the copy as top. |

Measured:

- Link-level bench (nvc, 2026-11-02): link ready 431.6 ns after reset
  release; 3000 samples sent, 3000 received, 0 mismatched, all counters 0.
  A second instance behind a deliberately faulty "transceiver" (lane-1 SEQ
  bit 0 stuck after link-up) counts exactly 750 = 2 × 3000/8 sequence
  errors, as predicted before the run. The counters can fail, so zero means
  something. Note: a pure lane *swap* is invisible at this sample rate (one
  sample per ~8 link words never shares a word with its neighbour) — the
  fixture catches alignment and corruption, not lane permutation.
- System bench (xsim on chococat, 2026-11-02 10:54 → 2026-11-04 ~22:30,
  elapsed 59 h 40 min): **25/25 frames decodable, pre-FEC BER 0.00–0.56 %,
  flat** — the same range as tier 1 (grade on `seam_chan_out.txt`,
  53,600 soft bits = 25.00 frames, all polarity +). Link counters at the
  end of the run, read from the waveform: **sent = rcvd = 20,829,760**
  (20,799,760 samples fed + 30,000 zero tail), seq_errors = marker_errors
  = multi_errors = 0. Receiver readbacks through the link: CFO applied
  498 Hz (truth 500), SYM_CLK_OFFSET −2254 Q24 (+11.5 ppm stimulus,
  expected ≈ −2200). Register bracket passed unchanged; first sample
  accepted 2 µs after the bracket; link up within the first microsecond
  of each reset release.
- Two sync-word correlation peaks were dented (627,732 at 561 ms and
  626,265 at 801 ms against the full-scale 786,408 = 24 × 32,767); both
  frames still synced and decoded (0.37 % and 0.09 %). At this error rate
  one or two dented sync words in 25 is what noise predicts; the same seed
  in tier 1 should show the same two dents — not yet compared.
- The bench's own tail did **not** complete: after injection, SL-A polled
  for symbol lock 40 ms *after the signal ended* (fails by placement, not
  by the receiver), then the SL-C write to demod register 0x0AC got no
  `bvalid` and the bench's write timeout called `$finish` at 1081.66 ms,
  before the `ESI LINK` line and the pass/fail summary printed. The
  AXI-Lite path does not cross the link. Whether the tier-1 run of
  2026-10-23 ended the same way is the open question; its log tail
  decides whether this is bench-tail business or a timing difference
  worth chasing. (The dead-air `ratio_pct = 247 %` readback is in the
  same bucket.)
- Simulation cost: xsim reported **cpu 4 h 42 min against 59 h 40 min
  elapsed** — 8 % of one core. The run was not compute-bound; the
  ESIstream lane busywork is not what made it slow. Suspects: the bench's
  per-sample textio writes (`channel_iq.txt`, `soft_raw.txt`,
  `seam_chan_out.txt`, `f1_error.txt`) or a loaded host. Tier 1's
  `run: Time (s)` line gives the baseline ratio. Until that is known,
  `NB_LANES => 2` is not the first thing to try.

Things that bit us: `git apply` of the review patch fails ("No such file")
because its paths lack the `haifuraiya/` prefix — the tarball carries the
whole runner, the patch is for reading only. The core does not analyse in
nvc (`lowpass_ema.vhd` line 132 aggregate), so the system bench runs in
xsim only.

## 5. Tier 3 operating point (ADC)

Candidate, with sources:

| Item | Value | Status |
|---|---|---|
| Mode | 4-channel (single core per input), **channel A only** | verified: datasheet §8 modes; chosen for no interleaving spurs, 2 lanes, 8 samples/clock |
| f_CLK | **5 GHz** | verified: datasheet "Performance vs F_clock" (p. 119) covers 5 GHz, flat; LMX2592 VCO fundamental 3.55–7.1 GHz (TI datasheet) — direct output, no doubler/divider |
| Lanes | 2 (ASL0/ASL1 = DP2/DP3), 10 Gb/s, SSO 156.25 MHz | verified: lane rate = 2 × f_CLK, SSO = f_CLK/32 (EVM guide); = package's validated link config |
| Core rate | 1.25 GSps | arithmetic |
| Input band | 5.65–5.67 GHz, **extended bandwidth** (6.5 GHz option) | verified: datasheet §8 analog bandwidth |
| IF after sampling | 660 MHz (5.66 GHz aliased, non-inverted) | estimate (arithmetic) |
| Downconverter | mix at IF, decimate **÷125 → 10 MSps** straight into the channelizer (halfband not needed); 625 kSps channel = 1.25 G / 2000 exactly | estimate; the main new fabric block |
| ADC ENOB at 5.58 GHz input, 4-channel mode | 7.0–7.5 (−1 dBFS), 7.4–7.7 (−3 dBFS); SNR 52.6 dBFS min | verified: datasheet dynamic-performance table, 4-channel mode |
| Resolution after ÷125 | ~11 effective bits in-band | estimate (+3.5 bits decimation gain) |
| EVM clock vs lab source | LMX2592 at 5–6 GHz: −112.6 dBc/Hz @100 kHz, −134 @1 MHz, −152.6 @10 MHz → ~50–80 fs jitter → jitter-limited SNR ≈ 52 dB at 5.66 GHz ≈ ADC's own; expect ~2–3 dB SNR cost vs a lab source; close-in noise negligible for 54 kbaud MSK | estimate |
| IMD3 at 5.5 GHz | 38 dB at −7 dBFS | verified; RF front-end filtering/gain-plan question |
| Control bits CB1/CB2 | timestamp (127-bit PRBS, reset on SYNC) or parity | verified: datasheet §8 |
| First light | ADC **ramp** test mode + package `txrx_frame_checking` | verified: datasheet §8 test modes |
| Later option | 4 cores in phase on one input, averaged in fabric: ~+6 dB SNR | verified: AN 60S 218492 |

Physical: card in J51 (pending §7), SSO on GTY201 refclk1 (M15/M14); tier 2
constraints change only the reference-clock pair.

## 6. VADJ / System Controller (verified, UG1366)

The VADJ_FMC rail (0 / 1.2 / 1.5 V) powers the FPGA's FMCP banks 706–708 and
both slots' VADJ pins; the System Controller sets it from the card's IPMI
EEPROM at power-on and sets **0 V** if it finds no value it can supply. The
EVM's logic is 1.8 V and it does not use VADJ, so expect 0 V by default —
which is Teledyne's "you must force VADJ to 1.5 V from the carrier". The
override is in the Board User Interface: **FMC → Set VADJ → explicit 1.5 V**
(the UI's "Use FMC EEPROM Voltage" is the default). The BUI talks to the
System Controller over **USB-UART J207** — the same USB cable as JTAG and the
Versal console; no Ethernet needed. Sequence: carrier on → set VADJ → card
power on (EVM guide §3.2 order, with the override inserted). Whether the
override persists across power cycles: ask Teledyne/AMD.

Electrical question for Teledyne: the card's signals toward the FPGA are
1.8 V into 1.5 V banks, and the FPGA drives 1.5 V swings into the card's 1.8 V
inputs (SPI, reset, selects). Teledyne called the combination compatible;
we want that in writing since the risk is the FPGA's banks.

## 7. Open questions for Teledyne

1. Which slot was the VCK190 package validated in? The constraints in the
   downloadable package are for FMCP1/J51 (GTY201/202, SSO on M15/M14); the
   e-mail said FMCP2.
2. The user guide for the VCK190 ESIstream package (not in the zip).
3. Confirmation that f_CLK = 5 GHz (4-channel mode) is a supported operating
   point, and the EVM's LMX2592 configuration for it.
4. The VADJ = 1.5 V procedure and the 1.5 V-bank / 1.8 V-signal compatibility
   statement, in writing. Does the override persist across power cycles?
5. Item 7 of the thread: the FMC-only EV12AQ600 daughter card, on loan, and
   when one could ship.

## 8. Next steps

1. Port check: run `xm107/script_64b.tcl` under Vivado 2022.2 untouched
   (scratch dir), log the IP-upgrade complaints. Measures the port cost.
2. ~~Write the reassembler + its bench; frame layout per §4.~~ Done; tier 2
   in simulation **passed** 2026-11-05 (§4.1). Open from that run: compare
   the bench tail (SL-A, 0x0AC bvalid timeout, cpu/elapsed ratio) with the
   tier-1 log; then the sync-word dents against tier 1's correlation peaks.
3. Bring `tx_esistream`/`rx_esistream` + the package's transceiver block
   into our block design (new `vck190_esistream_bd.tcl` or a `VCK190_ESI=1`
   variant of the playback BD), board clock on refclk0, internal loopback,
   AXI-Lite control.
4. Tier-2 acceptance: `opv_play` unchanged, 24/24 flat, same table as tier 1.
5. Downconverter design pass on paper (mode/clock per §5), then its bench,
   then fabric — for tier 3, when the card arrives.
