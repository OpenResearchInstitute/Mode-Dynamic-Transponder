# VCK190 Memory Loopback Plan

_Open Research Institute, 2026-10-23. Status: plan + unvalidated build scripts._

## Loopback Tests

| Tier | What is in the loop | Needs | Pass/fail |
|---|---|---|---|
| **1. Memory loopback** (this plan) | DDR → DMA → pacer → receiver → DMA → DDR. No converter interface at all. | VCK190, Vivado 2022.2, PetaLinux 2022.2 | `grade_payload_ber.py` on the captured soft bits matches the xsim table (25/25 flat; two-burst 8/8) |
| 2. Digital loopback | The ESIstream serial path: GT quad, lane alignment, reassembler, digital downconverter; Teledyne/ESIstream link test patterns (PRBS, fixed) with no analog signal; later DAC-out to ADC-in by cable | Teledyne EV12AQ600/EV12DD700 FMC EVMs, ESIstream package | Link patterns error-free; samples arriving from ESIstream match what the memory path was fed |
| 3. RF loopback | A radio card's SMA ports | A radio card (none yet) | As the ZCU102's RF loopback |

Tier 1 is the ZCU102's "digital loopback" taken one level deeper: there is not even a serial link in it, and it is the only tier whose pass criterion is already defined to the bit.

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
| Stimulus | DDR, written by the A72 from `opv_chan_stim.txt` | int16 I/Q pairs packed as one 32-bit beat (I low half, Q high half — the AXIS convention `haifuraiya_channelizer_axi` already uses); 20 MSps; 1.04 s = 20.8 M beats = 83 MB |
| Pacing | `axis_sample_pacer` (new, `platforms/vck190/rtl/`) | one beat per `period` clocks (5 at 100 MHz = 20 MSps), DMA held off in between; the hardware form of the bench's `SMP_PERIOD` |
| Receiver | `haifuraiya_rx_axi` (unchanged, module reference) | `aclk` 100 MHz; `s_axis_data` consume-on-arrival; two AXI-Lite slaves (ctrl, demod) with the published register maps; `m_axis_soft_bit` 3-bit + TLAST per frame |
| Soft bits | `axis_softbit_widen` (ZCU102 file, read-only reuse) → DMA S2MM | one byte per soft bit, 0..7, the layout `opv-decode -3` and the graders read |
| DMA | Xilinx `axi_dma` 7.1, scatter-gather, 64-bit addressing | MM2S 32-bit, S2MM 8-bit; SG so an 83 MB playback streams across descriptors without a gap |
| Control | CIPS `M_AXI_FPD` → SmartConnect → DMA lite, rx ctrl, rx demod | 0xA400_0000 DMA, 0xA401_0000 ctrl, 0xA402_0000 demod (proposed; fixed at `assign_bd_address` time) |
| Clock/reset | CIPS `pl0_ref_clk` 100 MHz, `pl0_resetn` → `proc_sys_reset` | one clock domain in the PL, same as the simulation |
| Software | PetaLinux 2022.2 on the A72s | DMA via the kernel `xilinx_dma` driver through a userspace proxy; registers via UIO |

Nothing in the receiver changes. The two new blocks are the pacer (verified,
`sim/tb_axis_sample_pacer.vhd`, runner `sim/run_axis_sample_pacer_nvc.sh`,
4/4 pass under nvc) and the block design itself.

## Files (all additive, all under `platforms/vck190/`)

```
rtl/axis_sample_pacer.vhd              the pacer
sim/tb_axis_sample_pacer.vhd           its bench
sim/run_axis_sample_pacer_nvc.sh       its runner
syn/vck190_playback_bd.tcl             block design (DRAFT — not yet run)
syn/vck190_playback_project.tcl        project, wrapper, build, .xsa (DRAFT — not yet run)
VCK190_PLAYBACK_PLAN.md                this file
```

## Build procedure (chococat)

1. `cd haifuraiya/platforms/vck190/syn` 
2. `vivado -mode batch -source vck190_playback_project.tcl` — project + block
   design + wrapper. **pass**
3. `vivado -mode batch -source vck190_playback_project.tcl -tclargs build` —
   synthesis, implementation, device image, `mdt_vck190_playback.xsa`,
   `timing_summary.rpt`, `utilization.rpt`. 
   
   To check results:
   timing: the header line and the numbers under it (WNS is the first column)
   `grep -A2 "WNS(ns)" timing_summary.rpt | head -3`
   the one-line verdict Vivado prints when every constraint is met, snag it:
   `grep -i "timing constraints are met" timing_summary.rpt`
   utilization: one row each for the resources that matter here
   `grep -E "^\| (CLB LUTs|CLB Registers|Block RAM Tile|DSP58|DSP as Logic) " utilization.rpt`
   
4. Doctrine check before step 3: the sim already passed on this RTL
   (25/25, 8/8). The pacer has its own bench. The BD has no bench; its
   correctness is `validate_bd_design` plus the hardware test.

## Software (after the .xsa exists)

1. PetaLinux 2022.2 project from the .xsa (`petalinux-create -t project
   --template versal`, `petalinux-config --get-hw-description`). This is
   run from Mode-Dynamic-Transponder/ or the top level, not from /syn
2. Device tree: `axi_dma` is picked up by the generated DT and bound to
   `xilinx_dma`; the two receiver register blocks get `generic-uio` nodes
   (compatible override in `system-user.dtsi`).
3. Userspace: one small tool, `opv_play` — load the stimulus file into a
   DMA buffer, program the receiver registers (OUTPUT_SHIFT, NORM_SQUELCH,
   CFO/timing gains: the same values the sim runner writes), start S2MM
   capture, start MM2S playback, wait, write the soft bytes to a file.
   Grade with `grade_payload_ber.py` as for the simulation. The DMA proxy
   is the point of decision: Xilinx's `dma-proxy` example driver, or a
   `libaxidma`-style userspace driver; either gives SG transfers from a
   file-sized buffer.
4. The ZCU102 flow uses ADI's `axi_dmac` + IIO + `dma_listen`. This design
   uses Xilinx `axi_dma` because the VCK190 build is from scratch without
   the ADI library. If reusing `dma_listen` unchanged matters more than
   staying ADI-free, swap the DMA in the BD for `axi_dmac` (two cells and
   the address lines) — the rest is unchanged.

## Acceptance

- `opv_play` on `opv_chan_stim.txt` (25-frame, 11.5 ppm, +500 Hz, seed 1):
  `grade_payload_ber.py` 25/25 decodable, flat, matching the xsim table to
  within a bit or two per frame (the hardware is the same RTL; the only
  difference is DMA pacing jitter, which the pacer removes).
- Register readbacks over UIO match the sim's: `cfo_word` ≈ 498–500,
  `sym_clk_offset` converging to about −2,200 Q24, `sym_locked` set,
  frame sync locked.
- Two-burst file: 8/8 real frames.

## Decisions taken

- **Keep the 2:1 halfband (20 MSps in, 10 MSps to the channelizer).** It exists because the ADRV9002 profiles delivered 20 MSps; the VCK190 has no such constraint, and the Teledyne digital downconverter will need a final decimating filter anyway, which may make the halfband redundant. But removing it would change the device under test and the stimulus at the same time as moving to silicon. Tier 1 confirms the receiver that passed in simulation (`SMP_PERIOD = 5`, the existing stimulus files). Dropping the halfband is its own later test: `opv_stim.py --fs 10e6`, pacer period 10, sim at `SMP_PERIOD = 10`, then the board — a tier-2 decision made with the ADC clock plan in hand. Note for that design: at 10 MSps the channelizer input is a full 10 MHz with no guard, so the downconverter's last filter must provide the transition band the halfband provides today.
- **PetaLinux 2022.2, not pure Yocto**, as on the ZCU102: 2022.2 is the Vivado the floating license covers and the version the ADI reference design needs; the Versal part is not in the free edition's device list (Vivado itself is the authority on that).
- **Xilinx `axi_dma` + `dma-proxy`**, not ADI `axi_dmac` + IIO, because the VCK190 build is from scratch without the ADI library. Swapping is two cells in the block design if reusing `dma_listen` unchanged turns out to matter more.

## Build flow (Makefile)

`vck190.mk` adds the targets to the top-level Makefile (one line: `include haifuraiya/platforms/vck190/vck190.mk`), mirroring the ZCU102 flow's shape:

```
make vck190-project            Vivado batch: project + block design + wrapper (fast; validates the BD)
make vck190-xsa                ... + synth/impl/device image -> syn/mdt_vck190_playback.xsa, timing + utilization reports
make vck190-petalinux-create   once: petalinux-create -t project --template versal (under platforms/vck190/petalinux/)
make vck190-import-xsa         petalinux-config --get-hw-description + copy petalinux/system-user.dtsi; checks the XSA has the receiver at 0xA4010000
make vck190-build              petalinux-build + package (BOOT.BIN, image.ub, boot.scr, prebuilt)
make vck190-boot               petalinux-boot --jtag --prebuilt 3
```

`petalinux/system-user.dtsi` binds the receiver's registers to `generic-uio` and adds a `dma-proxy` node on the two `axi_dma` channels. The userspace tool (`opv_play`: load stimulus into the DMA buffer, write registers, run, write soft bytes out) is written after the first boot, against the real `/dev/uio*` and `/dev/dma_proxy_*` names.

## Open items carried into this build

- Carrier acquisition after idle stops 36–72 Hz short (issue filed
  2026-10-23); not blocking, affects the two-burst test's `est_hz` readback
  only.
- `period` is a constant (5) in the first BD; make it a register when a
  second sample rate is needed.
- Timing closure on the XCVC1902 at 100 MHz is expected to be easy (the
  design closes on the ZCU102 at the same clock) but is unmeasured until
  step 3 runs.
