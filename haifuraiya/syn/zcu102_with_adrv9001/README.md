# Haifuraiya — ZCU102 + ADRV9002 Integrated Synthesis

This directory builds a Vivado project that integrates the Haifuraiya
channelizer IP into the Analog Devices `adrv9001/zcu102` reference design.
The result is a bitstream with the channelizer spliced into the RX1
datapath, suitable for live demonstration of polyphase channelization
on the AMSAT-UK FunCube+ ground station / lab development board.

## Distinguishing this from the Phase 1 standalone project

The repo contains two parallel ZCU102 build directories:

| Directory | Purpose | Includes ADRV9002? |
|-----------|---------|--------------------|
| `haifuraiya/syn/zcu102/` | Phase 1 standalone synth (IP-XACT verification) | No |
| `haifuraiya/syn/zcu102_with_adrv9001/` | Phase 3 integrated build (this directory) | Yes (via ADI submodule) |

Both are kept; both are useful. The standalone build is faster and
useful for testing IP changes in isolation. The integrated build is
what produces the bitstream we boot on real hardware.

## Topology

The splice replaces a single net in the ADI reference RX1 path. Before:

```
axi_adrv9001 → [parallel I/Q] → util_adc_1_pack → [64b fifo_wr] → axi_adrv9001_rx1_dma (DMA_TYPE_SRC=2)
```

After:

```
axi_adrv9001 → [parallel I/Q] → axis_iq_wrapper → [32b AXIS] → haifuraiya_channelizer_axi → [32b AXIS] → axi_adrv9001_rx1_dma (DMA_TYPE_SRC=1)
```

RX2, TX1, and TX2 are NOT modified. They remain identical to ADI's
reference and provide a working baseline for diagnostics if the RX1
channelizer path misbehaves.

## Files in this directory

This directory contains ONLY files that are uniquely ours. Files
authored by Analog Devices are referenced directly from the pinned
`hdl` submodule via `$ad_hdl_dir` — they are never copied into this
directory. See "Why we reference instead of copy" below for the
rationale.

| File | Purpose | Origin |
|------|---------|--------|
| `README.md` | This file | new |
| `system_project.tcl` | Vivado project creation, sanity-checks upstream files, references them via `$ad_hdl_dir` | new (adapted from ADI's) |
| `system_bd.tcl` | Builds the entire block design: Phase A sources ADI's reference bd verbatim; Phase B splices the channelizer into RX1 | new (adapted from ADI's) |
| `axis_iq_wrapper.vhd` | Parallel-to-AXIS adapter (no upstream equivalent) | new |

Files we reference but do NOT copy (read directly from the hdl submodule
at build time):

| Referenced path | Purpose |
|------|---------|
| `$ad_hdl_dir/projects/adrv9001/zcu102/system_top.v` | Top-level Verilog wrapper |
| `$ad_hdl_dir/projects/adrv9001/zcu102/system_constr.xdc` | Board-level constraints |
| `$ad_hdl_dir/projects/adrv9001/zcu102/cmos_constr.xdc` | CMOS interface constraints |
| `$ad_hdl_dir/projects/adrv9001/zcu102/lvds_constr.xdc` | LVDS interface constraints |
| `$ad_hdl_dir/projects/adrv9001/common/adrv9001_bd.tcl` | ADRV9002 BD definition |
| `$ad_hdl_dir/projects/common/zcu102/zcu102_system_bd.tcl` | ZCU102 base BD (PS, DDR, clocks) |
| `$ad_hdl_dir/projects/common/zcu102/zcu102_system_constr.xdc` | ZCU102 board constraints |
| `$ad_hdl_dir/library/common/ad_iobuf.v` | ADI's I/O buffer primitive |

## Why we reference instead of copy

The Analog Devices `hdl` repository is included in this project as a
git submodule pinned to a specific revision (currently `hdl_2022_r2`).
Vivado's TCL flow can use files from anywhere on the filesystem — there
is no requirement that all project sources live in the same directory.
That gives us a choice for ADI-authored files we want to use unmodified:

**Option A: copy the files into this directory.** Works because the
submodule pin guarantees the copies stay byte-equivalent to upstream
until we deliberately bump the pin. Used by some other projects
(including pluto_msk).

**Option B: reference the files in-place via `$ad_hdl_dir` paths.**
Used by us. The TCL flow reads upstream files directly from
`haifuraiya/third_party/hdl/...` at build time.

We chose Option B for four reasons:

1. **Single source of truth.** Two copies of the same file (here and in
   the submodule) is an invitation for one to be edited "just a little"
   and silently diverge. With references, there is exactly one path to
   that file and exactly one set of contents.
2. **Submodule bumps become trivial.** When we eventually update the pin
   to `hdl_2024_r2` (or further), the build picks up the new versions
   automatically. With copies, every submodule bump requires
   re-copying the (potentially changed) files and remembering to do so.
3. **Loud failure on upstream restructure.** If a future ADI release
   moves `system_top.v` to a different path, the build fails at TCL
   parse time with a clear error (the sanity-check block at the top of
   `system_project.tcl` catches it explicitly). Silent staleness from
   forgotten copies is impossible.
4. **Smaller, more reviewable directory.** Four files we authored, all
   meaningful. No "this is just a copy of upstream, please ignore"
   noise in `git log`.

The trade-off: tighter coupling to upstream's directory layout. We
accept this because the submodule pin makes upstream's layout a
known, stable contract within any given pinned version.

## Provenance / precedent

This integration approach is adapted from the pluto_msk libre Vivado
project (an ORI / collaborator effort deployed on LibreSDR ground
stations), which proved the `DMA_TYPE_SRC=1` + AXIS-direct pattern in
production. The key innovation is recognizing that ADI's `axi_dmac` IP
already supports AXIS input; switching from FIFO-write input to AXIS
input is a single parameter change, and eliminates the need for
`util_cpack2` packing on the RX1 path.

The reference-via-submodule choice diverges from pluto_msk's copy
approach. Both are defensible. We chose differently because Haifuraiya
expects more frequent collaborator contributions and longer-horizon
HDL release cycles, and the reduced drift risk is worth the slight
extra coupling.

## Memory map additions

| Address | Peripheral | Notes |
|---------|------------|-------|
| 0x84A70000 | `channelizer_rx1` (AXI-Lite control) | New — sits outside ADI's 0x44A_xxxx range |

The channelized RX1 data continues to flow through `axi_adrv9001_rx1_dma`
at 0x44A30000 (ADI's original address). Userspace reads the channelized
stream from this DMA exactly as it would read raw RX1 in the unmodified
reference — but the bytes are now tdest-tagged channels, not raw I/Q.

## Build command

From the MDT repo root:

```bash
source /tools/Xilinx/Vivado/2022.2/settings64.sh
make haifuraiya-xsa-integrated   # NEW target — see top-level Makefile
```

Expected duration: ~5 hours unattended Vivado batch. Output XSA goes to
`haifuraiya/syn/zcu102_with_adrv9001/adrv9001_zcu102_ori.sdk/system_top.xsa`.

Re-import to PetaLinux and rebuild:

```bash
make haifuraiya-import-xsa-integrated   # NEW target
make haifuraiya-build
```

## Verification steps post-boot

After JTAG-booting the integrated bitstream, on the ZCU102:

1. `dmesg | grep adrv9002` — expect the same signature line as Phase 2b
2. `cat /proc/iomem | grep 84a70000` — expect to see the channelizer AXI-Lite mapped
3. `devmem 0x84A70000` and `devmem 0x84A70004` — read channelizer control/status registers
4. Configure ADRV9002 RX (frequency, sample rate, gain) via libiio
5. Enable channelizer via control register write
6. Start DMA capture via libiio (cf-axi-adc for RX1)
7. Inspect captured stream: each 32-bit word is one channel sample with
   tdest = channel index (0-63 for a 64-channel polyphase)

## Known unknowns (file as Open Quests once verified)

- **Sample rate clock domain.** The channelizer runs at `adc_1_clk`. We
  haven't verified the channelizer's internal timing closes at the actual
  ADRV9002 sample rate range. May need to set Vivado timing constraints
  explicitly.
- **`channelizer_rx1/aresetn` polarity at the IP boundary.** The
  haifuraiya_channelizer_axi component.xml's port description for
  `aresetn` should be active-low (AXIS convention). Verify via the
  IP-XACT package or by reading the VHDL.
