# VCK190 Memory Loopback Plan

_Open Research Institute, 2026-10-23. Status: **PASS** on hardware 2026-10-25._

## Loopback Tests

| Tier | What is in the loop | Needs | Pass/fail | Status |
|---|---|---|---|---|
| **1. Memory loopback** (this plan) | DDR → DMA → pacer → receiver → DMA → DDR. No converter interface at all. | VCK190, Vivado 2022.2, PetaLinux 2022.2 | `grade_payload_ber.py` on the captured soft bits matches the xsim table | **PASS** 2026-10-25: 24/24 frames decodable, pre-FEC BER 0.00–0.56 %, flat |
| 2. Digital loopback | The ESIstream serial path spliced into tier 1: DDR → DMA → pacer → packer → ESIstream TX → link → ESIstream RX → reassembler → receiver → DMA → DDR. The link is a transceiver quad in internal near-end loopback (no card in the slot) or, in simulation, the TX words wired straight to the RX. | Teledyne ESIstream VCK190 package (public domain, vendored); the board's own 156.25 MHz reference clock. **No ADC card.** | Same stimulus, same `opv_play`, same grade as tier 1, plus the link's own counters at zero (every sample sent was received, in order). | **Simulation PASS 2026-11-09**: 25/25, byte-identical soft symbols to tier 1 (`ESISTREAM_NOTES.md` §4.1). **Hardware PASS 2026-11-10**, and again **2026-11-11** with the fabric timing its own transceiver reset (no manual step from power-on to pass): 24/24, pre-FEC BER 0.00–0.56 %, the same table as tier 1 both days; 20,799,760 samples sent = received through the GTY loopback, zero link errors (§4.2; `sim/logs/hw_tier2_2026111*.txt`). |
| 3. RF loopback | The Opulent Voice transmitter, on the air or by cable, into the EV12AQ600 ADC → ESIstream RX → digital downconverter → receiver. | Teledyne EV12AQ600 FMC+ evaluation module (on loan, pending), the downconverter (new fabric block) | As the ZCU102's RF loopback | Operating point chosen on paper (`ESISTREAM_NOTES.md` §5); card not yet in hand |

Tier 1 is the ZCU102's "digital loopback" taken one level deeper: there is not even a serial link in it, and it is the only tier whose pass criterion was defined to the bit before it ran. Tier 2 changes exactly one thing — the samples travel over the link — and keeps the pass criterion. The ESIstream plan, package review and tier-2/3 details live in `ESISTREAM_NOTES.md`; this file is tier 1 and the table above.

## What it is, in one sentence

The receiver exactly as simulated, running in the VCK190's programmable
logic, fed the same stimulus file from DDR at the ADC sample rate, with its
soft bits written back to DDR and graded by the same script as the
simulation.

## Why this first

- It reproduces the acceptance test (25 frames, 11.5 ppm, +500 Hz, Eb/N0
  10 dB) on silicon with no FMC, no ADC, no radio. Pass/fail is the same
  `grade_payload_ber.py` table.
- Everything new on Versal — CIPS, NoC, DDR, the PL control plane, the
  PetaLinux image — gets exercised with a known-good data path. When the
  Teledyne ESIstream front end arrives, only the source of samples changes.
- The ZCU102 stays untouched; this lives entirely under `platforms/vck190/`.

## Domain model

| Thing | Where it lives | Contract |
|---|---|---|
| Stimulus | DDR, written by the A72 from `opv_chan_stim.bin` (the sim's `opv_chan_stim.txt` converted by `tools/opv_stim_txt2bin.py`) | int16 I/Q pairs packed as one 32-bit beat (I low half, Q high half — the AXIS convention `haifuraiya_channelizer_axi` already uses); 20 MSps; 1.04 s = 20.8 M beats = 83 MB |
| Pacing | `axis_sample_pacer` (`platforms/vck190/rtl/`) | one beat per `period` clocks (5 at 100 MHz = 20 MSps), DMA held off in between; the hardware form of the bench's `SMP_PERIOD` |
| Receiver | `haifuraiya_rx_axi` (unchanged, module reference) | `aclk` 100 MHz; `s_axis_data` consume-on-arrival; two AXI-Lite slaves (ctrl, demod) with the published register maps; `m_axis_soft_bit` 3-bit + TLAST per frame |
| Soft bits | `axis_softbit_widen` (ZCU102 file, read-only reuse) → DMA S2MM | one byte per soft bit, 0..7, the layout `opv-decode -3` and the graders read |
| DMA | Xilinx `axi_dma` 7.1, scatter-gather, 64-bit addressing, **status/control stream off** (`c_sg_include_stscntrl_strm 0`) | MM2S 32-bit, S2MM 8-bit; SG so an 83 MB playback streams across descriptors without a gap |
| Control | CIPS `M_AXI_FPD` → SmartConnect → DMA lite, rx ctrl, rx demod | 0xA400_0000 DMA, 0xA401_0000 ctrl, 0xA402_0000 demod (fixed at `assign_bd_address` time; the device tree and `opv_play` use these) |
| Clock/reset | CIPS `pl0_ref_clk` 100 MHz, `pl0_resetn` → `proc_sys_reset` | one clock domain in the PL, same as the simulation |
| Software | PetaLinux 2022.2 on the A72s, machine `versal-vck190-reva` | DMA via the kernel `xilinx_dma` driver through Xilinx's `dma-proxy` module; registers via UIO; client is `opv_play` in dōgu |

Nothing in the receiver changes. The two new blocks are the pacer (verified,
`sim/tb_axis_sample_pacer.vhd`, runner `sim/run_axis_sample_pacer_nvc.sh`,
4/4 pass under nvc) and the block design itself.

## Files (all additive, all under `platforms/vck190/`)

```
rtl/axis_sample_pacer.vhd              the pacer
rtl/axis_softbit_tap.vhd               native ILA tap on the soft-bit stream (debug build only)
sim/tb_axis_sample_pacer.vhd           its bench
sim/run_axis_sample_pacer_nvc.sh       its runner
sim/run_mdt_vck190_sim.tcl             xsim runner: core + shared bench on the VC1902 (tier 1)
syn/vck190_playback_bd.tcl             block design
syn/vck190_playback_project.tcl        project, wrapper, build, .xsa
syn/timing_summary.rpt, utilization.rpt   from the last `make vck190-xsa`
vck190.mk                              make targets (included by the top-level Makefile)
petalinux/                             PetaLinux project (tracked: config.project, project-spec/), dma-proxy recipe, system-user.dtsi, README.md
tools/opv_stim_txt2bin.py              sim stimulus text -> the binary opv_play loads
tools/opv_soft_bin2txt.py              captured soft bytes -> the text the graders read
VCK190_PLAYBACK_PLAN.md                this file
VCK190_USER_GUIDE.md                   the procedure, step by step, with what bit us
ESISTREAM_NOTES.md                     tiers 2 and 3: the ESIstream package, pins, operating point, status
```

Client side (dōgu repo): `tools/opv_play/` and `make deploy-vck190`.

## Build procedure (chococat)

The step-by-step procedure, with the things that bit us, is in
`VCK190_USER_GUIDE.md`. In short: `make vck190-project` (block design,
minutes, no license) → `make vck190-xsa` (synthesis to .xsa, licensed) →
`make vck190-import-xsa` → `make vck190-build` → power cycle, wait 30 s →
`make vck190-boot` → `make deploy-vck190` from dōgu → `opv_play` on the
board → `grade_payload_ber.py` on chococat.

Doctrine check before synthesis: the sim already passed on this RTL
(25/25, 8/8). The pacer has its own bench. The BD has no bench; its
correctness is `validate_bd_design` plus the hardware test. **Done.**

## Acceptance reference (simulation, 2026-11-09)

Stimulus: `opv_stim.py --preamble --clock-offset-ppm 11.5 --fc 781250
--carrier-offset 500 --ebn0 10 --seed 1 --frames 25`, md5
`6088c57b03b048abab52b8cd29fdd867`, 20,799,760 samples. Bench with the
first-sample fix. Archive `sim/logs/tb_haifuraiya_channelizer_axi_20261108_2122/`.

| frame | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| BER % | 0.42 | 0.47 | 0.19 | 0.00 | 0.19 | 0.37 | 0.09 | 0.09 | 0.28 | 0.09 | 0.19 | 0.19 | 0.19 |

| frame | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| BER % | 0.37 | 0.19 | 0.19 | 0.19 | 0.56 | 0.09 | 0.09 | 0.28 | 0.09 | 0.09 | 0.19 | 0.37 |

25/25 decodable, all polarity +. The tier-2 (ESIstream digital loopback)
simulation of 2026-11-04 produced a byte-identical `soft_raw.txt`, so this
is tier 2's table as well. Tables recorded before 2026-11-08 were computed
with the bench's first sample dropped and differ slightly.

## Acceptance, tier 2 (hardware, measured 2026-11-10)

- Same stimulus, same `opv_play -q`, same grader, the tier-2 image
  (`make vck190-xsa-esi`, commit `8f1d612`): **24/24 decodable, pre-FEC BER
  0.00–0.56 %, flat** — the tier-1 table. CFO 498 Hz, SYM_CLK_OFFSET
  −11.39 ppm (simulation −2254 Q24 = −11.6 ppm), 24 frames, 0 dropped.
- Link scoreboard: ESI_SAMPLES_SENT = ESI_SAMPLES_RCVD = 20,799,760;
  sequence, marker, multi-lane errors 0; link drops 0; `tx_clk` / PL clock
  1.5625.
- 2026-11-11, build `8302671`: the link block resets the transceiver when
  it sees the reference clock reach 156.25 MHz; `opv_play -l` straight
  after boot reads 0xEEF, REFCLK_GOOD_EVENTS 1; same 24/24 table. No manual
  step from power-on to a passing run.

## Acceptance, tier 1 (hardware, measured 2026-10-25)

- `opv_play` on `opv_chan_stim.bin` (25-frame, 11.5 ppm, +500 Hz, seed 1):
  `grade_payload_ber.py` **24/24 decodable, pre-FEC BER 0.00–0.56 %, flat**,
  the same shape as the xsim table.
- The receiver locked on the very first run (frame sync, symbol lock,
  carrier readbacks all sane); what did not work was the DMA capture, see
  below.
- Two-burst file: not yet run on hardware.

## Decisions taken

- **Keep the 2:1 halfband (20 MSps in, 10 MSps to the channelizer).** It exists because the ADRV9002 profiles delivered 20 MSps; the VCK190 has no such constraint, and the Teledyne digital downconverter will need a final decimating filter anyway, which may make the halfband redundant. But removing it would change the device under test and the stimulus at the same time as moving to silicon. Tier 1 confirms the receiver that passed in simulation (`SMP_PERIOD = 5`, the existing stimulus files). Dropping the halfband is its own later test: `opv_stim.py --fs 10e6`, pacer period 10, sim at `SMP_PERIOD = 10`, then the board — a tier-3 decision made with the ADC clock plan in hand (`ESISTREAM_NOTES.md` §5: at 1.25 GSps core rate, ÷125 lands on 10 MSps directly). Note for that design: at 10 MSps the channelizer input is a full 10 MHz with no guard, so the downconverter's last filter must provide the transition band the halfband provides today.
- **PetaLinux 2022.2, not pure Yocto**, as on the ZCU102: 2022.2 is the Vivado the floating license covers and the version the ADI reference design needs; the Versal part is not in the free edition's device list (Vivado itself is the authority on that).
- **Xilinx `axi_dma` + `dma-proxy`**, not ADI `axi_dmac` + IIO, because the VCK190 build is from scratch without the ADI library. Swapping is two cells in the block design if reusing `dma_listen` unchanged turns out to matter more.
- **ILA style: native probes on plain nets** (`rtl/axis_softbit_tap.vhd`), not Vivado's AXI-Stream interface monitors, which failed to elaborate here (TKEEP/TDEST absent). The one exception taken was an AXI memory-mapped interface monitor on the DMA's descriptor and S2MM write ports, for the one-off DMA investigation.

## What the hardware taught us (2026-10-24/25)

- **DMA receive stalled with the data already in DDR.** The Xilinx `axi_dma` defaults to `c_sg_include_stscntrl_strm = 1`; with nothing driving the status stream (`s_axis_s2mm_sts_tvalid` tied low), end-of-packet S2MM descriptors wait for a status word that never comes — the transfer completes by count, the soft bits land, and the descriptor never writes back. Found with the AXI monitor on the descriptor port (the S2MM data wrote, the status write never came), fixed in the block design (`CONFIG.c_sg_include_stscntrl_strm {0}`). This was the only hardware defect; the receiver was right from the first run.
- **One receive completion per batch.** `xilinx_dma` sets the interrupt-coalescing threshold to the number of queued descriptors, so queuing all receive buffers at once produced one notification. `opv_play` keeps `RX_AHEAD = 2` transfers outstanding.
- `opv_play -L rx_bytes` bounds the capture when a run is expected to be short (first-frame debugging).
- The stale-image trap: a BOOT.BIN older than the imported XSA booted once and cost a build-boot-test cycle. `make vck190-build` now refuses to finish if either BOOT.BIN copy is older than `system.xsa`.

## Open items carried forward

- Carrier acquisition after idle stops 36–72 Hz short (issue filed
  2026-10-23); not blocking, affects the two-burst test's `est_hz` readback
  only.
- `period` is a constant (5) in the BD; make it a register when a second
  sample rate is needed.
- The board's static netmask came through as /8 (harmless on the lab
  segment; `petalinux/README.md` item 2 is the place to fix it).
- dōgu's `make cross` still fails on `dma_listen` (no ZCU102 sysroot on
  chococat); `opv_play` is built on its own (`VCK190_USER_GUIDE.md` step 10).
- Two-burst (8/8) run on hardware.
