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

### 4.1 Tier 2 in simulation — PASS, and bit-identical to tier 1 (2026-11-08)

What exists (all under `haifuraiya/platforms/vck190/` unless noted):

| File | What it is |
|---|---|
| `../../third_party/esistream_vck190/` | Teledyne's zip, verbatim; `README_ORI.md` there records origin, md5 and license. Not a submodule (Teledyne ships a zip, not a repository). |
| `rtl/esi/esi_loop_pkg.vhd` | The slot layout: per lane per link clock, 4 × 14-bit frames carry VALID, I[15:0], Q[15:0], a 9-bit marker (0x155) and a 14-bit sequence number. |
| `rtl/esi/esi_sample_packer.vhd` | AXI-Stream in (100 MHz) → one sample per link clock, rotating over the lanes, idle slots elsewhere → `tx_esistream.data_in`. |
| `rtl/esi/esi_sample_reassembler.vhd` | `rx_esistream.data_out` → the one valid slot per clock → AXI-Stream out (100 MHz); counts `seq_errors`, `marker_errors`, `multi_errors`, `samples_rcvd`. |
| `rtl/esi/esi_link_loop.vhd` | packer → `tx_esistream` → link → `rx_esistream` → reassembler, plus bring-up (ip_ready, one sync pulse, wait for `lanes_ready`, release). Generic `IDEAL_LINK`: true = TX words wired to RX words (simulation); false = words out/in on `xcvr_*` ports for the GTY block (hardware). |
| `sim/esi/tb_esi_link_loop.vhd`, `run_esi_link_nvc.sh` | Link-level bench (nvc; `rx_xpm_async_fifo_sim.vhd` stands in for the one XPM wrapper — never in a Vivado project). Negative test: a faulty lane must count exactly the predicted sequence errors (750 at 8 lanes, 2999 at 2, 1500 at 4; N = 3000). |
| `sim/tb_haifuraiya_vck190_esi.vhd` | **Copy** of the shared bench with the loop spliced in (`NB_LANES => 2`, the tier-3 lane count); header records the source md5; `diff` against the shared bench shows only `ESI:` hunks. Also writes `esi_rx_samples.txt`: every sample the core accepts, with the clock gap since the previous one. |
| `sim/run_mdt_vck190_esi_sim.tcl` | Sets `ESI_LOOP 1` and sources the tier-1 runner (which consumes and unsets the switch, adds the 22 link files — gate 54 — uses the copy as top, and archives every run's log, waveform and output files to `sim/logs/<top>_<stamp>/`). |
| `tools/esi_rx_check.py` | `esi_rx_samples.txt` against the stimulus: value mismatches and the gap histogram. |
| `tools/which_phase.py` | Golden-channelizer model at both halfband phases against a `channel_iq.txt` capture: which phase did the run use? (Channel 5 of the bench is model index 59 — the wrapper relabels.) |
| `tools/bisect_sim_pace.sh` | Per-commit simulation pace in a scratch worktree (10-minute points). |

Measured:

- **Link bench** (nvc, 2026-11-02/07): link ready 431.6 ns after reset release; 3000 sent, 3000 received, 0 mismatched, all counters 0, at 8, 4 and 2 lanes; faulty-lane instance counts exactly the predicted errors each time. Latency 25 aclk cycles (28 in xsim with the real XPM FIFO).
- **System bench, 25 frames, 8 lanes, old shared bench** (xsim, 2026-11-02→04, 59 h 40 min): 25/25 decodable, pre-FEC BER 0.00–0.56 %, flat. Link counters: sent = rcvd = 20,829,760 (20,799,760 + 30,000 tail), zero errors.
- **System bench, 3 frames, 2 lanes** (2026-11-06, 3 h 57 min): 3/3; **every sample the core received checked against the stimulus: 3,229,963 received, 0 mismatches, 3,229,962 gaps all exactly 5 clocks** (2026-11-08 capture run).
- **Tier 1 vs tier 2, same 3-frame stimulus, fixed shared bench (2026-11-08): `soft_raw.txt` and `channel_iq.txt` byte-identical**; grade 0.33 / 0.09 / 0.19. The receiver through the link produces the same bits as the receiver fed directly.
- **25 frames, fixed bench, tier 1 (2026-11-08→09, archive `tb_haifuraiya_channelizer_axi_20261108_2122`): 25/25, pre-FEC BER 0.00–0.56 %, and `soft_raw.txt` byte-identical to the 2026-11-04 tier-2 run through the 8-lane link.** The per-frame table (0.42, 0.47, 0.19, 0.00, 0.19, 0.37, 0.09, 0.09, 0.28, 0.09, 0.19, 0.19, 0.19, 0.37, 0.19, 0.19, 0.19, 0.56, 0.09, 0.09, 0.28, 0.09, 0.09, 0.19, 0.37 %) is the acceptance reference for both tiers. Stimulus: the acceptance command with `--frames 25`, md5 `6088c57b03b048abab52b8cd29fdd867`, 20,799,760 samples.
- Pace (3-frame stimulus): core alone 130–146 ms of simulated time per hour (same at commit `8980e58` and HEAD — no regression); 8 lanes 18.6 ms/h; **2 lanes 51 ms/h**. The link's cost is the lanes first, then the 156.25 MHz clock and the two crossing FIFOs. (The Vivado `run: Time` cpu figure is the Vivado process, not `xsimk`; `top` on `xsimk` is the real load — it was 100 % of one core throughout.)

**Finding — the shared bench dropped the first sample.** Before 2026-11-08, tier 1 and tier 2 differed by exactly one 20 MSps sample of halfband decimation phase: the channel output rotated 14.06° (= 2π · 781.25 kHz · 50 ns), 83 of 8688 soft symbols moved, one frame picked up two coded-bit errors. The golden channelizer model put tier 2 on the *designed* phase (0.0°, residual 0.0 %) and tier 1 at +14.1°, i.e. a stream starting at `stim[1]`. Cause, in `tb_haifuraiya_channelizer_axi.vhd`: `wait for 2 us` from a clock edge lands exactly on the next edge, so the burst's first `tvalid` rose in the same delta as `aclk`; the core's combinational `sample_valid_int` (`haifuraiya_channelizer_axi.vhd`) updates a delta later and the decimator never saw `stim[0]`. The link's input FIFO reads `tvalid` directly inside its clocked process, caught the sample, and delivered it a full cycle wide — which is why tier 2 was right. Fix: `wait until rising_edge(aclk)` after each such `wait for` (two places). Every per-frame BER table recorded before this fix was computed on the inverted decimation phase; the grade class never changed. The hardware pacer (registered `tvalid`) never had the race.

**Bench tail, pre-existing, in the tracker:** after injection, SL-A polls for symbol lock 40 ms after the signal ended (fails by placement), then the SL-C write to demod register 0x0AC never gets `bvalid` and the bench dies by `$finish` before printing its summary or the `ESI LINK` line — in tier 1 at commit `8980e58` as well. `haifuraiya_demod_regs` commits a write only when AW and W handshake in the same cycle; the bench (correctly) does not promise that. Issue filed 2026-11-06.

**Lessons for the runner (fixed 2026-11-05):** a Tcl global that survives between `source`s turned a tier-1 run into tier 2 for a day — the switch is now consumed and unset on every source; the project directory is deleted on every source, which destroyed the 59-hour waveform — every run now archives its log, `.wdb` and outputs before anything else can run.

### 4.2 Tier 2 in hardware — the design (2026-11-09; build and board test pending)

This is the part other people will want: how Teledyne's ESIstream VHDL and a
Versal GTY quad go into a block design that is otherwise a plain DMA-fed
receiver. Written to be followed, not just read. Everything below is in the
repository; nothing depends on the GUI.

**Shape.** One sentence: the tier-1 playback design with `esi_link_hw`
spliced between the pacer and the receiver, and a two-lane GTY quad in
near-end PMA loopback hanging off it.

```
DDR --NoC--> axi_dma --> pacer --> esi_link/esi (esi_link_hw) --> rx (haifuraiya_rx_axi) --> widen --> axi_dma --NoC--> DDR
                                      |      ^
                        2 x 64 bits   |      |  2 x 64 bits
                        tx_clk        v      |  rx_clk
                                  gt_bridge_ip (bypass) <--> gt_quad_base (GTY, 10.0 Gb/s)
                                                                ch0/ch1 loopback = 010 (near-end PMA)
                                                                refclk0 <- IBUFDS_GTE <- AB11/AB10 (SI570, 156.25 MHz)
CIPS M_AXI_FPD --> smartconnect --> axi_dma 0xA400_0000, rx ctrl 0xA401_0000, rx demod 0xA402_0000, esi 0xA403_0000
```

**Files** (under `haifuraiya/platforms/vck190/`):

| File | What it is |
|---|---|
| `rtl/esi/esi_link_loop.vhd` | As §4.1, now with **two link clock domains**: `tx_clk`/`tx_rstn` (packer link side, `tx_esistream`, the bring-up sequencer) and `rx_clk`/`rx_rstn` (`rx_esistream` as both `rx_usrclk` and `rx_frame_clk`, the reassembler). The three signals that cross (sync pulse TX→RX, `lanes_ready` and `release_data` RX→TX) go through Teledyne's `ff_synchronizer_array`. The sync pulse is 4 `tx_clk` wide — Teledyne's own `SYNCTRIG_PULSE_WIDTH` — and is sent 16 clocks after the transceiver reports ready (not 32 clocks after reset as before: in hardware the transceiver is not ready at reset). In simulation both clocks are tied to one; the benches were updated and pass. |
| `rtl/esi/esi_link_hw.vhd` | The block-design module: `esi_link_loop(IDEAL_LINK => false, 2 lanes)` + GTY glue + AXI-Lite registers. Flat ports only (module references cannot take arrays). The bridge's data ports are 128 bits per channel; bits 63:0 carry the word, as in Teledyne's `tx_rx_xcvr_wrapper_64b`. `xcvr_ready = lcpll_lock and tx_resetdone and rx_resetdone` (Teledyne's `ip_ready`). One automatic `gtreset_in` pulse 32 clocks after reset, so the bridge starts without software. Register map in the file header and below. |
| `sim/esi/tb_esi_link_hw.vhd`, `run_esi_link_hw_nvc.sh` | **Unit test** for the wrapper with a stand-in transceiver (4-cycle delay line in `tx_clk`, re-registered in an `rx_clk` of the same frequency and a different phase; GT status lines come up on a schedule after `gt_reset`). Three real clock domains. Checks: the automatic `gt_reset`; `link_ready` and both clock-alive bits; 2000 samples through at one per 5 `aclk`, identical and in order; SNAPSHOT counters (sent = rcvd = 2000, errors 0) and the measured `tx_clk/aclk` ratio (1.5625061 over 10231 `aclk`); a split-phase AXI-Lite write (W three cycles before AW) completes; SYNC_REQ brings the link back (`LINK_DROPS` = 1). **PASS** (nvc in the sandbox, 2026-11-09; not yet run on chococat). Run: `sim/esi/run_esi_link_hw_nvc.sh`, pass = `PASS: tb_esi_link_hw`. |
| `syn/gt_scratch.tcl` | The derivation, reproducible: builds the two-lane GT pair **by hand** from Teledyne's `gty_txrx_8lanes_64b.bd` in a scratch block design (no block automation — the 2022.2 rule names for the bridge are not public), validates it, and dumps every pin of every cell to `gt_2lanes_pins.txt` and the design to `gt_2lanes_bd.tcl`. That dump is where `ch0_loopback`..`ch3_loopback` were found on the quad and where the bridge's `chN_txdata_ext`/`chN_rxdata_ext` names come from. `validate_bd_design: OK` on chococat, 2026-11-09 (third attempt: v1 used automation rules that do not exist; v2 left `ch2/ch3` user clocks unconnected and the quad insists on all four). |
| `syn/vck190_playback_bd.tcl` §4t | The same cells and wires as `gt_scratch.tcl`, in the playback design, when `tier == 2`; the splice; `smartconnect` M03 → `esi/s_axi`; `assign_bd_address` 0xA403_0000; everything grouped into the `esi_link` hierarchy. |
| `syn/vck190_playback_project.tcl` | `VCK190_TIER=2` in the environment adds the 23 ESIstream/esi sources (the sim runner's list plus `esi_link_hw.vhd`) and the constraints file, names the project `mdt_vck190_playback_esi`, and writes `timing_summary_esi.rpt` / `utilization_esi.rpt` / `mdt_vck190_playback_esi.xsa`. Tier 1 is untouched (and its manifest no longer lists the deleted `axi_mon_tap.vhd`, which had made `make vck190-project` fail the 36-file count). |
| `syn/vck190_esi_link.xdc` | Refclk pins AB11/AB10 + `create_clock -period 6.400`; lane pins for quad 201 ch0/ch1 (= FMC1 DP0/DP1, Teledyne's lanes 0/1); `set_clock_groups -asynchronous` between `clk_pl_0` and the two BUFG_GT clocks (`PROCESSING_ORDER LATE` so the GT IP's clock names exist). |
| `vck190.mk` | `make vck190-project-esi` (BD only, minutes) and `make vck190-xsa-esi` (the bitstream); separate project directory, XSA, reports and log. |
| `petalinux/system-user.dtsi` | The link block as `/dev/uio1` (generic-uio), beside the receiver's `/dev/uio0`. Label to be confirmed from the generated `pl.dtsi` after the first tier-2 import. |
| dōgu `tools/opv_play` | The one place the link's registers are read (patch `dogu_opv_play_esi.patch`, 2026-11-10): refuses to play until `link_ready`; `-q` adds the link scoreboard to the readbacks; `-l` reads the link alone, including the transceiver clock against the PL clock. Same style as the receiver's registers; no separate tool. |

**The transceiver configuration, and where each number comes from.**

| Setting | Value | Source |
|---|---|---|
| IP | `gt_bridge_ip` 1.1 in **bypass (pass-through) mode**, `IP_NO_OF_LANES 2`; `gt_quad_base` 1.1 | Teledyne's `gty_txrx_8lanes_64b.bd` (two quads, eight lanes) reduced to one quad, channels 0–1 |
| Line rate / PLL / refclk | 10.0 Gb/s, LCPLL, 156.25 MHz on refclk R0, TX and RX | Teledyne's `IP_LR0_SETTINGS` string, verbatim (`syn/gt_scratch.tcl` line 24). EV12AQ600 lane rate = 2 × f_CLK = 10 Gb/s at 5 GHz; SSO = f_CLK/32 = 156.25 MHz (§5). |
| Encoding / width | RAW, 64-bit user and internal width, TX and RX **buffer mode** | same string; ESIstream does its own alignment and scrambling, the GT is a bit pipe |
| User clocks | `ch0_txoutclk` and `ch0_rxoutclk` through `bufg_gt`, each feeding the bridge **and all four channels' `usrclk`** | Teledyne's wiring; `validate_bd_design` fails with ch2/ch3 unconnected |
| `REFCLK_STRING` | `HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1` (+ HSCLK1) | Teledyne's; Vivado reduces it to HSCLK0 for two lanes |
| Loopback | quad `ch0_loopback`, `ch1_loopback` = `"010"` near-end PMA, from the register block (default); `"001"` near-end PCS and `"000"` normal available | Versal GTY architecture manual loopback encoding; found on the quad with `gt_scratch.tcl` |
| `apb3clk` | the 100 MHz PL clock | Teledyne: `sysclk` |
| `gtreset_in` | from the register block: once automatically, and on demand | Teledyne: 3-cycle stretch of the board reset |
| `rate_sel`, `reset_*_in` | 0 | Teledyne leaves `rate_sel` = 0 and the four datapath resets undriven |
| Reference clock source | quad 201 refclk0 = AB11/AB10 = SI570_8A34001_MUX_BUF0: user SI570 **U205** via the SI53340 buffer, J306 off (default). Powers up at **100.000 MHz**; program to 156.25 MHz over I2C (address 0x5F) **after every power cycle**. | UG1366 (GTY and clock tables). Tier 3 moves to refclk1 = FMC1_GBTCLK0 (M15/M14), the ADC's SSO, same frequency — the GT configuration does not change. |
| Lane pins | ch0 TX AB7/AB6, RX AB2/AB1; ch1 TX AA9/AA8, RX AA4/AA3 | UG1366 FMC1 table; identical to Teledyne's `tx_rx_esistream_top_64b.xdc` lanes 0/1 |
| Validated by Teledyne | the same package on **FMCP1 (J51)** | Marc, 2026-11-05 |

**Register map, `esi_link_hw` at 0xA403_0000** (byte offsets; also in the file header):

| Offset | Name | Access | Contents |
|---|---|---|---|
| 0x00 | ID | RO | `0x45534931` "ESI1" |
| 0x04 | CONTROL | RW | bit 0 LINK_RESET (hold the link logic in reset); bit 1 SYNC_REQ (write 1: one more sync pulse); bit 2 STATS_CLEAR (write 1); bit 3 GT_RESET (write 1: 8-clock pulse to the bridge); bits 6:4 LOOPBACK (010 default); bit 7 SNAPSHOT (write 1: latch the link-domain counters). The pulse bits read 0. |
| 0x08 | STATUS | RO | 0 gt_powergood, 1 lcpll_lock, 2 tx_resetdone, 3 rx_resetdone, 4 gt_link_status, 5 xcvr_ready, 6 lanes_ready, 7 link_ready, 8 snapshot busy, 9 tx_clk alive, 10 rx_clk alive |
| 0x0C–0x1C | SAMPLES_SENT, SAMPLES_RCVD, SEQ_ERRORS, MARKER_ERRORS, MULTI_ERRORS | RO | snapshot values |
| 0x20, 0x24, 0x28 | TX_CLK_COUNT, RX_CLK_COUNT, ACLK_COUNT | RO | snapshot of the free-running cycle counters; two snapshots give the clock ratios (tx/aclk = 1.5625 when the SI570 is right) |
| 0x2C | LINK_DROPS | RO | times `link_ready` fell since reset |

Why SNAPSHOT: the counters live in the 156.25 MHz domains and advance at up
to 20 MHz; reading them directly from the 100 MHz bus would tear. A write to
SNAPSHOT toggles a request that each link domain synchronizes, latches its
counters on, and acknowledges with a toggle of its own; when both
acknowledgements are back (STATUS bit 8 clears) the latched values are
copied and stable. If a link clock is not running, busy never clears — and
bits 9/10 say which clock.

**Clock-domain crossings, listed** (every one is one of three patterns; the
XDC declares the three clocks asynchronous and nothing else):

| Crossing | Pattern |
|---|---|
| samples, aclk ↔ tx_clk and rx_clk ↔ aclk | `axis_async_fifo` (the receiver's own, already proven) inside packer and reassembler |
| `xcvr_ready`, `sync_req`, `stats_clear`, `link_run` into tx_clk / rx_clk | two-flop synchronizer (`ff_synchronizer_array`, ASYNC_REG) |
| sync pulse tx_clk → rx_clk (4 wide), `lanes_ready` and `release_data` rx_clk → tx_clk | two-flop synchronizer |
| counters → aclk | toggle-handshake snapshot (above) |
| `lanes_ready`, `link_ready`, clock-alive toggles → aclk | two-flop synchronizer |
| Teledyne's own: `sync_in` into `rx_control` (stretched to 4 and resynchronized), `xcvr_ip_ready` into `rx_control` | theirs, unchanged |

**Bring-up sequence, as the hardware will do it** (and as `tb_esi_link_hw`
plays it): PL reset releases → 32 clocks → `gtreset_in` pulse → bridge
sequences the quad → `lcpll_lock`, `tx_resetdone`, `rx_resetdone` →
`xcvr_ready` → 16 `tx_clk` → 4-clock sync pulse to TX and (synchronized) RX
→ Teledyne's RX aligns the two lanes → `lanes_ready` → 16 `rx_clk` →
`release_data` = `link_ready` → the packer starts taking samples from the
pacer. Until then `s_axis_tready` is low and the DMA simply waits: `opv_play`
needs no change. In the bench, `link_ready` is 2.3 µs after reset release
with the stand-in's status schedule; on hardware expect the bridge's reset
sequence to dominate (tens of microseconds).

**Pass criterion (tier 2, hardware):** `opv_play -q`, same command as tier
1: 24/24 decodable on the acceptance stimulus with the §4.1 table, and in the
readbacks `link_ready`, SAMPLES_SENT = SAMPLES_RCVD = the stimulus length
(20,799,760 for the 25-frame file), SEQ/MARKER/MULTI errors 0, LINK_DROPS 0;
`opv_play -l` beforehand shows the clock ratio 1.5625.

**What is not verified yet (2026-11-09):** the Vivado build itself
(`make vck190-project-esi` is the first check — it validates the block design
in minutes without a license); timing at 156.25 MHz through Teledyne's RX;
the generated device-tree label for the link block (`system-user.dtsi`
guesses `esi_link_esi`; confirm from `pl.dtsi` after the first tier-2
import); `tb_esi_link_hw` has run only under nvc in the sandbox, not yet on
chococat; the assumption that PMA loopback closes at 10 Gb/s with the
bridge's default equalization (Teledyne's `INS_LOSS_NYQ 20`, `RX_EQ_MODE
AUTO`). If the link does not come up in PMA mode, `loopback 1` (near-end
PCS, no analog path) splits the question.

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

## 7. Open questions for Teledyne — and the answers (Marc, 2026-11-05)

1. Which slot was the VCK190 package validated in? — **FMCP1 (J51)**, as the
   package's constraints say (GTY201/202, SSO on M15/M14).
2. The user guide for the VCK190 ESIstream package — **there is none**; the
   EVM user guide is the document.
3. f_CLK = 5 GHz (4-channel mode) and the LMX2592 configuration — the
   configuration is in the package's Python: `python/ev12AQ600.py`,
   `external_pll_configuration_5000`.
4. VADJ — Teledyne **used 1.5 V** on the VCK190. The written compatibility
   statement for 1.5 V banks against the card's 1.8 V signals is still
   open; so is whether the BUI override persists across power cycles.
5. The EVM loan — with Todd Weckhurst; pending.

## 8. Next steps

1. Port check: run `xm107/script_64b.tcl` under Vivado 2022.2 untouched
   (scratch dir), log the IP-upgrade complaints. Measures the port cost.
2. ~~Write the reassembler + its bench; frame layout per §4.~~ **Done.**
   Tier 2 in simulation passed and is bit-identical to tier 1 at 3 and 25
   frames (§4.1, 2026-11-08/09). The bench-tail items are in the tracker.
3. ~~Bring `tx_esistream`/`rx_esistream` + the package's transceiver block
   into our block design, board clock on refclk0, internal loopback,
   AXI-Lite control.~~ **Designed and benched 2026-11-09** (§4.2:
   `VCK190_TIER=2`, `esi_link_hw`, `gt_scratch.tcl`). Next: `make
   vck190-project-esi` on chococat, then `make vck190-xsa-esi`.
4. Tier-2 acceptance: `opv_play` unchanged, 24/24 flat, same table as tier 1,
   link counters sent = rcvd, zero errors (`opv_play -q`, dōgu).
5. Downconverter design pass on paper (mode/clock per §5), then its bench,
   then fabric — for tier 3, when the card arrives.
