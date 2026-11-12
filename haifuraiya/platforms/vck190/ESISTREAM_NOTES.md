# ESIstream on the VCK190 — package review and plan

_Status 2026-11-11. Tier 2 — Teledyne's ESIstream over a real GTY pair on
the VCK190, two lanes, 10 Gb/s — passes on hardware and starts itself from
power-on (§4.2). Everything marked **verified** was read from the named
document or measured (Vivado, the benches, the board); everything marked
**estimate** is our arithmetic and still has to be confirmed by Teledyne or
by a measurement. Sections 1–3 are the review as written in October with
the answers folded in; §4 is tier 2 as built; §5–6 are tier 3 as planned._

## 1. Where this sits

Tier 1 (memory loopback: DDR → DMA → pacer → receiver → DMA → DDR) passed on
2026-10-25: 24/24 frames decodable, 0.00–0.56% pre-FEC BER, flat, matching
xsim. The receiver, the Xilinx AXI DMA and the PetaLinux image are the
baseline. The next two tiers put the Teledyne e2v EV12AQ600 ADC's serial
interface in front of the receiver:

- **Tier 2 — digital loopback.** Same `opv_play`, same stimulus, same
  receiver; the ESIstream link spliced into the sample path:
  DDR → DMA → pacer → ESIstream TX → GTY → (loopback) → GTY → ESIstream RX →
  reassembler → receiver → DMA → DDR. No ADC. **Passed** in simulation
  (bit-identical to tier 1, 2026-11-08) and on the board (2026-11-10, and
  self-starting 2026-11-11): 24/24, the tier-1 table, 20,799,760 samples
  through the link with zero errors.
- **Tier 2½ — the card's clock and pins, no card.** The reference moved to
  FMC1 GBTCLK0 (where the ADC's SSO will arrive), driven from the bench;
  then the loopback taken off-chip through the FMC pins. Same image
  otherwise. Not started; §8.
- **Tier 3 — RF loopback.** Opulent Voice transmitter → EV12AQ600 on the
  FMC evaluation module → ESIstream RX → digital downconverter → receiver.
  Waits on the EVM loan (§7).

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
  **We run it at 2 lanes** (the tier-3 lane count: the ADC's 4-channel
  mode, one core, is ASL0/ASL1 = two lanes, §5). `NB_LANES` is a generic
  throughout Teledyne's IP and ours; the link bench ran at 8, 4 and 2 with
  the faulty-lane prediction holding at each (§4.1); the system simulation
  is 2.7 × faster at 2 lanes than at 8; the hardware GT pair is two
  channels of one quad (§4.2).
- **Interfaces we meet:** `rx_esistream.data_out` (per lane 4 × 14 bits),
  `valid_out` per lane, `lanes_ready`; `tx_esistream.data_in` of the same
  shape. The IP does not care what the 14 bits mean.
- **Vivado 2021.1** scripts and block designs; VCK190 board file 2.2 (same as
  ours). The port to 2022.2 did not go through an IP upgrade of Teledyne's
  block design: the GT pair (`gt_bridge_ip` 1.1 in bypass mode,
  `gt_quad_base` 1.1) was rebuilt by hand from their block design's
  settings in a batch script (`syn/gt_scratch.tcl`, §4.2), two lanes
  instead of eight, and placed in our own playback design. Their VHDL
  (`src_rx`, `src_tx`, `src_common`, the package) is used verbatim.
- **No user guide for the package exists** (Marc, 2026-11-05); the EVM user
  guide is the document.

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
had said FMCP2; **answered 2026-11-05: FMCP1 (J51)**, as the constraints
say. Our two lanes are DP0/DP1 = GTY201 channels 0 and 1 (AB7/AB6, AB2/AB1,
AA9/AA8, AA4/AA3), the same pins as the package's lanes 0 and 1.

EVM ↔ FMC pin mapping (EV12AQ600-FMC-EVM user guide, June 2017): the eight
lanes are `DP0..DP7_M2C` = B SL0, B SL1, A SL0, A SL1, D SL0, C SL1, C SL0,
D SL1 (two links per ADC core, link 0 = even samples, link 1 = odd); SSO on
`GBTCLK0_M2C`; ADC/PLL SPI, resets and mode selects on LA pins at 1.8 V;
the card does not use VADJ.

Board clock pins for tier 2 (quad 201 refclk0): **AB11 / AB10**
(MGTREFCLKP0/N0_201) — the user SI570 U205, on the Versal's PMC I2C0 behind
switch U33 channel 6 at 0x5F, set to 156.25 MHz by the Linux device tree at
every boot (§4.2; UG1366 "PMC MIO 46-47 I2C0 Bus").

## 4. Tier 2 design (digital loopback) — as built

- **Reference clock:** the board's user SI570 on GTY201 refclk0 (AB11/AB10),
  programmed to 156.25 MHz **by the Linux kernel from the device tree** at
  every boot (the oscillator is on the Versal's own I2C bus; the System
  Controller, AMD's documented route, was never needed for it). Slot J51 stays
  **empty**. The fabric watches a copy of the reference and resets the
  transceiver when the clock becomes good (§4.2).
- **Loopback:** the transceivers' near-end PMA loopback, selected by a
  register (default). Closed at 10 Gb/s with the bridge's default
  equalization on the first try. No XM107 card.
- **Lanes: two** (§2), on channels 0 and 1 of quad 201.
- **Data path:** the pacer feeds a **packer** (one sample per link clock,
  rotating over the lanes) → `tx_esistream` → GTY → `rx_esistream` → a
  **reassembler** that rebuilds 32-bit I/Q beats for the receiver. Frame
  layout is ours on both ends: one 16-bit I, one 16-bit Q, a valid flag, a
  9-bit marker and a 14-bit sequence number per 56-bit lane slot (4 frames ×
  14 bits), so a lane order or alignment error is counted and scrambles the
  sample order. Lossless: the receiver produces the same grade table as
  tier 1 (it does, to the bit). The ADC's 12-bit format is **not** imitated
  here — the ADC never quantizes our baseband; the downconverter hands the
  receiver its samples (§5).
- **Clock domains:** 100 MHz (DMA/pacer/receiver/registers), the GT's TX
  and RX user clocks (156.25 MHz each, unrelated phase), and the reference
  copy; two async FIFOs for the samples, two-flop synchronizers and a
  toggle handshake for everything else (§4.2 lists every crossing). The
  receiver is consume-on-arrival and never knows the link exists.
- **Control:** the package's UART/register-map/Python GUI replaced by one
  AXI-Lite register block on our control plane (0xA403_0000: status,
  scoreboard, loopback mode, resets, the clock monitor), read by dōgu's
  `opv_play` and nothing else.
- **Order of work, as it happened:** the package's own link bench under nvc
  (and GHDL); the splice in the system bench, 3 and 25 frames, against tier
  1; the hardware wrapper's unit test; the build; the board.

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

### 4.2 Tier 2 in hardware — the design (2026-11-09) and the pass (2026-11-10)

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
| `rtl/esi/esi_link_hw.vhd` | The block-design module: `esi_link_loop(IDEAL_LINK => false, 2 lanes)` + GTY glue + AXI-Lite registers + the reference-clock monitor. Flat ports only (module references cannot take arrays). The bridge's data ports are 128 bits per channel; bits 63:0 carry the word, as in Teledyne's `tx_rx_xcvr_wrapper_64b`. `xcvr_ready = lcpll_lock and tx_resetdone and rx_resetdone` (Teledyne's `ip_ready`; the lock is the quad's `hsclk0_lcplllock`). The transceiver is reset once each time the reference clock becomes good ("the qualified reset", below). Register map in the file header and below. |
| `sim/esi/tb_esi_link_hw.vhd`, `run_esi_link_hw_nvc.sh`, `run_esi_link_hw_ghdl.sh` | **Unit test** for the wrapper with a stand-in transceiver (4-cycle delay line in `tx_clk`, re-registered in an `rx_clk` of the same frequency and a different phase; GT status lines come up on a schedule after `gt_reset`). Three real clock domains. Checks: the automatic `gt_reset`; `link_ready` and both clock-alive bits; 2000 samples through at one per 5 `aclk`, identical and in order; SNAPSHOT counters (sent = rcvd = 2000, errors 0) and the measured `tx_clk/aclk` ratio (1.5625061 over 10231 `aclk`); a split-phase AXI-Lite write (W three cycles before AW) completes; SYNC_REQ brings the link back (`LINK_DROPS` = 1). **PASS** (nvc in the sandbox, 2026-11-09; not yet run on chococat). Run: `sim/esi/run_esi_link_hw_nvc.sh`, pass = `PASS: tb_esi_link_hw`. |
| `syn/gt_scratch.tcl` | The derivation, reproducible: builds the two-lane GT pair **by hand** from Teledyne's `gty_txrx_8lanes_64b.bd` in a scratch block design (no block automation — the 2022.2 rule names for the bridge are not public), validates it, and dumps every pin of every cell to `gt_2lanes_pins.txt` and the design to `gt_2lanes_bd.tcl`. That dump is where `ch0_loopback`..`ch3_loopback` were found on the quad and where the bridge's `chN_txdata_ext`/`chN_rxdata_ext` names come from. `validate_bd_design: OK` on chococat, 2026-11-09 (third attempt: v1 used automation rules that do not exist; v2 left `ch2/ch3` user clocks unconnected and the quad insists on all four). |
| `syn/vck190_playback_bd.tcl` §4t | The same cells and wires as `gt_scratch.tcl`, in the playback design, when `tier == 2`; the splice; `smartconnect` M03 → `esi/s_axi`; `assign_bd_address` 0xA403_0000; everything grouped into the `esi_link` hierarchy. |
| `syn/vck190_playback_project.tcl` | `VCK190_TIER=2` in the environment adds the 23 ESIstream/esi sources (the sim runner's list plus `esi_link_hw.vhd`) and the constraints file, names the project `mdt_vck190_playback_esi`, and writes `timing_summary_esi.rpt` / `utilization_esi.rpt` / `mdt_vck190_playback_esi.xsa`. Tier 1 is untouched (and its manifest no longer lists the deleted `axi_mon_tap.vhd`, which had made `make vck190-project` fail the 36-file count). |
| `syn/vck190_esi_link.xdc` | Refclk pins AB11/AB10 + `create_clock -period 6.400`; lane pins for quad 201 ch0/ch1 (= FMC1 DP0/DP1, Teledyne's lanes 0/1); `set_clock_groups -asynchronous` between `clk_pl_0` and the two BUFG_GT clocks (`PROCESSING_ORDER LATE` so the GT IP's clock names exist). |
| `vck190.mk` | `make vck190-project-esi` (BD only, minutes) and `make vck190-xsa-esi` (the bitstream); separate project directory, XSA, reports and log. |
| `petalinux/system-user.dtsi` | Two things. The link block as a generic-uio device (label `esi_link_esi`, confirmed from the generated `pl.dtsi` 2026-11-10 — note the kernel numbers UIO devices in device-tree order, so on the tier-2 image the link is `/dev/uio0` and the receiver `/dev/uio1`; `opv_play` finds both by name). And the **GT reference clock**: a `clk-si570` node for the board's user SI570 (U205) on PMC I2C0 (`i2c2`) behind TCA9548A U33 channel 6 at 0x5F, `clock-frequency = <156250000>` — the kernel programs the oscillator at every boot (`si570 9-005f: registered, current frequency 156250000 Hz`), so the clock is part of the image. |
| `sim/logs/hw_tier2_20261110_2325.txt`, `hw_tier2_20261110_2311_linkup.txt` | The console transcripts of the first hardware pass: the playback with `-q` and the grade table (Michelle's capture), and the link-up before it — the `dmesg` clock lines, the UIO names, `opv_play -l` before the reset and `-r` after. |
| dōgu `tools/opv_play` | The one place the link's registers are read (patch `dogu_opv_play_esi.patch`, 2026-11-10): refuses to play until `link_ready`; `-q` adds the link scoreboard to the readbacks; `-l` reads the link alone, including the transceiver clock against the PL clock. Same style as the receiver's registers; no separate tool. |

**The transceiver configuration, and where each number comes from.**

| Setting | Value | Source |
|---|---|---|
| IP | `gt_bridge_ip` 1.1 in **bypass (pass-through) mode**, `IP_NO_OF_LANES 2`; `gt_quad_base` 1.1 | Teledyne's `gty_txrx_8lanes_64b.bd` (two quads, eight lanes) reduced to one quad, channels 0–1 |
| Line rate / PLL / refclk | 10.0 Gb/s, LCPLL, 156.25 MHz on refclk R0, TX and RX | Teledyne's `IP_LR0_SETTINGS` string, verbatim (`syn/gt_scratch.tcl` line 24). EV12AQ600 lane rate = 2 × f_CLK = 10 Gb/s at 5 GHz; SSO = f_CLK/32 = 156.25 MHz (§5). |
| Encoding / width | RAW, 64-bit user and internal width, TX and RX **buffer mode** | same string; ESIstream does its own alignment and scrambling, the GT is a bit pipe |
| User clocks | `ch0_txoutclk` and `ch0_rxoutclk` through `bufg_gt`, each feeding the bridge **and all four channels' `usrclk`** | Teledyne's wiring; `validate_bd_design` fails with ch2/ch3 unconnected |
| `REFCLK_STRING` | `HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1` (+ HSCLK1) | Teledyne's; Vivado reduces it to HSCLK0 for two lanes |
| Loopback | quad `ch0_loopback`, `ch1_loopback` = `"010"` near-end PMA, from the register block (default); `"001"` near-end PCS and `"000"` normal available | Versal GTY architecture manual loopback encoding; found on the quad with `gt_scratch.tcl`. PMA loopback closed at 10 Gb/s with the bridge's default equalization, first try (2026-11-10). |
| PLL lock | the **quad's** `hsclk0_lcplllock` (HSCLK0 is the PLL the two lanes use) — not the bridge's `lcpll_lock_out`, which never asserted in bypass mode on the board | Teledyne's wrapper: `lcpll_lock <= hsclk0_lcplllock_0 and ...`; measured 2026-11-10 (resetdone high, user clocks at 1.5625 × PL clock, `lcpll_lock_out` low) |
| `apb3clk` | the 100 MHz PL clock | Teledyne: `sysclk` |
| `gtreset_in` | from the register block: once automatically, and on demand | Teledyne: 3-cycle stretch of the board reset |
| `rate_sel`, `reset_*_in` | 0 | Teledyne leaves `rate_sel` = 0 and the four datapath resets undriven |
| Reference clock source | quad 201 refclk0 = AB11/AB10 = SI570_8A34001_MUX_BUF0: user SI570 **U205** via the SI53340 buffer, J306 off (default). Powers up at **100.000 MHz**; **Linux sets it to 156.25 MHz at every boot** from the device tree (U205 is on the Versal's PMC I2C0, `i2c2`, behind TCA9548A U33 channel 6, address 0x5F). The fabric's power-up transceiver reset runs before Linux does this, so one more transceiver reset is needed after boot (`opv_play -r`) until the block retries by itself. | UG1366 "PMC MIO 46-47 I2C0 Bus" table; the System Controller's `VCK190.json` (`SI570_USER1_FMC`, default 100 MHz). Measured 2026-11-10: `tx_clk/aclk` = 1.5625. Tier 3 moves to refclk1 = FMC1_GBTCLK0 (M15/M14), the ADC's SSO, same frequency — the GT configuration does not change. |
| Lane pins | ch0 TX AB7/AB6, RX AB2/AB1; ch1 TX AA9/AA8, RX AA4/AA3 | UG1366 FMC1 table; identical to Teledyne's `tx_rx_esistream_top_64b.xdc` lanes 0/1 |
| Validated by Teledyne | the same package on **FMCP1 (J51)** | Marc, 2026-11-05 |

**Register map, `esi_link_hw` at 0xA403_0000** (byte offsets; also in the file header):

| Offset | Name | Access | Contents |
|---|---|---|---|
| 0x00 | ID | RO | `0x45534931` "ESI1" |
| 0x04 | CONTROL | RW | bit 0 LINK_RESET (hold the link logic in reset); bit 1 SYNC_REQ (write 1: one more sync pulse); bit 2 STATS_CLEAR (write 1); bit 3 GT_RESET (write 1: 8-clock pulse to the bridge); bits 6:4 LOOPBACK (010 default); bit 7 SNAPSHOT (write 1: latch the link-domain counters). The pulse bits read 0. |
| 0x08 | STATUS | RO | 0 gt_powergood, 1 lcpll_lock, 2 tx_resetdone, 3 rx_resetdone, 4 gt_link_status (the bridge's, for its protocol modes; stays 0 in bypass mode and means nothing here), 5 xcvr_ready, 6 lanes_ready, 7 link_ready, 8 snapshot busy, 9 tx_clk alive, 10 rx_clk alive, 11 refclk_valid. A healthy tier-2 link reads 0xEEF (0x6EF before the monitor, 2026-11-10). |
| 0x0C–0x1C | SAMPLES_SENT, SAMPLES_RCVD, SEQ_ERRORS, MARKER_ERRORS, MULTI_ERRORS | RO | snapshot values |
| 0x20, 0x24, 0x28 | TX_CLK_COUNT, RX_CLK_COUNT, ACLK_COUNT | RO | snapshot of the free-running cycle counters; two snapshots give the clock ratios (tx/aclk = 1.5625 when the SI570 is right) |
| 0x2C | LINK_DROPS | RO | times `link_ready` fell since reset |
| 0x30 | REFCLK_PERIOD | RO | PL clocks per 1024 reference clocks: 655 at 156.25 MHz, 1024 at 100 MHz, 4095 = no clock |
| 0x34 | REFCLK_GOOD_EVENTS | RO | times the reference clock became good = automatic transceiver resets issued (1 after a normal boot) |

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

**Bring-up sequence** (as `tb_esi_link_hw` plays it and as the board did
it): PL reset releases → 32 clocks → `gtreset_in` pulse → bridge sequences
the quad → `lcpll_lock`, `tx_resetdone`, `rx_resetdone` → `xcvr_ready` → 16
`tx_clk` → 4-clock sync pulse to TX and (synchronized) RX → Teledyne's RX
aligns the two lanes → `lanes_ready` → 16 `rx_clk` → `release_data` =
`link_ready` → the packer starts taking samples from the pacer. Until then
`s_axis_tready` is low and the DMA simply waits: `opv_play` needs no change.
On the board there was one wrinkle (2026-11-10): the block's `gtreset_in`
pulse came at a fixed time after PL reset, before Linux had programmed the
SI570, so the PLL saw 100 MHz and did not lock; the sequence completed
after one more reset once the clock was right (`opv_play -r`: `-l` →
STATUS 0x001, `-r` → 0x6EF within its 500 ms wait).

**The qualified reset (2026-11-11, in the next build).** The transceiver's
reset is not issued at a time; it is issued when the thing it depends on
is true. The block gets a fabric copy of the reference clock (the
IBUFDS_GTE5's ODIV2 output through one more BUFG_GT — ODIV2 is the
reference itself with the primitive's default `REFCLK_HROW_CK_SEL = 0`,
AM002) and a monitor: a toggle every 1024 reference cycles, timed in PL
clocks; 655 ± 17 means 156.25 MHz. `refclk_valid` asserts after 8
consecutive good windows (52 µs) and clears on 2 bad ones or no clock at
all; **one** `gtreset_in` pulse is issued on each rising edge of
`refclk_valid`. One reset per "clock became good" event, none if it never
does, no retry timer. `tb_esi_link_hw` now starts its reference at 100 MHz,
switches it at 80 µs the way Linux does, and checks: no reset and
REFCLK_PERIOD 1024 before; exactly one reset, `refclk_valid`,
REFCLK_PERIOD 656 and link-up after; then drops the reference and brings it
back — `link_ready` falls, a second reset, REFCLK_GOOD_EVENTS 2, link back.
PASS (nvc, 2026-11-11). **On the board, 2026-11-11 15:52** (commit
`8302671`, dōgu `debe311`; `sim/logs/hw_tier2_20261111_1552.txt`):
`opv_play -l` straight after boot, nothing touched — STATUS 0xEEF,
`refclk_valid`, REFCLK_PERIOD 655, REFCLK_GOOD_EVENTS 1, link_ready; then
the playback: 24/24 decodable with the same per-frame table as 2026-11-10
to the last digit, sent = received = 20,799,760, zero link errors. Tier 2
needs nothing manual between power-on and a passing run.

**Pass criterion (tier 2, hardware):** `opv_play -q`, same command as tier
1: 24/24 decodable on the acceptance stimulus with the §4.1 table, and in the
readbacks `link_ready`, SAMPLES_SENT = SAMPLES_RCVD = the stimulus length
(20,799,760 for the 25-frame file), SEQ/MARKER/MULTI errors 0, LINK_DROPS 0;
`opv_play -r` beforehand shows STATUS 0x6EF and the clock ratio 1.5625.

**PASS, 2026-11-10 23:25** (transcript: `sim/logs/hw_tier2_20261110_2325.txt`;
commit `8f1d612`, dōgu `1e988cd`):

| Measured | Tier 1, 2026-10-25 | Tier 2, 2026-11-10 |
|---|---|---|
| Grade | 24/24 decodable, pre-FEC BER 0.00–0.56 %, flat | 24/24 decodable, pre-FEC BER 0.00–0.56 %, flat |
| CFO estimate (500 Hz injected) | not recorded | 498 Hz, quality 6763 |
| SYM_CLK_OFFSET (11.5 ppm injected) | not recorded | −2203 Q24 = −11.39 ppm (simulation: −2254; the sign is the stimulus's — it stretches the waveform, so the symbol clock is slow) |
| Frames received / soft bits dropped | 24 / 0 | 24 / 0 |
| ESI samples sent / received | — | 20,799,760 / 20,799,760 |
| ESI sequence / marker / multi-lane errors, link drops | — | 0 / 0 / 0, 0 |
| `tx_clk` / PL clock | — | 1.5625 (over 20,006,224 PL clocks) |
| STATUS | — | 0x6EF (everything but bit 4, the bridge's protocol-mode link status) |

The build that did it: `make vck190-project-esi` validated first try (the
expected warnings plus six `BD 41-1306` for the per-pin connections to the
bridge's grouped interfaces — intended, Teledyne's design does the same —
and two cosmetic clock-interface notes for `tx_clk`/`rx_clk`);
`make vck190-xsa-esi` met timing: `clk_pl_0` WNS 0.374 ns (tier 1: 0.546),
`ch0_txoutclk` 2.295 ns and `ch0_rxoutclk` 2.013 ns at 6.400 ns, no
inter-clock paths (the clock groups), `check_timing` with no unconstrained
endpoints; synthesis 1:20, place 19:40, route 14:16; one GTYE5 quad of 11,
DSP 77.95 % (unchanged), LUT 16.6 %, block RAM 17.1 %.

**Three things the board taught that the benches could not** (each fixed
in `8f1d612` / dōgu, each measured; the user guide's "Things that bit us"
has the detail): the UIO numbering order; the SI570 at 100 MHz with the
System Controller's console dark (the device-tree route above replaced it);
and the bridge's `lcpll_lock_out` never asserting in bypass mode (the quad's
`hsclk0_lcplllock` is the signal, as in Teledyne's wrapper).

**Unit Tests Passed** the two unit tests have run on chococat under two 
independent simulators there: nvc 1.24 and GHDL 4.1 (`run_esi_link_ghdl.sh`, 
`run_esi_link_hw_ghdl.sh`, 2026-11-11) and they agree on every reported 
event to the picosecond (link-up 348.4 ns, the qualified reset at 
133.695 µs and 357.825 µs, 750 faulty-lane errors).

Ubuntu 22.04's `ghdl` package is 1.0 and too old for the 2008 features
these benches use; the release tarball from github.com/ghdl/ghdl is the
way on chococat. **Closed:** the qualified reset — built, booted and
measured 2026-11-11 (above); `i2cdetect` — it is in the image at
`/usr/sbin/i2cdetect`, the "not found" was a non-interactive `ssh` PATH.
**Decided:** `system.xsa` stays in git, so a clone can
reproduce the board without rebuilding the design. **The System
Controller** (its console was dark on 2026-11-10): running after all —
reached over Ethernet on 2026-11-11, §6. Not needed for tier 2; needed for
tier 3's VADJ, and now in hand.

## 5. Tier 3 operating point (ADC)

Candidate, with sources:

| Item | Value | Status |
|---|---|---|
| Mode | 4-channel (single core per input), **channel A only** | verified: datasheet §8 modes; chosen for no interleaving spurs, 2 lanes, 8 samples/clock |
| f_CLK | **5 GHz** | verified: datasheet "Performance vs F_clock" (p. 119) covers 5 GHz, flat; LMX2592 VCO fundamental 3.55–7.1 GHz (TI datasheet) — direct output, no doubler/divider; Teledyne ships the configuration (`external_pll_configuration_5000`, §7) |
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

Physical: card in **J51** (confirmed, §7), SSO on GTY201 refclk1 (M15/M14);
the tier-2 image changes only the reference-clock pair (the quad's
`REFCLK_STRING` and two XDC lines) — and the clock monitor already handles a
reference that arrives late, which the ADC's SSO will. Teledyne's 5 GHz
LMX2592 configuration exists in the package's Python
(`python/ev12AQ600.py`, `external_pll_configuration_5000`; §7).

## 6. VADJ / System Controller (UG1366; measured 2026-11-11)

The VADJ_FMC rail (0 / 1.2 / 1.5 V) powers the FPGA's FMCP banks 706–708 and
both slots' VADJ pins; the System Controller sets it. UG1366 says it reads
the card's IPMI EEPROM at power-on and sets **0 V** if it finds no value it
can supply; the EVM's logic is 1.8 V and does not use VADJ — hence
Teledyne's "you must force VADJ to 1.5 V from the carrier".

**Measured 2026-11-11, both FMC slots empty:** BEAM's power page reads
`VADJ_FMC 1.5075 V, 0.0012 A` — **1.5 V is this board's power-up default**,
not 0 V. BEAM's VADJ_FMC control offers 0.0 / 1.2 / 1.5 V, each as
"current" and as "set on boot"; **"set on boot" did not do what its name
says**: set to 1.5 and then to 1.2, a power cycle brought "current" back
to 1.5 V and "set on boot" back to 0.0 each time. With empty slots the
controller puts the rail at 1.5 V at every power-up regardless. So, for
tier 3: card in J51, power on, read `VADJ_FMC` on BEAM; if it is not 1.5 V
(the controller may act on the card's EEPROM), set 1.5 V as "current" and
read again — and if that has to be repeated after every power cycle, it
is one `sc_app` command over `ssh` (`sc_app -h` lists the VADJ command)
that belongs in dōgu's tier-3 bring-up next to the ADC configuration. A
measurement each time, not an act of faith. The EVM guide's §3.2 order
(carrier on → card power on) still applies.

**The System Controller itself** (the board's separate Zynq UltraScale+,
its own Linux on the microSD card in its own slot, boot-mode switch SW11
as UG1573's setup figure shows — both as shipped): it was running all
along; only its serial console never answered. Reached 2026-11-11 over
Ethernet: first back-to-back with chococat (UG1573's procedure), then on
the lab network by DHCP (10.73.1.103 that evening; a static address is
being set, Paul). **BEAM** is the web page at `http://<its address>:50002`
— clocks, power rails (every INA226 on the board, VADJ_FMC among them),
FMC settings; **`ssh`** to the same address works (login: the image's
`petalinux` user; password as Paul set it). The serial console on the
USB-UART (`ttyUSB3` by the channel order) stayed silent with the
controller demonstrably running — unexplained, and no longer needed.
Which RJ45 jack carries it: the one in UG1573's setup photo; with that one
cable both the Versal (10.73.1.17) and the controller are on the lab
network — J-number to be read off the board (TODO).

Electrical question for Teledyne: the card's signals toward the FPGA are
1.8 V into 1.5 V banks, and the FPGA drives 1.5 V swings into the card's 1.8 V
inputs (SPI, reset, selects). Teledyne called the combination compatible and
**used 1.5 V on their VCK190** (2026-11-05); we still want the statement in
writing since the risk is the FPGA's banks.

(2026-11-10's note here said the controller was not running and its card
slot empty. That was an inference from a silent console, stated as fact,
and wrong: the card that shipped with the board is in the slot and boots.
Corrected 2026-11-11.)

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
   open. Persistence: BEAM's "set on boot" does not persist (measured
   2026-11-11, §6); the power-up default is 1.5 V with the slots empty,
   and the card-in reading decides.
5. The EVM loan — with Todd Weckhurst; **to ask for now** (2026-11-11), with
   the tier-2 result as the case: their package on a VCK190 at the ADC's
   rate and encoding, two lanes, self-starting, bit-exact.

## 8. Next steps

1. ~~Port check: run `xm107/script_64b.tcl` under Vivado 2022.2.~~
   **Superseded**: the GT pair was rebuilt by hand under 2022.2 from the
   block design's settings (§2, §4.2); Teledyne's scripts were never run.
2. ~~Write the reassembler + its bench; frame layout per §4.~~ **Done.**
   Tier 2 in simulation passed and is bit-identical to tier 1 at 3 and 25
   frames (§4.1, 2026-11-08/09). The bench-tail items are in the tracker.
3. ~~Bring `tx_esistream`/`rx_esistream` + the package's transceiver block
   into our block design, board clock on refclk0, internal loopback,
   AXI-Lite control.~~ **Designed and benched 2026-11-09, built and
   brought up 2026-11-10** (§4.2).
4. ~~Tier-2 acceptance: `opv_play` unchanged, 24/24 flat, same table as tier 1,
   link counters sent = rcvd, zero errors.~~ **PASS 2026-11-10** (§4.2).
4a. ~~The link block retries the transceiver reset~~ The link block resets
   the transceiver when its reference clock becomes good (§4.2, "the
   qualified reset"): designed, benched, **built and passed on the board
   2026-11-11**. No manual step remains in tier 2.
5. **Tier 2½, part 1 — the card's reference clock.** Move the quad's
   reference to refclk1 = FMC1 GBTCLK0 (M15/M14) and drive it from the
   bench (the board's 8A34001 through the FMC clock path, or a signal
   generator into the FMC); the loopback stays internal. Proves the
   reference path the ADC's SSO will use, and the monitor's handling of a
   clock that arrives whenever the source is switched on. Small change:
   `REFCLK_STRING`, two XDC lines, the user guide.
6. **Tier 2½, part 2 — the serial path off-chip.** Loopback mode 0 and a
   physical TX→RX loop on the FMC pins (an XM107 card, or SMA cabling on a
   breakout). Proves the equalization and the pins with a real channel.
7. **Tier 3 prerequisites, no card needed:** ~~the System Controller
   running~~ (it is; BEAM and `ssh`, §6), a fixed address for it (Paul,
   in hand — a static address, 2026-11-11); the
   downconverter design pass on paper (mode/clock per §5), then its bench.
8. **The EVM loan** (§7 item 5): ask now.
9. Tier 3: card in J51, VADJ 1.5 V, SPI bring-up with the package's
   register map, ramp test mode first, then the downconverter, then
   Opulent Voice.
