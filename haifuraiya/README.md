# Haifuraiya — 64-channel polyphase channelizer on ZCU102 + ADRV9002

The ground-station channelizer for the ORI Opulent Voice FDMA transponder.
A polyphase filter bank that splits a 10 MSps complex input into 64 channels
at 625 kSps each, running on the Xilinx ZCU102 with an ADRV9002 RF front end.

For an introduction to what a polyphase channelizer is, see the top-level
repository [`README.md`](../README.md). For design history, lessons
learned, and the phase-by-phase status of the project, see
[`haifuraiya_plan_of_attack.md`](haifuraiya_plan_of_attack.md). This
document is the build-and-deploy guide.

For the separate iCE40 + STM32 successive-interference-cancellation
receiver (the other subproject in this repo), see
[`../mdt_sic/README.md`](../mdt_sic/README.md).

---

## Prerequisites

### Tools

| Tool | Version | Required for |
|---|---|---|
| PetaLinux Tools | 2022.2 | All builds and JTAG boot |
| Vivado | 2022.2 | Only when rebuilding the XSA (RTL / IP-XACT / block-design changes) |
| Git | 2.x | With submodule support |
| GNU Make | 4.x | Build orchestration |
| `screen` | any | Serial console access to the ZCU102 |
| `openssh-client` | any | SSH to the ZCU102 after boot |
| `python3-venv` | (optional) | Only if regenerating channelizer coefficients — see [`../docs/README.md`](../docs/README.md) |

PetaLinux Tools 2022.2 is **Linux-only** (officially Ubuntu 18.04/20.04;
works in practice on 22.04). The Makefile and scripts use GNU sed and
other Linux-specific tools — do not attempt to run on macOS.

Source the PetaLinux environment before running any make target:

```bash
source ~/petalinux/2022.2/settings.sh
```

`make haifuraiya-check-env` will verify this for you.

### Submodules

It's complicated. 

Don't clone with --recurse-submodules or run git submodule update --init --recursive at the top level.
It descends into pluto_msk and pulls ADI's multi-GB hdl + linux grandchildren that the ZCU102 build never uses.

# 1. Clone (no blanket --recurse-submodules)
git clone https://github.com/OpenResearchInstitute/Mode-Dynamic-Transponder.git
cd Mode-Dynamic-Transponder

# 2. Direct ADI/ORI submodules -- recursive is safe for these
git submodule update --init --recursive \
    haifuraiya/third_party/hdl \
    haifuraiya/third_party/meta-adi \
    haifuraiya/third_party/power_detector \
    haifuraiya/third_party/lowpass_ema

# 3. pluto_msk: init the submodule, then ONLY the demod-chain leaves
git submodule update --init haifuraiya/third_party/pluto_msk
git -C haifuraiya/third_party/pluto_msk submodule update --init \
    nco pi_controller msk_demodulator

| Submodule | Source | Purpose |
|---|---|---|
| `hdl` | analogdevicesinc/hdl @ `hdl_2022_r2` | ADI's ADRV9002 reference Vivado project (this is where the XSA is built) |
| `meta-adi` | analogdevicesinc/meta-adi @ `2022_R2` | ADI's Yocto layer (kernel drivers, device tree) |
| `power_detector` | OpenResearchInstitute/power_detector | RF power detection used inside the channelizer |
| `lowpass_ema` | OpenResearchInstitute/lowpass_ema | EMA filter primitive (used inside power_detector) |
| `pluto_msk` | OpenResearchInstitute/pluto_msk | OPV MSK demodulator + frame-sync VHDL. Init only nco, pi_controlle>

### Lab setup

| Host | Role | Notes |
|---|---|---|
| Build host | Vivado + PetaLinux installed, repo lives here | Linux, Ubuntu 22.04 known-good |
| `keroppi` | JTAG host | `hw_server` listens on port 3121; ZCU102 connected via JTAG USB and serial USB |
| ZCU102 | Target | Reachable via JTAG over keroppi during boot; on the lab network after Linux comes up |

All make targets are run on the build host. `keroppi` is reached
transparently via the JTAG hw_server URL `TCP:keroppi:3121` baked into
the boot target, and via SSH for the serial console.

---

## Quick start

The cached XSA and PetaLinux hardware description are already in the
repo, so a fresh clone goes straight to a PetaLinux build:

```bash
cd Mode-Dynamic-Transponder

# Source PetaLinux env (in every fresh shell)
source ~/petalinux/2022.2/settings.sh

# Build PetaLinux (auto-runs haifuraiya-check-env and haifuraiya-configure)
make haifuraiya-build

# Power-cycle the ZCU102 (REQUIRED — PetaLinux's boot script assumes a
# freshly-reset board).

# Boot via JTAG over keroppi
make haifuraiya-boot
```

In a second terminal, watch the serial console:

```bash
ssh keroppi 'screen /dev/zcu102_uart1 115200'
```

Once Linux boots, the board is on the lab network and you can SSH to
it. (See [Current limitations](#current-limitations) for the one-time
SSH setup step needed on first boot.)

For the full list of targets and their descriptions:

```bash
make help
```

---

## Make targets

All targets are run from the repository root.

### Routine workflow

| Target | Purpose |
|---|---|
| `haifuraiya-build` | Configure + petalinux-build + package. Produces `BOOT.BIN`, `image.ub`, and populates `pre-built/linux/images/`. Auto-depends on `haifuraiya-check-env` and `haifuraiya-configure`. |
| `haifuraiya-boot` | Boots the ZCU102 via JTAG over keroppi (`petalinux-boot --jtag --prebuilt 3`). Requires the board to have been power-cycled. |
| `haifuraiya-clean` | Wipes `build/`, `images/`, and `pre-built/` from the PetaLinux project. Sources and project-spec are preserved. |
| `haifuraiya-update` | Safely syncs with `origin/main`: reverts local paths → `git pull` → re-configures for this clone. Use this instead of bare `git pull` if you've run `haifuraiya-configure`. |

### Path management

| Target | Purpose |
|---|---|
| `haifuraiya-configure` | Rewrites `CONFIG_USER_LAYER_*` and `HARDWARE_PATH` to point at your local clone. Idempotent. Run automatically by `haifuraiya-build`. |
| `haifuraiya-revert-paths` | Reverts those substitutions back to sentinel placeholders. **Run this before `git commit` if you've ever run `haifuraiya-configure`** — otherwise your local absolute paths leak into the repo. |

### Vivado / XSA rebuild

You only need these when you change RTL, IP-XACT, or the block design.
Otherwise the cached XSA + hardware description in the repo are
sufficient and `haifuraiya-build` works without touching Vivado.

| Target | Purpose |
|---|---|
| `haifuraiya-xsa` | Builds the Vivado project end-to-end (synth + impl + bitstream + XSA export) by invoking ADI's HDL Makefile under `third_party/hdl/projects/adrv9001/zcu102/`. **Takes about 5 hours.** |
| `haifuraiya-import-xsa` | Imports the freshly-built XSA into the PetaLinux project (`petalinux-config --get-hw-description`). Must run after `haifuraiya-xsa` and before `haifuraiya-build`. |

### Environment checks

| Target | Purpose |
|---|---|
| `haifuraiya-check-env` | Verifies PetaLinux Tools is sourced. Run automatically by `haifuraiya-build`. |
| `haifuraiya-check-vivado` | Verifies Vivado is sourced. Run automatically by `haifuraiya-xsa`. |

---

## When to rebuild what

```
       Change                          Required steps
─────────────────────────────────────────────────────────────────
RTL / IP-XACT / block design  ─►  haifuraiya-xsa            (~5h)
                                   haifuraiya-import-xsa     (~1m)
                                   haifuraiya-build          (~30m)
                                   haifuraiya-boot

PetaLinux config / rootfs     ─►  haifuraiya-build          (~30m)
                                   haifuraiya-boot

Just want to rebuild Linux    ─►  haifuraiya-build          (~30m)
on the current XSA                 haifuraiya-boot

Pulled from origin            ─►  haifuraiya-update         (handles
                                                              path
                                                              revert
                                                              cleanly)
                                   haifuraiya-build
                                   haifuraiya-boot
```

---

## Current limitations

Active development items — documented so you know what to expect.

### Missing SSH on first boot (meta-ori orphan layer)

`haifuraiya/yocto/meta-ori/` contains recipes to add `openssh` and a
static IP configuration to the rootfs. The layer is not currently
registered as `CONFIG_USER_LAYER_2`, so the recipes are not parsed
during the PetaLinux build. The rootfs ships with `dropbear` (root
password login disabled by default) and DHCP networking.

**Current workaround**, from the JTAG serial console on first boot:

```bash
sed -i 's/-w//' /etc/default/dropbear
passwd root         # set a password
systemctl start dropbear
```

After this, SSH from the build host works:

```bash
ssh root@<board-IP>
```

**Real fix in progress:** register `meta-ori` as `CONFIG_USER_LAYER_2`
via `petalinux-config`, enable `debug-tweaks` in the rootfs config,
and update `setup-petalinux.sh` and `haifuraiya-revert-paths` to
handle the new layer slot symmetrically.

### ADRV9002 RX/TX not yet configured for sample capture

The ADRV9002 probes cleanly on boot and exposes IIO devices for RX1,
RX2, TX1, and TX2. Capturing samples requires a profile configuration
(JSON from ADI's Transceiver Evaluation Software), running initial
calibrations, and arming the buffer — none of which are currently
automated. `iio_readdev` will block waiting for samples that never
arrive until this sequence is run.

The workflow is standard ADI; see
[the ADRV9002 user guide](https://wiki.analog.com/resources/eval/user-guides/adrv9002).
Automating the sequence for haifuraiya is on the project roadmap.

---

## Verification checks after a successful boot

Once the board boots and you have a shell (serial or SSH):

```bash
# ADRV9002 driver probed successfully
dmesg | grep adrv9002

# Channelizer AXI-Lite responds at its base address
# (Exact address depends on the current build; check
#  the device tree or component.xml.)
devmem 0x84A70014 32     # expect 0x10  (DATA_WIDTH = 16)
devmem 0x84A7001C 32     # expect 0x40  (N_CHANNELS = 64)

# IIO devices enumerate
# (expect: ams, adrv9002-phy, two axi-adrv9002-rx*-lpc,
#  two axi-adrv9002-tx*-lpc, two axi-core-tdd)
for d in /sys/bus/iio/devices/iio:device*; do
    echo "$d: $(cat $d/name 2>/dev/null)"
done
```

---

## See also

- [`../README.md`](../README.md) — top-level overview and intro to
  polyphase channelizers.
- [`../docs/README.md`](../docs/README.md) — coefficient generation
  notebook: environment setup and what it produces.
- [`haifuraiya_plan_of_attack.md`](haifuraiya_plan_of_attack.md) —
  design history, phase status, and lessons learned. The detailed
  architecture diagram and engineering notes live here.
- [`../mdt_sic/README.md`](../mdt_sic/README.md) — the separate
  iCE40 + STM32 successive-interference-cancellation receiver.
