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
settle near **minus** the ppm we injected (−11.5 ppm; the stimulus stretches
the waveform, so the symbol clock is slow and the loop's correction is
negative — simulation −2254 Q24, board −2203, both = −11.4 ppm).

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

Run time, measured on chococat with the 3-frame stimulus: the core alone
simulates 130–146 ms per wall hour (about 8 hours for the 25-frame
stimulus); tier 2 at 8 lanes ran 18.6 ms/hour (59 h 40 min for 25 frames);
at 2 lanes 51 ms/hour. The bench copy is at 2 lanes now (the tier-3 lane
count). The ESIstream encoder and decoder run every 6.4 ns on every lane
whether or not a slot carries a sample, so lanes are the first cost, the
156.25 MHz clock and the two crossing FIFOs the rest. `top` on `xsimk`
shows the real load; Vivado's `run: Time` cpu figure is Vivado's own
process, not the simulator.

Two checks worth running on any tier-2 archive:

```
python3 haifuraiya/platforms/vck190/tools/esi_rx_check.py haifuraiya/sim/opv_chan_stim.txt <archive>/esi_rx_samples.txt
```

(every sample the core received against the stimulus, plus the spacing
histogram — expect 0 mismatches and only 5s), and a byte compare
(`cmp`) of `soft_raw.txt` against the tier-1 archive of the same stimulus —
expect identical (it was, 2026-11-08). `tools/which_phase.py` tells which
halfband decimation phase a `channel_iq.txt` capture used, against the
golden channelizer model.

Per-frame BER tables recorded before 2026-11-08 were computed with the
bench's first sample dropped (the halfband ran on the other decimation
phase); see "Things that bit us". The grade class is unchanged; the old
numbers do not reproduce exactly.

There is also a link-level bench that runs in seconds under nvc, for the
ESIstream pieces alone:
`sim/esi/run_esi_link_nvc.sh` (pass = `PASS: tb_esi_link_loop`). It uses
`sim/esi/rx_xpm_async_fifo_sim.vhd` in place of Teledyne's XPM FIFO wrapper;
never add that stand-in to a Vivado project. The same bench, and the
wrapper's unit test (T7), also run under GHDL — `run_esi_link_ghdl.sh`,
`run_esi_link_hw_ghdl.sh` — and the two simulators agree event for event
(2026-11-11). GHDL 4.x is needed: Ubuntu 24.04's package is fine, 22.04's
is 1.0 and too old; on 22.04 use a release tarball from
github.com/ghdl/ghdl (unpack, put its `bin` on PATH).

## Logs and waveforms after a simulation

The runner archives every run that reaches the bench's own finish:
`simulate.log`, the `.wdb` waveform database, and the output text files go
to `sim/logs/<bench>_<date>_<time>/` before the next `source` can delete
the project directory (it deletes it every time — the 59-hour tier-2
waveform was lost that way on 2026-11-05). `*.wdb` is gitignored; the text
is committed as the evidence behind the notes.

Two things the archive does **not** capture:

- The Tcl console text. `simulate.log` stops at the last message xsim
  wrote; the `$finish` line and `run: Time (s): cpu = … ; elapsed = …` are
  only in the console. Copy them into the archive directory by hand.
- A run you stop early. Then copy by hand, before sourcing anything else:

```
X=haifuraiya/platforms/vck190/sim/mdt_vck190_sim_project/mdt_vck190_sim.sim/sim_1/behav/xsim
A=haifuraiya/platforms/vck190/sim/logs/<bench>_<date>_<time>_stopped
mkdir -p $A && cp $X/simulate.log $X/*.txt $X/*.wdb $A/
```

To look at an archived waveform later, in the Vivado Tcl console:
`open_wave_database <archive>/<bench>_behav.wdb` then
`open_wave_config <your saved .wcfg>`. "Save Waveform Configuration" in the
GUI saves only the `.wcfg` (which signals, how displayed), never the data;
the data is the `.wdb`, and it is only there if it was copied.


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
- A cross compiler for the board's software (dōgu). Two levels: Vitis's
  `aarch64-linux-gnu-gcc` (on PATH after `source
  /tools/Xilinx/Vitis/2022.2/settings64.sh`) builds plain-C tools such as
  `opv_play` with no sysroot at all, and is all tier 1 and tier 2 need.
  dōgu's full `make cross` (libiio, `dma_listen`) additionally needs the
  PetaLinux SDK sysroot at `~/petalinux-sdk/sysroots/`, which a rebuilt
  chococat does not have (2026-11-10); generate it from this project
  (`petalinux-build --sdk`, then `petalinux-package --sysroot -d
  ~/petalinux-sdk`, an hour or more) when the ADRV9002 tools are wanted
  on this machine.

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
10.73.1.17 (static), login `root`, password `root` (from `rootfs_config`,
`CONFIG_ADD_EXTRA_USERS="root:root;…"`; the ZCU102 and libreSDR images use
`analog`, this one never has). The root filesystem is a RAM disk, so the
ssh host key is new every boot (the `ssh-keygen -R` is not optional) and
**nothing copied to the board survives a boot** — `opv_play` and the
stimulus go over again every time.

The board's USB cable (J207) presents four FTDI channels; channel A is JTAG
and has no tty (Vivado's hardware server takes it), so on chococat they are
`ttyUSB1` = Versal UART0 (the Linux console, 115200), `ttyUSB2` = Versal
UART1, `ttyUSB3` = the System Controller's console by the channel order —
silent on this board even with the controller running; reach it by
Ethernet instead (BEAM on port 50002, or `ssh`; T4). The libreSDR on the same host shows up the same
way as "Xilinx Debugger DebugChannel" on `ttyUSB5–7`.
`udevadm info -q property /dev/ttyUSBn | grep ID_SERIAL` tells them apart.

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
(it needs the PetaLinux SDK sysroot, step 0), so build the one tool
directly with the Vitis cross compiler, then deploy:

```
source /tools/Xilinx/Vitis/2022.2/settings64.sh     # puts aarch64-linux-gnu-gcc on PATH
cd ~/dogu
make -C tools/opv_play CC=aarch64-linux-gnu-gcc     # the Makefile defaults to the host cc
file tools/opv_play/opv_play                        # must say aarch64
make deploy-vck190
cd -
```

`opv_play` finds the receiver's registers by the UIO device's name
(`haifuraiya_rx_axi` under `/sys/class/uio/*/name`), never by number: the
kernel numbers UIO devices in device-tree order, and on the tier-2 image
the link block sorts first (`/dev/uio0`) and the receiver is `/dev/uio1`.

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

## How to Build and Run the Digital Loopback (tier 2)

_Designed and benched 2026-11-09, built and **passed on the board
2026-11-10** (`ESISTREAM_NOTES.md` §4.2; transcript
`sim/logs/hw_tier2_20261110_2325.txt`). Every step below has been run on
chococat and the board as written. Same board, same cable, no card in the
FMC slot._

Tier 2 is tier 1 with the samples taking the long way round: pacer → Teledyne
ESIstream TX → a GTY transceiver pair talking to itself (near-end PMA
loopback) → Teledyne ESIstream RX → receiver. The receiver, `opv_play`, the
stimulus and the grade are unchanged. What is new: one more register block
at 0xA403_0000 (the link's status and scoreboard), two make targets, one
constraints file, a device-tree node that sets the transceiver's reference
clock at boot, and one `opv_play -r` per boot.

### T1. Build the block design only (minutes; no license needed)

```
make vck190-project-esi
```

Expect, in `haifuraiya/platforms/vck190/syn/vck190_project_esi.log`:

```
grep "INFO: tier\|INFO: M_AXI_FPD\|validate\|CRITICAL WARNING" haifuraiya/platforms/vck190/syn/vck190_project_esi.log
```

the tier banner (`INFO: tier 2 -> project mdt_vck190_playback_esi`), the
three tier-1 addresses plus `0x000A4030000` for the link, and the one
cosmetic 3-bit-port warning from tier 1. Anything else critical: stop and
look; the GT IP is new to this design and this step is where it will
complain. The block design has the tier-1 cells plus one hierarchy,
`esi_link`, holding `esi` (our module), `gt_bridge_ip`, `gt_quad_base`, the
two `bufg_gt`s, the refclk buffer and two constants.

### T2. Build the bitstream and XSA (license required)

```
make vck190-xsa-esi
```

Writes `mdt_vck190_playback_esi.xsa`, `timing_summary_esi.rpt`,
`utilization_esi.rpt`; the tier-1 XSA is untouched. Read the timing summary
as in step 5: `clk_pl_0` as before, and now two more clocks from the quad
(the TX and RX user clocks, 6.400 ns) with their own paths — Teledyne's RX
at 156.25 MHz is the new timing question. The three clock groups are
declared asynchronous to each other (`syn/vck190_esi_link.xdc`); a failing
path *between* them means a crossing was missed, not that the clock is too
fast.

### T3. Import, build, boot

Exactly steps 7–9 with the tier-2 XSA named:

```
make vck190-import-xsa VCK190_XSA=haifuraiya/platforms/vck190/syn/mdt_vck190_playback_esi.xsa
make vck190-build
# power-cycle the VCK190, wait 30 s, then:
make vck190-boot
ssh-keygen -R 10.73.1.17
scp ~/dogu/tools/opv_play/opv_play root@10.73.1.17:/home/root/     # every boot: RAM root filesystem
ssh root@10.73.1.17 /home/root/opv_play -l                          # expect 0xEEF: the block reset the transceiver itself (T4)
```

`vck190-check-xsa` still looks for the receiver at 0xA4010000, which tier 2
also has. `petalinux/system-user.dtsi` refers to the link block by the
label the device-tree generator gives the cell `playback_i/esi_link/esi`,
`esi_link_esi` (confirmed 2026-11-10). The generated `pl.dtsi` is only
written during the build, not the import, so to see it before committing
to the full build:

```
cd haifuraiya/platforms/vck190/petalinux/mdt_vck190 && petalinux-build -c device-tree && cd -
grep -n "@a40" haifuraiya/platforms/vck190/petalinux/mdt_vck190/components/plnx_workspace/device-tree/device-tree/pl.dtsi
```

Expect `esi_link_esi: esi_link_hw@a4030000` beside `rx:
haifuraiya_rx_axi@a4010000`. (A tier-1 import has no such node and the
`&esi_link_esi` reference would fail the device-tree build: comment it out
when going back to a tier-1 image.) On the booted board,
`cat /sys/class/uio/uio*/name` lists `esi_link_hw` and
`haifuraiya_rx_axi` — in that order, as `/dev/uio0` and `/dev/uio1`.

### T4. The GT reference clock — set by the image, nothing to do

The quad's reference clock is the board's user SI570 (U205, through the
SI53340 buffer onto AB11/AB10, jumper J306 off = default). It **powers up at
100.000 MHz** and the design needs **156.25 MHz** (10.0 Gb/s = 64 × 156.25
MHz, and the EV12AQ600's SSO for tier 3). The oscillator sits on the
Versal's own PMC I2C0 (`i2c2`, `f1000000`) behind TCA9548A switch U33,
channel 6, I2C address 0x5F (UG1366, "PMC MIO 46-47 I2C0 Bus"), and
`petalinux/system-user.dtsi` describes it as a `silabs,si570` clock with
`clock-frequency = <156250000>`: the kernel's `clk-si570` driver programs
it at every boot. Check on the board:

```
dmesg | grep -i "si570\|pca954"
```

```
pca954x 2-0074: registered 8 multiplexed busses for I2C switch pca9548
si570 9-005f: registered, current frequency 156250000 Hz
```

(The System Controller — the board's separate management processor, a
Zynq UltraScale+ with its own Linux on the microSD card in its own slot,
and I2C access to the same oscillator — is AMD's documented way to set
this clock, through its BEAM web page. It is not needed for the clock. It
*is* the way to read the board's power rails and to set VADJ for tier 3,
and it is reachable: on the lab network (static address being set; it was
10.73.1.103 by DHCP on 2026-11-11), BEAM at `http://<address>:50002` and
`ssh` with the `petalinux` user. Its serial console on `ttyUSB3` has never
answered; don't spend time on it. `VADJ_FMC` reads 1.5 V with the slots
empty at every power-up — what the Teledyne card wants; BEAM's "set on
boot" control does not persist anything (measured), so for tier 3 read
the rail with the card in and set "current" if needed.
Note for anyone reading `ifconfig` on the Versal: `eth0` *and* `eth1`
there are both the Versal's own MACs, not the System Controller.)

One consequence, and how it is handled: Linux programs the oscillator
long after the PL came out of reset, so a transceiver reset at a fixed time
after PL reset would run against 100 MHz and never lock (it did, on
2026-11-10, and `opv_play -r` — a manual reset through the link's register
— was the workaround). Since the build of 2026-11-11 the link block
watches a copy of the reference clock and resets the transceiver **when
the clock becomes good** (`ESISTREAM_NOTES.md` §4.2, "the qualified
reset"): nothing to do after boot. `opv_play -l` shows it —
`refclk_valid=1`, `ESI_REFCLK_PERIOD 655 (reference clock 156.25 MHz)`,
`ESI_REFCLK_GOOD_EVENTS 1`. **Verified on the board 2026-11-11 15:52**
(`sim/logs/hw_tier2_20261111_1552.txt`): straight after boot, nothing
touched, `opv_play -l` read exactly that, and the playback passed 24/24
with the same table as the day before. `-r` remains for experiments.

### T5. Look at the link before the first run

`opv_play` is the only thing that reads the link's registers (dōgu
`tools/opv_play`, step 10 builds and deploys it). `opv_play -l` reads the
link without playing; `-r` resets the transceiver by hand (T4; not needed
since the 2026-11-11 build). Measured 2026-11-11 15:52, straight after
boot, nothing touched:

```
$ dmesg | grep si570
[    6.376577] si570 9-005f: registered, current frequency 156250000 Hz
$ opv_play -l
ESI_STATUS 0x00000EEF  CONTROL 0x00000020  (loopback mode 2)
  gt_powergood=1 lcpll_lock=1 tx_resetdone=1 rx_resetdone=1 gt_link_status=0 xcvr_ready=1 lanes_ready=1 link_ready=1 snapshot_busy=0 tx_clk_alive=1 rx_clk_alive=1 refclk_valid=1
ESI_SAMPLES_SENT 0  ESI_SAMPLES_RCVD 0  (equal)
ESI_SEQ_ERRORS 0  ESI_MARKER_ERRORS 0  ESI_MULTI_ERRORS 0  ESI_LINK_DROPS 0
ESI_REFCLK_PERIOD 655  (reference clock 156.34 MHz; 156.25 expected)  ESI_REFCLK_GOOD_EVENTS 1
tx_clk / PL clock over 20008025 PL clocks = 1.5625  (156.25 MHz / 100 MHz = 1.5625; 1.0000 = SI570 still at 100 MHz)
```

`0xEEF` is the healthy word: every bit but 4. (`gt_link_status`, bit 4, is
the bridge's own link indicator for its protocol modes and stays 0 in
bypass mode; it is not part of the pass. The "156.34 MHz" is the
655-count's resolution, not the oscillator; the 1.5625 ratio over 20
million clocks is the precise figure.) The 2026-11-10 build, before the
clock monitor, read `0x001` here and needed `opv_play -r` to reach
`0x6EF`; that transcript is `sim/logs/hw_tier2_20261110_2311_linkup.txt`. Reading the failures: ratio 1.0000 =
the oscillator is at 100 MHz (the device tree did not take — check
`dmesg` as in T4); `lcpll_lock=0` with both clocks alive after `-r` is the
2026-11-10 miswiring, fixed in `8f1d612` (the lock signal must be the
quad's `hsclk0_lcplllock`, not the bridge's `lcpll_lock_out`);
`xcvr_ready=1` but `lanes_ready=0` would mean the serial path is not
closing — the CONTROL register's loopback mode (bits 6:4; 1 = near-end PCS,
no analog path) is the experiment, and `opv_play` has no switch for it on
purpose: that would be a finding to record and an option to add, not a
reason to poke the register by hand.

### T6. Run the playback and read both scoreboards

Step 10 unchanged — same `opv_play -q` command, same grader, same 24/24.
With the tier-2 image loaded, `opv_play` refuses to start until the link is
ready and prints the link's scoreboard after the receiver's readbacks.
Pass for tier 2 = the grade table from step 10 **and**
ESI_SAMPLES_SENT = ESI_SAMPLES_RCVD = 20,799,760 (the 25-frame stimulus
file; the simulation's 20,829,760 included the bench's 30,000-sample tail),
ESI_SEQ_ERRORS = ESI_MARKER_ERRORS = ESI_MULTI_ERRORS = 0, ESI_LINK_DROPS = 0.

Measured 2026-11-10 23:25 (`sim/logs/hw_tier2_20261110_2325.txt`): 24/24
decodable, pre-FEC BER 0.00–0.56 % — the tier-1 table — CFO 498 Hz,
SYM_CLK_OFFSET −11.39 ppm, 24 frames, 0 dropped; 20,799,760 sent =
20,799,760 received, all link error counters 0, no link drops. Recorded in
`ESISTREAM_NOTES.md` §4.2 and the tier table in `VCK190_PLAYBACK_PLAN.md`;
do the same for the next run that changes anything.

Commands that worked (after a power cycle and `make vck190-boot`)

```
ssh-keygen -R 10.73.1.17
scp ~/dogu/tools/opv_play/opv_play root@10.73.1.17:/home/root/
ssh root@10.73.1.17 'dmesg | grep si570; /home/root/opv_play -l'
```

and then

```
scp /tmp/opv_chan_stim.bin root@10.73.1.17:/home/root/
ssh root@10.73.1.17 '/home/root/opv_play -i /home/root/opv_chan_stim.bin -o /home/root/soft.bin -q'
scp root@10.73.1.17:/home/root/soft.bin /tmp/ && python3 haifuraiya/platforms/vck190/tools/opv_soft_bin2txt.py /tmp/soft.bin /tmp/soft.txt && python3 haifuraiya/sim/grade_payload_ber.py /tmp/soft.txt --stim-dir haifuraiya/sim
```


### T7. The link's unit test, on chococat

The wrapper (`esi_link_hw`: registers, snapshot, two link clocks against the
PL clock) has a bench of its own under nvc, alongside the link bench of
step "How to Simulate".

```
haifuraiya/platforms/vck190/sim/esi/run_esi_link_hw_nvc.sh      # pass = PASS: tb_esi_link_hw, about a minute
haifuraiya/platforms/vck190/sim/esi/run_esi_link_hw_ghdl.sh     # the same under GHDL 4.x; either one is the record
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
- 2026-11-05: the runner's tier switch was a Tcl global that survived
  between `source`s; a "tier 1" run was tier 2 for a day. Now consumed and
  unset on every source. Check the `Tier:` banner line anyway, and the
  Scope window's top-level name before walking away.
- 2026-11-05: the runner deletes the project directory on every source; the
  59-hour tier-2 waveform went with it. Every run archives itself now.
- 2026-11-05: Vivado's `run: Time` cpu figure is the Vivado process (8 % of
  elapsed); `xsimk` was at 100 % the whole time. Use `top`.
- 2026-11-05: a `git worktree` has no submodules; the bisect script's first
  version failed every point in a minute and then waited twenty for output.
- 2026-11-05: an orphaned `xsimk` from mid-October was still holding its
  deleted output files open; `/proc/<pid>/fd/` gave them back. Kill
  orphans after rescuing, not before.
- 2026-11-07: the two runners differ by four letters; the tier-1 one was
  sourced for a tier-2 test and 3.5 hours went to a clean but unwanted
  tier-1 run. `run_mdt_vck190_esi_sim.tcl` is the only thing to source for
  tier 2.
- 2026-11-08: the shared bench's `wait for 2 us` before the burst landed
  exactly on a clock edge; the first `tvalid` rose in the same delta as
  `aclk` and the core's combinational `sample_valid_int` missed `stim[0]`.
  Every simulation before this ran on the inverted halfband decimation
  phase. Found because the ESIstream link's input FIFO caught the sample
  and the two tiers disagreed by exactly 14.06° (one 20 MSps sample at
  781.25 kHz); the golden channelizer model put tier 2 on the designed
  phase; a byte-identical re-run after the fix proved it. Fix:
  `wait until rising_edge(aclk)` after the `wait for` (two places).
- 2026-11-09: the whole-file delivery of the ESI bench on 2026-11-08 was
  built from a base one commit too old and silently put `NB_LANES => 8` back
  (the 2026-11-07 commit had made it 2). Caught while splitting the link
  clocks; it is 2 again. Whole-file deliveries need a `git diff --stat`
  against HEAD before committing, not just a look at the hunk you asked for.
- 2026-11-09: `vck190_playback_project.tcl` still listed `axi_mon_tap.vhd`
  (deleted 2026-11-02) and counted it, so `make vck190-project` would have
  failed the manifest check. Removed from the list; the count is 35 (+23
  for tier 2).
- 2026-11-09: Vivado's GUI froze on the GT bridge's block automation and the
  journal was never flushed, so the session left no record. The GT work is
  done in batch scripts (`syn/gt_scratch.tcl`) that print what they find;
  the IP's block-automation rule names are not public, so the GT pair is
  built cell by cell from Teledyne's block design instead.
- 2026-11-10: `git clean -f <path>` removes **every** untracked file under
  the path and, with a path given, descends into untracked directories —
  it took the PetaLinux template's empty `recipes-apps/` along with the six
  files it was meant for. Harmless that time; the rule is `git clean -n`
  first and read the list, and to withdraw a delivery name the files, not
  the directory.
- 2026-11-10: a patch cut against `HEAD` was handed over after the previous
  day's whole-file delivery had already been applied to the tree; it could
  not apply. Every patch states the commit it applies to, and the tree is
  checked against that commit before applying.
- 2026-11-10: the uncommitted `opv_play` on chococat was the version that
  passed on 2026-10-25 (`RX_AHEAD`, `-L`), newer than the one on GitHub; a
  patch cut against GitHub would have landed in the wrong places. The
  passing version was committed first, on its own, then the new work on
  top.
- 2026-11-10: `opv_play` opened `/dev/uio0` for the receiver; on the tier-2
  image `/dev/uio0` is the link (the kernel numbers UIO devices in
  device-tree order, alphabetical from the generator). Both are found by
  name now.
- 2026-11-11: the System Controller "not running / no card in its slot"
  was an inference from a silent serial console, written as fact. The
  card was there and it was running; Ethernet (UG1573's back-to-back
  procedure) reached BEAM and `ssh` in minutes. A silent port is evidence
  about the port.
- 2026-11-10: the GT reference clock (user SI570) powers up at 100 MHz, the
  System Controller that normally sets it was dark on its console, and
  nothing in the kernel's VCK190 board file describes the I2C clock tree.
  UG1366's I2C0 table gave the path (switch U33 at 0x74, channel 6, 0x5F) on
  the Versal's own bus; a `clk-si570` node in `system-user.dtsi` sets it at
  every boot. The fabric's power-up transceiver reset comes before that, so
  one `opv_play -r` per boot until the block retries by itself.
- 2026-11-10: the bridge's `lcpll_lock_out` never asserts in bypass mode.
  Resetdone high and the user clock measured at exactly 1.5625 × the PL
  clock said the PLL was locked while the bit said it was not; the quad's
  `hsclk0_lcplllock` is the signal (Teledyne's wrapper uses it). The
  block's clock counters were put in for exactly this kind of question.
- 2026-11-10: a JTAG re-boot without a power cycle fails ("Configuration
  timed out waiting for DONE") — the 2026-10-25 lesson again, and it cost
  the quick "reset after clock" experiment, which then needed `-r` in
  `opv_play` instead. Power cycle, 30 s, boot: there is no shortcut.
- 2026-11-11: `i2cdetect` "not found" over `ssh` was PATH: it is
  `/usr/sbin/i2cdetect`, and a non-interactive `ssh` shell does not have
  `/usr/sbin` on its PATH. The rootfs line had worked.
- 2026-11-11: `opv_play` run again on a board that had already run once
  (no reboot in between) delivered 0 frames — frame sync gone, CFO at the
  rail — while the link underneath was perfect (41.6 million samples, no
  errors). `opv_play` does not reset the receiver; step 10 says reboot
  between runs; it now refuses on a warm receiver unless told `-w`.
- 2026-11-11: `make vck190-boot` failed with "PLM stalled during
  programming" and then `xsdb` showed the Versal as a bare `DAP (AXI AP
  transaction error, DAP status 0x30000021)` with no `xcvc1902` entry and
  `plm log` unreadable. Not the image: `pkill -f hw_server`, a full power
  cycle with the 30 s wait, and the next boot went through. If `xsdb
  -eval 'connect; targets'` does not list `Versal xcvc1902`, there is no
  point programming; re-seat the USB cable (J207) and power cycle again.
- 2026-11-11: a test was run against the previous day's bitstream because
  the rebuild had not happened before a meeting. The registers said so
  (`SAMPLES_SENT` already 20,799,760 at the start; the new registers read
  0). Read the counters before believing a run; a fresh boot starts at 0.
