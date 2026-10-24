# VCK-190 User Guide
_Open Research Institute digital signal processing work_

## High-Level Overview

### What is Versal?

The Versal AI Core Series chip is a system on chip (SOC) FPGA. 
It has programmable logic, scalar processors and dedicated AI and 
DSP engines. The embedded ARMs are a dual-core Cortex A72 processor 
and a dual-core Cortex R5 real-time processor. It has 8GB DDR4 and 
8GB LPDDR4. It's used for 5G radio and beamforming, which puts it 
squarely in the category of device ORI needs in order to do
open source microwave band digital multiplexing communications 
satellite (Haifuraiya) implementations. 

Versal AI Core Series chip: XCVC1902-2MSEVSVA2197

### How is Versal Organized?

Versal designs require a CIPS (Control, Interfaces and Processing 
System) block. This is the successor to the Zynq MPSoC processing-system 
IP. CIPS is used even for mostly-PL designs, like ours, because boot and 
configuration flow through CIPS.

DDR (Double Data Rate memory) and PS (Processor Side) to PL (Programmable
Logic) traffic route through the NoC (Network on Chip) via AXI 
NoC IP. We do not have direct AXI ports on the Versal, like we do with
the 7000/Ultrascale type FPGAs we've been using. Our AXI-Lite control 
plane and things like memory buffers that we capture get re-done for
Versal. 

Transceivers are instantiated through the GT Quad IP. The ESIstream 
package’s block design, from Teledyne, is going to handle this for us.

Clocking, I/O banks (1.5 V XPIO), and constraints are all new, of course.

The input side changes. No LVDS/radio-chip front end here. Eventually 
ESIstream RX goes to "reassembler" goes to DDC (digital downconverter).

### What Needed to Change for Versal?

New platforms like Versal live under /platforms/

The zcu102 stays in its sim/ syn/ petalinux/ and yocto/ directories, and
the build system (makefile) for Haifuraiya stays the same. No changes to
any of that. 

## How to Simulate on the VCK190

We have a tcl script runner that calls up a VHDL test bench. 

`run_mdt_vck190_sim.tcl`

To use it, create the stimulus file first. Here's an example:

```
 python3 opv_stim.py --preamble --clock-offset-ppm 11.5 \
    --fc 781250 --carrier-offset 500 \
    --ebn0 10 --seed 1 --out opv_chan_stim.txt
```

This sets up a 40 ms preamble and then makes six 40 ms frames. There is 
some resampling from the ppm offset, to give our circuits something to do!
It's on channel 5 (781250 Hz offset). There are additional arguments. See 
the source code for additional options and what they do.

With noise and CFO in the stimulus, the soft codes should leave the rails and 
populate the middle values, `cfo_word` and `est_hz` in the CFO group should 
move towards `--carrier-offset`, and `sym_clk_offset` in Symbol_Lock should 
settle near the ppm we injected.

We grade the resulting output files from our simulations by using a Python
script. Here's how we use it:

```
cd ~/vck190/Mode-Dynamic-Transponder/haifuraiya/sim

python3 ~/Downloads/grade_payload_ber.py ~/vck190/Mode-Dynamic-Transponder/haifuraiya/platforms/vck190/sim/mdt_vck190_sim_project/mdt_vck190_sim.sim/sim_1/behav/xsim --stim-dir .

python3 ~/Downloads/grade_payload_ber.py ~/vck190/Mode-Dynamic-Transponder/haifuraiya/platforms/vck190/sim/mdt_vck190_sim_2burst_project/mdt_vck190_sim_2burst.sim/sim_1/behav/xsim --stim-dir .
```

Action item: move the grader script into the simulations directory since 
it has earned it's keep.

## How to Build and Boot the Memory-Loopback Design (VCK190)

_Procedure as of 2026-10-23. Steps 1–5 have been run on chococat. Steps 6–9
are the next commands in the chain and have not been exercised yet 
update this section the first time through them._

Everything is run from the repo root on chococat:

```
cd ~/vck190/Mode-Dynamic-Transponder
```

`make vck190-help` lists every target below. Each target checks its own
prerequisites and tells you what is missing instead of failing halfway.

### 0. One-time setup on a fresh chococat (done 2026-10-23)

- PetaLinux 2022.2's required packages installed (`source` of its
  `settings.sh` lists what is missing).
- `/bin/sh` must be bash, not dash: `sudo dpkg-reconfigure dash` and answer
  **No**. `petalinux-build` misbehaves under dash.
- Your ssh key on the ORI license server (ask Paul).
- The top-level `Makefile` has, at the bottom:
  `include haifuraiya/platforms/vck190/vck190.mk`

### 1. Open the shell for the build

Every terminal you build in needs both tools sourced. Do this first, every time:

```
source /tools/Xilinx/Vivado/2022.2/settings64.sh
source /tools/Xilinx/PetaLinux/2022.2/settings.sh
```

### 2. Check out the license (needed for synthesis only)

```
make vck190-license-up
export XILINXD_LICENSE_FILE=2100@127.0.0.1
```

The first command opens Paul's ssh tunnel to `flexlm-server.openresearch.institute`
(local ports 2100/2101). The second tells Vivado where the license is; it must be
typed in the same terminal you build from, because `make` cannot set it for you.
When you are done for the day: `make vck190-license-down`.

### 3. Build the block design only (minutes; no license needed)

```
make vck190-project
```

Creates the Vivado project, the block design (CIPS, NoC, DDR, DMA, pacer,
receiver, widener, control plane), validates it and generates the wrapper.
Then look at two things in `haifuraiya/platforms/vck190/syn/vck190_project.log`:

```
grep "INFO: M_AXI_FPD" haifuraiya/platforms/vck190/syn/vck190_project.log
grep -B1 -A4 "CRITICAL WARNING" haifuraiya/platforms/vck190/syn/vck190_project.log
```

Expected address map (this is what the device tree and software use):

```
/cips/M_AXI_FPD/SEG_axi_dma_Reg   offset 0x000A4000000   DMA
/cips/M_AXI_FPD/SEG_rx_reg0       offset 0x000A4010000   receiver: channelizer registers
/cips/M_AXI_FPD/SEG_rx_reg0_1     offset 0x000A4020000   receiver: demod registers
```

Expected critical warning (one, cosmetic): `Port 'm_axis_soft_bit_tdata' ...
must have a width of multiples of 8 bits. The current port width is '3'.`
The receiver's soft-bit port is 3 bits wide (as on the ZCU102); the widener
makes it a byte before the DMA. Any *other* critical warning: stop and look.

### 4. Build the bitstream and XSA (hours; license required)

```
make vck190-xsa
```

Refuses to start unless the tunnel is up and `XILINXD_LICENSE_FILE` is set.
Runs synthesis, implementation and the device image; writes
`haifuraiya/platforms/vck190/syn/mdt_vck190_playback.xsa`,
`timing_summary.rpt` and `utilization.rpt` next to it.

### 5. Read the two numbers that matter

```
cd haifuraiya/platforms/vck190/syn
grep -A2 "WNS(ns)" timing_summary.rpt | head -3
grep -i "timing constraints are met" timing_summary.rpt
grep -E "^\| (CLB LUTs|CLB Registers|Block RAM Tile|DSP58|DSP as Logic) " utilization.rpt
cd ~/vck190/Mode-Dynamic-Transponder
```

WNS (first column) positive and "Failing Endpoints" 0 = timing met at
100 MHz. If the resource names in the utilization report differ,
`grep -n "^| " utilization.rpt | head -40` shows every row; fix the names here.

### 6. Create the PetaLinux project (one time; done 2026-10-23)

```
make vck190-petalinux-create
```

Makes `haifuraiya/platforms/vck190/petalinux/mdt_vck190/` from the Versal
template. Commit only `config.project` and `project-spec/` from it.

### 7. Import the XSA into PetaLinux  _(not yet run)_

```
make vck190-import-xsa
```

Runs `petalinux-config --get-hw-description` on the XSA from step 4, copies
in `petalinux/system-user.dtsi` (receiver registers as UIO, DMA proxy node),
and checks that the imported XSA really carries the receiver at 0xA4010000 —
the "wrong XSA imported" trap from the ZCU102 days.

### 8. Build the Linux image  _(not yet run)_

```
make vck190-build
```

`petalinux-build`, then packages BOOT.BIN, image.ub and boot.scr into
`petalinux/mdt_vck190/images/linux/` and the prebuilt directory for JTAG boot.
First build is long (it fetches and builds the whole Yocto image); later ones
are incremental.

### 9. Boot the board  _(not yet run)_

```
make vck190-boot
```

`petalinux-boot --jtag --prebuilt 3` — needs `hw_server` reachable and the
VCK190 on JTAG. Alternative: copy the three files from step 8 to an SD card.

### 10. Run the memory loopback  _(tool not yet written)_

On the board: `opv_play` loads a stimulus file (the same `opv_chan_stim.txt`
the simulator uses) into DDR, programs the receiver's registers, streams it
through the receiver at 20 MSps, and writes the soft bits to a file. Then on
chococat, exactly as for the simulation:

```
python3 haifuraiya/sim/grade_payload_ber.py <soft-bit file> --stim-dir haifuraiya/sim
```

Pass = 25/25 decodable, flat, matching the xsim table.

### Cleaning up

```
make vck190-clean          # removes the Vivado project dir and logs, keeps the XSA
make vck190-license-down   # drops the license tunnel
```

### Things that bit us (keep adding)

- 2026-10-23: forgot the license checkout; synthesis refused at launch. Now
  guarded by `vck190-check-license`.
- 2026-10-23: `git add` of the sim directory staged two whole Vivado project
  trees. `haifuraiya/platforms/vck190/.gitignore` now excludes `*_project/`,
  logs, and the PetaLinux build products.
- 2026-10-23: PetaLinux on a fresh machine: missing packages, and `/bin/sh`
  was dash.

