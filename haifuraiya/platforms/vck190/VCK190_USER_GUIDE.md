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
package's block design, from Teledyne, is going to handle this for us.

Clocking, I/O banks (1.5 V XPIO), and constraints are all new, of course.

The input side changes. No LVDS/radio-chip front end here. Eventually 
ESIstream RX goes to "reassembler" goes to DDC (digital downconverter).
The ESIstream work — package review, pins, the tier-2 digital loopback and
the tier-3 operating point — is in `ESISTREAM_NOTES.md`.

### What Needed to Change for Versal?

New platforms like Versal live under /platforms/

The zcu102 stays in its sim/ syn/ petalinux/ and yocto/ directories, and
the build system (makefile) for Haifuraiya stays the same. No changes to 
any of that. 

## How to Simulate on the VCK190

Two runners, one switch. Both are sourced from the Vivado Tcl console on
chococat.

| Runner | What it simulates | Bench |
|---|---|---|
| `sim/run_mdt_vck190_sim.tcl` | Tier 1: the core alone, retargeted to the VC1902 | the shared ZCU102 bench `haifuraiya/sim/tb_haifuraiya_channelizer_axi.vhd`, referenced in place |
| `sim/run_mdt_vck190_esi_sim.tcl` | Tier 2: the ESIstream link spliced into the sample path (digital loopback, no transceiver) | `sim/tb_haifuraiya_vck190_esi.vhd`, a copy of the shared bench with the link added; `diff` the two and only the `ESI:` hunks differ |

The tier-2 runner is two lines: `set ESI_LOOP 1` and source the tier-1
runner, which then adds the 22 link files (Teledyne's 18 plus our 4 under
`rtl/esi/`) and uses the copy as top. Look for
`PART 2 (tier 2) complete: 54 files in sources_1.` in the log.

Create the stimulus file first. This is the acceptance stimulus:

```
cd haifuraiya/sim
python3 opv_stim.py --preamble --clock-offset-ppm 11.5 \
    --fc 781250 --carrier-offset 500 \
    --ebn0 10 --seed 1 --frames 25 --out opv_chan_stim.txt
```

This sets up a 40 ms preamble and then 25 40 ms frames (1.04 s). There is 
some resampling from the ppm offset, to give our circuits something to do!
It's on channel 5 (781250 Hz offset). There are additional arguments. See 
the source code for additional options and what they do. Short runs (6
frames, the default) are for smoke tests only: the receiver always works for
the first ~6 frames, and the failures that matter show up later.

With noise and CFO in the stimulus, the soft codes should leave the rails and 
populate the middle values, `cfo_word` and `est_hz` in the CFO group should 
move towards `--carrier-offset`, and `sym_clk_offset` in Symbol_Lock should 
settle near the ppm we injected.

We grade the resulting output files from our simulations by using a Python
script, now in the repo at `haifuraiya/sim/grade_payload_ber.py`:

```
cd ~/vck190/Mode-Dynamic-Transponder/haifuraiya/sim
python3 grade_payload_ber.py \
    ../platforms/vck190/sim/mdt_vck190_sim_project/mdt_vck190_sim.sim/sim_1/behav/xsim --stim-dir .
```

Pass is 25/25 decodable with a flat pre-FEC BER table (0.00–0.56 % on the
acceptance stimulus). The tier-2 run adds a line near the end of the xsim
log, `ESI LINK: sent= rcvd= seq_err= marker_err= multi_err=`, which must
show sent = rcvd and all three error counts 0, and is folded into
`ALL TESTS PASSED`.

Run time: tier 1 is about a night for the 25-frame stimulus. Tier 2 with 8
lanes measured ~18 ms of simulated time per hour on chococat (2026-11-02),
i.e. roughly 55–60 hours — the ESIstream encoder and decoder run every
6.4 ns on every lane whether or not a slot carries a sample. The planned
follow-up is `NB_LANES => 2` on `u_esi` in the bench copy (the tier-3 lane
count anyway).

There is also a link-level bench that runs in seconds under nvc, for the
ESIstream pieces alone:
`sim/esi/run_esi_link_nvc.sh` (pass = `PASS: tb_esi_link_loop`). It uses
`sim/esi/rx_xpm_async_fifo_sim.vhd` in place of Teledyne's XPM FIFO wrapper;
never add that stand-in to a Vivado project.

## How to Build and Boot the Memory-Loopback Design (VCK190)

_Procedure as of 2026-10-25. Every step below has been run on chococat and
the design passed on the board. Keep "Things that bit us" current._

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

Every terminal you build in needs both tools sourced. Do this first, every
time, **from your home directory in a fresh terminal**:

```
cd ~
source /tools/Xilinx/Vivado/2022.2/settings64.sh
source /tools/Xilinx/PetaLinux/2022.2/settings.sh
cd ~/vck190/Mode-Dynamic-Transponder
```

PetaLinux's `settings.sh` resolved its install directory to the *current*
directory once, when sourced from inside the project tree, and
`petalinux-config` was then not on PATH. Sourcing from `~` avoids it.

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

### 4. Build the bitstream and XSA (license required)

```
make vck190-xsa
```

Refuses to start unless the tunnel is up and `XILINXD_LICENSE_FILE` is set.
Runs synthesis, implementation and the device image; writes
`haifuraiya/platforms/vck190/syn/mdt_vck190_playback.xsa`,
`timing_summary.rpt` and `utilization.rpt` next to it. About 100 minutes.

Debug variant: `make vck190-xsa-ila` builds the same design plus an ILA
(native taps on the soft-bit stream, AXI monitors on the DMA) and writes
`mdt_vck190_playback_ila.xsa` and `.ltx`. Native probes on plain nets are
the house style; Vivado's AXI-Stream interface monitors do not elaborate on
this stream (no TKEEP/TDEST). Build the ILA variant only when chasing
something; it is a separate 100 minutes.

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

### 6. Create the PetaLinux project (once)

```
make vck190-petalinux-create
```

Makes `haifuraiya/platforms/vck190/petalinux/mdt_vck190/` from the Versal
template. Commit only `config.project` and `project-spec/` from it. The
settings applied on top of the template (root login, static IP, the
dma-proxy module, the board machine name) are listed in
`petalinux/README.md`; they are already in the tracked `project-spec/`.

### 7. Import the XSA into PetaLinux

```
make vck190-import-xsa
```

Runs `petalinux-config --get-hw-description` on the XSA from step 4, copies
in `petalinux/system-user.dtsi` (receiver registers as UIO, DMA proxy node,
`cma=512M`), and checks that the imported XSA really carries the receiver at
0xA4010000 — the "wrong XSA imported" trap from the ZCU102 days. The XSA
path is made absolute inside the Makefile: a relative path once imported
nothing, silently, because `petalinux-config` runs after a `cd`.

### 8. Build the Linux image

```
make vck190-build
```

`petalinux-build`, then packages BOOT.BIN, image.ub and boot.scr into
`petalinux/mdt_vck190/images/linux/` and the prebuilt directory for JTAG boot.
First build is long (it fetches and builds the whole Yocto image); later ones
are incremental. The target ends by checking that both BOOT.BIN copies are
newer than the imported `system.xsa`; if not, it fails on purpose (a stale
image booted once and looked like a design bug).

### 9. Boot the board

```
# power-cycle the VCK190, wait 30 s, then:
make vck190-boot
ssh-keygen -R 10.73.1.17
```

`petalinux-boot --jtag --prebuilt 3` needs `hw_server` reachable and the
VCK190 on JTAG. Boot mode switches all ON for JTAG. The board is at
10.73.1.17 (static), login `root`, no password. The root filesystem is a RAM
disk, so the ssh host key is new every boot: the `ssh-keygen -R` is not
optional.

Two JTAG facts: the LibreSDR (xc7z020) is on chococat's JTAG chain too, so
`xsdb` targets list both — the VCK190 is the `xcvc1902` entry. And if the
Versal's boot ROM is in an error state (a failed or interrupted boot leaves
it there, `error_status` shows it), nothing programs until the board is
power-cycled; wait the 30 s before trying again.

If `make vck190-boot` misbehaves, the manual equivalent in `xsdb` is:
`device program BOOT.BIN`, select the A72 target, `dow -data Image
0x00200000`, `dow -data rootfs.cpio.gz.u-boot 0x04000000`, `dow -data
system.dtb 0x00001000`, `dow -data boot.scr 0x20000000`, `con`. The files
are in `petalinux/mdt_vck190/images/linux/`.

First-boot checks on the board:

```
ls /dev/uio* /dev/dma_proxy_*          # uio0 (map0 ctrl, map1 demod), dma_proxy_rx dma_proxy_tx
dmesg | grep -i "dma_proxy\|xilinx-vdma\|macb"
ip -br addr                             # eth0 10.73.1.17
```

### 10. Run the memory loopback

`opv_play` lives in the dōgu repo (`tools/opv_play/`). It loads a stimulus
file into DDR, programs the receiver's registers, streams it through the
receiver at 20 MSps, and writes the soft bits to a file.

Build and deploy from chococat. dōgu's `make cross` fails on `dma_listen`
(it needs the ZCU102 sysroot, which chococat does not have), so build the
one tool directly with the Vitis cross compiler, then deploy:

```
source /tools/Xilinx/Vitis/2022.2/settings64.sh     # puts aarch64-linux-gnu-gcc on PATH
cd ~/dogu
make -C tools/opv_play
make deploy-vck190
cd -
```

Convert the stimulus and send it over:

```
python3 haifuraiya/platforms/vck190/tools/opv_stim_txt2bin.py haifuraiya/sim/opv_chan_stim.txt /tmp/opv_chan_stim.bin
scp /tmp/opv_chan_stim.bin root@10.73.1.17:/home/root/
```

On the board:

```
/home/root/opv_play -i /home/root/opv_chan_stim.bin -o /home/root/soft.bin -q
```

`-q` prints the register readbacks (frame sync, symbol lock, `cfo_word`,
`sym_clk_offset`) after the run; `-f max_frames` and `-L rx_bytes` bound a
run when debugging; `-v` is chatty. Exit status 2 means a DMA error. Reboot
the board between runs: the receiver is not reset by `opv_play`, and a
second run on a warm receiver is not the same test.

Then on chococat, exactly as for the simulation:

```
scp root@10.73.1.17:/home/root/soft.bin /tmp/
python3 haifuraiya/platforms/vck190/tools/opv_soft_bin2txt.py /tmp/soft.bin /tmp/soft.txt
python3 haifuraiya/sim/grade_payload_ber.py /tmp/soft.txt --stim-dir haifuraiya/sim
```

Pass = 24/24 decodable, flat, the same shape as the xsim table. Measured
2026-10-25: 24/24, pre-FEC BER 0.00–0.56 %.

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
- 2026-10-24: the Versal *template* project has no board support: generic
  PHY, no board device tree, Ethernet dead. `CONFIG_SUBSYSTEM_MACHINE_NAME`
  must be `versal-vck190-reva` (DP83867 PHY delays, MACs). Also set a real
  MAC (the template gave `ff:ff:...`) and the static IP; the symbols are in
  `petalinux/README.md`.
- 2026-10-24: PetaLinux `settings.sh` sourced from inside the project tree
  resolved to the wrong directory; `petalinux-config` vanished from PATH.
  Source from `~` in a fresh terminal (step 1).
- 2026-10-24: `make vck190-import-xsa` with a relative XSA path imported
  nothing and said nothing. Path is now made absolute in `vck190.mk`.
- 2026-10-24: root login locked by default in 2022.2; `debug-tweaks` in the
  rootfs config restores the ZCU102 behaviour (root, no password).
- 2026-10-24: the dma-proxy module was built but not loaded at boot;
  `KERNEL_MODULE_AUTOLOAD += "dma-proxy"` in the recipe.
- 2026-10-24: the board would not answer ping; it was a lab-segment issue,
  not the image (IPv6 all-nodes pings got replies, which ruled out the
  board's transmit path). Swapping the board's two Ethernet jacks does not
  help and earns a lecture. Ask Paul before touching the bench.
- 2026-10-25: `make vck190-boot` tried to program the LibreSDR on the same
  JTAG chain, and the Versal boot ROM sat in an error state until a power
  cycle. Power cycle, wait 30 s, then boot.
- 2026-10-25: a BOOT.BIN older than the imported XSA booted a stale fabric.
  `make vck190-build` now checks timestamps and refuses.
- 2026-10-25: DMA receive "timed out" with the soft bits already in DDR —
  the `axi_dma` status/control stream default (`c_sg_include_stscntrl_strm`)
  left S2MM end-of-packet descriptors waiting for a status word nobody
  sends. Off in the block design now. Found with the AXI monitor on the
  descriptor port; the receiver itself was right from the first run.
- 2026-10-25: only the first receive descriptor completed — `xilinx_dma`
  interrupt coalescing equals the queue depth. `opv_play` keeps two
  receives outstanding (`RX_AHEAD`).
- 2026-10-25: ran `opv_play` without rebuilding it, then without rebooting
  the board. Both looked like design regressions. Stop when the mistakes
  start stacking; the morning run passed.
- 2026-11-02: `git apply` of a review patch failed ("No such file") — its
  paths lacked the `haifuraiya/` prefix. The tarballs carry whole files;
  the patches are for reading.
