# Haifuraiya Yocto Bring-up: Sub-Dungeon Map

*Phase 2b plan of attack for getting from "Petalinux works but we want
Yocto" to "ZCU102 boots Yocto with our Haifuraiya hardware design, mmaps
our channelizer registers, and publishes telemetry via MQTT."*

Scoped to Haifuraiya. This document lives at
`haifuraiya/yocto/yocto_plan_of_attack.md`. MDT-SIC and other ORI projects
have their own Yocto trees (or don't need one); this is the polyphase
channelizer's Linux runtime.

---

## ⚔️ You Are Here

| Status | Item | Notes |
|:-:|---|---|
| ✅ | Phase 1 complete | RTL, IP-XACT v0.1, BD smoke test all done |
| ✅ | Decision: Yocto over Petalinux | Vendor-recommended; matches "deliberate and clean" working style |
| ✅ | Decision: Vivado 2022.2 (locked) | License constraint; pairs with Yocto Honister |
| ✅ | Decision: meta-ori layer scope | Lives at `haifuraiya/yocto/meta-ori/`; per-project (not parent-repo-wide) |
| ✅ | Host packages installed | Ubuntu 22.04 deps via apt; en_US.UTF-8 locale generated |
| ✅ | Build tree `repo init` + `repo sync` | At `~/yocto/haifuraiya/`; all 5 required layers populated at `xlnx-rel-v2022.2` |
| ✅ | Version stack pinned (commit SHAs) | See "Pinned Version Stack" below — all five layers locked |
| ✅ | **M1: vanilla zcu102 Yocto image boots** | **`uname -a`: Linux 5.15.36-xilinx-v2022.2 SMP aarch64. 4GB DDR visible. Gigabit Ethernet up. Root shell achieved via JTAG boot from keroppi.** |
| ✅ | **JTAG deployment recipe established** | **xsdb-based boot via PMU→FSBL→ATF→U-Boot→Linux, fully documented in "JTAG Boot Procedure" below** |
| ✅ | **meta-ori is a real Yocto layer** | **conf/layer.conf, MIT license, README. Registered with bitbake at priority 10. Collection name `ori`. Forward-compat with kirkstone.** |
| ✅ | **First meta-ori recipe: static IP via systemd-networkd** | **`ip addr show eth0` reports `inet 10.73.1.16/24`. ping from keroppi succeeds. systemd-networkd uses /etc/systemd/network/10-eth0.network installed by our recipe.** |
| 🎯 | **Next concrete action** | **Choose: (a) openssh-server recipe in meta-ori for SSH access, OR (b) PXE boot config to eliminate manual setenv+tftpboot+booti typing, OR (c) jump to meta-adi-xilinx + ADRV9002 prep for Phase 2a integration** |
| ⏳ | M2 remainder: add ADI/ADRV9002 layer + device tree | meta-adi-xilinx added to build, kernel includes ADRV9002 driver, `iio_info` lists device |
| ⏳ | M3: image built against Phase 2a .xsa (Haifuraiya in PL) | Hardware design integrated; channelizer in bitstream |
| ⏳ | M4: userspace mmap reads VERSION register = 0x00010000 | Round-trip Linux-to-IP communication confirmed |
| ⏳ | M5: Takadono v0 MQTT publish working | First observability output |

If you're returning to this doc after a hiatus, start at "You Are Here,"
then jump to whichever milestone is the current 🎯.

---

## 🗺️ How This Fits

```
Phase 1 (DONE) ─────────────────────────────────────┐
  Channelizer RTL, IP-XACT v0.1, BD smoke test       │
                                                     │
                                                     ▼
                                          ┌──────────────────┐
Phase 2a (in parallel) ─────▶ .xsa  ───▶ │ Yocto image      │
  Vivado: ADRV9002 + Haifuraiya          │ - kernel for PS  │
  block design                            │ - bitstream      │
                                          │ - device tree    │
Phase 2b (this doc) ─────────────────────▶│ - userspace      │
  Yocto bring-up                          └──────────────────┘
                                                     │
                                                     ▼
                                          ZCU102 boots, samples flow,
                                          registers mmap'able from
                                          userspace, MQTT publishing
                                          channelizer state.
                                                     │
                                                     ▼
                                          Phase 3 (First Light):
                                          point at real RF, verify
                                          channels behave correctly
```

Phase 2a and Phase 2b are **independent until the `.xsa` export from
Phase 2a is fed into the Yocto build**. They can be worked in parallel,
serialized, or interleaved — whatever works on a given evening at the
bench.

---

## 📦 Pinned Version Stack

The first commandment of "deliberate and clean Yocto" is to **pin every
version**. Yocto builds drift over time; what built yesterday may not
build today if upstream meta layers move. Pin commits, document them
here.

### Tool versions

| Layer | Pin | Rationale |
|---|---|---|
| Vivado | **2022.2** | License-constrained |
| Yocto release | **Honister (3.4)** | What xlnx-rel-v2022.2 actually pulls (despite Kirkstone being available at the same time). Verify with: `grep LAYERSERIES_COMPAT_core sources/core/meta/conf/layer.conf` |
| Xilinx manifest | **`rel-v2022.2`** from `github.com/Xilinx/yocto-manifests.git` | AMD-recommended, pulls a consistent layer set |
| Host OS | **Ubuntu 22.04 LTS** | Yocto Honister's primary supported host (note: 22.04's glibc 2.35 vs Honister uninative's 2.34 — handled automatically, see Trophy Case) |
| `repo` tool | latest from Google | Self-updating |

### Layer pins (captured after first `repo sync` on 2026-05-17)

All layers tagged `xlnx-rel-v2022.2`:

| Layer | Commit SHA | Last commit message |
|---|---|---|
| `core` | **e309c80a51** | "bitbake: utils: Fix lockfile path length issues" |
| `meta-openembedded` | **5d871d57b** | "Merge remote-tracking branch 'honister' into 2022" |
| `meta-xilinx` | **2e60ee606** | "xwayland: Add xkbcomp runtime dependency" |
| `meta-xilinx-tools` | **909b70c** | "Add new YAML_BSP_CONFIG for apu overlay config" |
| `meta-petalinux` | **5799be30** | "Revert: xilinx-mirrors.conf TEMPORARY mirrors" |
| `meta-adi-xilinx` | _(TBD — pin when added in M2)_ | Cloned separately; not in AMD manifest |

### How to refresh these pins (for future you)

```bash
cd ~/yocto/haifuraiya/sources

for layer in core meta-openembedded meta-xilinx meta-xilinx-tools meta-petalinux; do
    if [ -d "$layer" ]; then
        echo "=== $layer ==="
        cd $layer
        git log -1 --oneline
        echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
        echo ""
        cd ..
    fi
done
```

**Important nomenclature note:** AMD's manifest names `poky/` as `core/`.
The directory contains oe-core, bitbake, AND meta-poky (the reference
distro definition — yes, this IS activated in bblayers.conf, contrary
to a common assumption). What's NOT included is meta-yocto-bsp; Xilinx
provides machine support via meta-xilinx-bsp instead.

### Caveat worth knowing

Yocto Honister was a regular (non-LTS) release that reached upstream
end-of-life in 2022. Xilinx continued patching it through their xlnx-rel
branches, which is what we're pinned to. Community-extended security
patches are minimal. For our use case — an FPGA dev/deployment host with
no internet-facing exposure — this is fine. Pin commits explicitly, document
workarounds inline, treat as our stable platform. The next Xilinx release
(2023.x) moved to Yocto Langdale; jumping to that would mean migrating
all our work, so we stay on 2022.2/Honister until there's a compelling
reason to upgrade.

---

## 📚 What AMD's Manifest Actually Pulled

AMD's `setupsdk` is aggressive: it activates **every layer** in the
manifest by default. Activation means bitbake parses the layer's recipes
and applies any .bbappend files; it does NOT mean recipes from that
layer end up in your image. Most activated layers are "available but
silent" for our use case.

### All layers activated by AMD setupsdk (37 entries)

These appear in `bblayers.conf` after running setupsdk:

**Contributes recipes to petalinux-image-minimal:**
- `core/meta` (oe-core)
- `core/meta-poky` (reference distro definition)
- `meta-openembedded/meta-oe`, `meta-python`, `meta-networking`, `meta-webserver`, `meta-multimedia`, `meta-filesystems`, `meta-perl`, `meta-initramfs`
- `meta-xilinx/meta-xilinx-core`, `meta-xilinx-microblaze`, `meta-xilinx-bsp`, `meta-xilinx-standalone`, `meta-xilinx-vendor`, `meta-xilinx-contrib`
- `meta-xilinx-tools`
- `meta-petalinux`

**Activated but silent in our image** (parsed but no recipes used):
- `meta-openembedded/meta-gnome`, `meta-xfce` (desktop environments — we don't use)
- `meta-xilinx/meta-xilinx-pynq` (PYNQ Python/Jupyter on Xilinx — academic use)
- `meta-clang` (LLVM/Clang toolchain — alternative to GCC, we use GCC)
- `meta-browser/meta-chromium` (Chromium web browser)
- `meta-qt5` (Qt5 framework — we don't have a GUI)
- `meta-virtualization` (Xen/KVM/containers)
- `meta-openamp` (asymmetric multiprocessing — R5F use case)
- `meta-jupyter` (JupyterLab on target — useful in M3+)
- `meta-vitis` (Vitis HLS/AI acceleration)
- `meta-python2` (Python 2 legacy support)
- `meta-som` (Kria SoM-specific support)
- `meta-security`, `meta-security/meta-tpm` (hardening + TPM)
- `meta-xilinx-tsn` (Time-Sensitive Networking)
- `meta-ros/meta-ros-common`, `meta-ros2`, `meta-ros2-humble` (Robot Operating System)

**Pulled by repo sync but NOT activated** (rare):
- (most things in the manifest end up activated; this category is small)

### Why activate all 37 instead of a minimal subset?

Inactive layers can still provide .bbappend files that affect builds
silently. Removing a layer can cause subtle recipe behavior changes that
are hard to trace. Safer to keep the full AMD-recommended set active and
only add layers (never remove).

For our use case the practical impact is small: parse time is slightly
longer at the start of each build, but no extra recipes get built into
the rootfs. The image stays minimal regardless.

---

## 🖥️ Build Host Setup

### Hardware (verified during M1 build on `mymelody`)

| Resource | Used during M1 build | Recommendation |
|---|---|---|
| Disk | ~50 GB consumed (downloads/, tmp/, sstate-cache/) | Have 100+ GB free |
| RAM | sufficient on host | 16 GB+ recommended |
| First-build time | ~4 hours | One evening; tee output to log |
| Subsequent build time | ~10-15 minutes for image changes | sstate cache pays off massively |

### Required packages (✅ documented working)

```bash
sudo apt update && sudo apt install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev \
    python3-subunit mesa-common-dev zstd liblz4-tool file locales \
    libacl1

sudo locale-gen en_US.UTF-8

# repo tool (not in apt)
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH="$HOME/bin:$PATH"
```

### 📍 Path conventions (watch points)

Two host-path patterns appear throughout this plan; if they change in the
future, search-and-replace will be needed.

**Color-name container directory.** The repo working tree currently lives
under `~/brown/Mode-Dynamic-Transponder/` on `mymelody`. Earlier
development used `~/orange/`. The color is just a container directory
convention for development repos and may change. **If the active color
changes, every absolute path in this document and in the scripts/
referencing `~/brown/` needs to be updated.** Watch points:
- `meta-ori` symlink target in `~/yocto/haifuraiya/sources/`
- `scripts/copy_to_keroppi.sh` source paths
- M2 layer-activation commands below
- The example commands in JTAG Boot Procedure

**Yocto build tree.** The build tree is at `~/yocto/haifuraiya/` (NOT
under `~/brown/`). This is intentional: build artifacts are huge and
regenerable, so they live separately from the source-controlled repo.

### ⚠️ Common setupsdk pitfall

**ALWAYS source setupsdk from the project root** (`~/yocto/haifuraiya/`),
never from inside an existing `build/` directory. If you source it from
inside `build/`, it creates a nested `build/build/` and you end up in
the empty one with no config. Recovery: `cd` to project root, `rm -rf
build/build`, re-source from project root.

---

## 📁 Directory Layout

Two distinct trees: what's in git (small, reviewable) vs. what's on disk
(huge, regenerable).

### In the repo (`haifuraiya/yocto/`)

```
haifuraiya/yocto/
├── yocto_plan_of_attack.md          # this doc
├── conf/                             # build configuration templates
│   ├── README.md                     # how to use the templates
│   ├── local.conf.template           # M1-validated local.conf settings
│   └── bblayers.conf.template        # M1-validated layer activation
├── meta-ori/                         # our custom Yocto layer
│   ├── conf/
│   │   └── layer.conf                # NEW: makes it a real layer (M2 task)
│   ├── recipes-core/
│   │   └── images/                   # custom image recipes (TBD)
│   ├── recipes-network/              # NEW: static IP systemd dropin
│   │   └── systemd-network/
│   ├── recipes-takadono/             # Takadono v0 publisher (M5)
│   └── recipes-haifuraiya/           # channelizer device tree fragments (M3)
├── scripts/
│   ├── copy_to_keroppi.sh            # ✅ working
│   ├── zcu102_jtag_boot.tcl          # ✅ working (after Phase 2b debug)
│   ├── run_jtag_boot.sh              # ✅ working
│   └── (more as we add automation)
└── .gitignore                        # belt-and-suspenders gitignore
```

### On disk, out of repo (`~/yocto/haifuraiya/`)

```
~/yocto/haifuraiya/                   # NOT in git
├── .repo/                            # repo tool metadata
├── sources/                          # meta layers populated by repo sync
│   ├── core/                         # oe-core + bitbake
│   ├── meta-openembedded/
│   ├── meta-xilinx/
│   ├── meta-xilinx-tools/
│   ├── meta-petalinux/
│   ├── meta-adi/                     # added separately in M2
│   ├── (many other meta-* layers, inactive by default)
│   ├── yocto-scripts/                # contains setupsdk
│   ├── manifest/                     # repo metadata
│   └── meta-ori -> /home/abraxas3d/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/meta-ori
│                                     # symlinked from repo
└── build/                            # bitbake's working tree
    ├── conf/                         # bblayers.conf, local.conf
    ├── tmp/                          # build artifacts (MASSIVE)
    ├── downloads/                    # fetched source (LARGE)
    └── sstate-cache/                 # build cache (LARGE)
```

---

## 🏗️ Layer Stack

AMD setupsdk activates 37 layers total (see "What AMD's Manifest Actually
Pulled" above for the full list). Of those, the layers that actually
contribute recipes to our `petalinux-image-minimal` form this dependency
chain:

```
core/meta + core/meta-poky    (oe-core + bitbake + reference distro)
  └── meta-openembedded     (meta-oe, meta-python, meta-networking,
                             meta-webserver, meta-multimedia,
                             meta-filesystems, meta-perl, meta-initramfs)
       └── meta-xilinx       (AMD/Xilinx hardware support: meta-xilinx-core,
                              meta-xilinx-microblaze, meta-xilinx-bsp,
                              meta-xilinx-standalone, meta-xilinx-vendor,
                              meta-xilinx-contrib)
            └── meta-xilinx-tools     (XSCT-dependent baremetal recipes)
                 └── meta-petalinux    (petalinux-image-minimal recipe)
                      └── meta-adi-xilinx     (M2: ADRV9002 driver, libiio,
                                               device trees — TBD)
                           └── meta-ori        (M2+: static IP, Takadono
                                                publisher, channelizer DT)
```

The other ~20 layers (meta-ros, meta-vitis, meta-jupyter, meta-virtualization,
meta-qt5, etc.) are activated but don't contribute recipes to our image.
They're parsed during the build but silent in the output.

Optional additions later:
- **`meta-jupyter` contribution** in M3/M4 if interactive debugging would help
  (the layer is already activated; we just don't currently pull recipes from it)
- **`meta-security` contribution** in Phase 5+ when going on a real public
  network

### 📛 Layer collection name reference

Yocto layers have TWO names: the **directory name** (visible in the filesystem
and bblayers.conf paths) and the **collection name** (declared by each
layer's own `BBFILE_COLLECTIONS` and used in `LAYERDEPENDS`, recipe
overrides, etc.). These often differ. Mixing them up makes
`bitbake-layers add-layer` fail with cryptic errors.

For our active layer set:

| Directory name | Collection name |
|---|---|
| `core/meta` | `core` |
| `core/meta-poky` | `yocto` |
| `meta-openembedded/meta-oe` | `openembedded-layer` |
| `meta-openembedded/meta-python` | `meta-python` |
| `meta-openembedded/meta-networking` | `networking-layer` |
| `meta-openembedded/meta-webserver` | `webserver` |
| `meta-openembedded/meta-multimedia` | `multimedia-layer` |
| `meta-openembedded/meta-filesystems` | `filesystems-layer` |
| `meta-openembedded/meta-perl` | `perl-layer` |
| `meta-xilinx/meta-xilinx-core` | `xilinx` |
| `meta-xilinx/meta-xilinx-bsp` | `xilinx-bsp` |
| `meta-xilinx/meta-xilinx-standalone` | `xilinx-standalone` |
| `meta-xilinx-tools` | `xilinx-tools` |
| `meta-petalinux` | `petalinux` |
| `meta-ori` (ours) | `ori` |

To find the collection name of any layer:
```bash
grep BBFILE_COLLECTIONS sources/<layer>/conf/layer.conf
```

When declaring `LAYERDEPENDS_<ours>` or recipe overrides, **always use
collection names**.

---

## 🎯 Milestones

Each milestone is a "stop here, save state, commit, take a break"
checkpoint. The deliberate-and-clean working style: prove M_N before
attempting M_N+1.

### M1: Vanilla zcu102 Yocto image boots ✅ COMPLETE (2026-05-17/18)

**Goal achieved:** prove the build environment + JTAG deployment + boot
chain all work end-to-end. No custom hardware, no ADI layers, no
Haifuraiya — just stock AMD content booted via JTAG.

**Critical local.conf additions for M1:**
```
# Source mirror — required to handle upstream SHA drift on first build
SOURCE_MIRROR_URL ?= "http://sources.yoctoproject.org/releases/"
INHERIT += "own-mirrors"
BB_GENERATE_MIRROR_TARBALLS = "1"

# Skip image formats whose recipes have broken upstream fetches
IMAGE_FSTYPES:remove = "wic wic.bmap wic.qemu-sd"

# Skip htop (upstream SHA garbage-collected, recipe fetch fails)
IMAGE_INSTALL:remove = "htop"

# REQUIRED for dev image — root account locked by default without this
EXTRA_IMAGE_FEATURES = "debug-tweaks"
```

**Build command:**
```bash
cd ~/yocto/haifuraiya
source sources/yocto-scripts/setupsdk
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

**Deliverables produced in `build/tmp/deploy/images/zcu102-zynqmp/`:**
- `BOOT-zcu102-zynqmp.bin` — bundled FSBL+PMU+ATF+U-Boot (for SD use)
- `fsbl-zcu102-zynqmp.elf` — First Stage Boot Loader
- `pmu-firmware-zcu102-zynqmp.elf` — PMU MicroBlaze firmware
- `arm-trusted-firmware.bin` — ATF (BL31) raw binary
- `u-boot.elf` — U-Boot ELF for JTAG load
- `Image` — Linux kernel
- `zynqmp-zcu102-rev1.0.dtb` — device tree blob
- `petalinux-image-minimal-zcu102-zynqmp.cpio.gz.u-boot` — initramfs in U-Boot uImage wrapper
- `petalinux-image-minimal-zcu102-zynqmp.tar.gz` — full rootfs tarball

**Verified behavior at login:**
```
Linux zcu102-zynqmp 5.15.36-xilinx-v2022.2 #1 SMP Mon Oct 3 07:50:07 UTC 2022 aarch64 GNU/Linux

Mem: 3.8G total / 3.6G free / 174.7M buff/cache
CPUs online: 0, 2, 3 (CPU 1 not coming online — see Open Issues)
Ethernet: macb ff0e0000.ethernet eth0: Link is Up - 1Gbps/Full
MAC: 00:0a:35:07:eb:c1 (Xilinx OUI)
```

**What this proves:**
- ✅ Yocto build host configured correctly
- ✅ AMD layer stack consistent at xlnx-rel-v2022.2
- ✅ Source mirror config handles upstream SHA drift
- ✅ wic.qemu-sd / bmap-tools / htop blacklisting works
- ✅ debug-tweaks enables empty-password root
- ✅ JTAG deployment from mymelody → keroppi → ZCU102 fully works
- ✅ Boot chain: PMU FW → FSBL → ATF (EL3) → U-Boot (EL2) → Linux (EL1)
- ✅ PSCI handshake between Linux and ATF works (3 of 4 CPUs)
- ✅ Network up at gigabit, link autodetected

### M2: meta-ori layer + static IP + ADRV9002 device tree ⏳ IN PROGRESS

**Status: meta-ori layer + first recipe (static IP) ✅ DONE (2026-05-18).
Remaining: openssh-server, PXE boot config, meta-adi-xilinx integration.**

**Goal:** turn `meta-ori/` into a real Yocto layer with `conf/layer.conf`,
add static IP via systemd-networkd dropin, then add meta-adi-xilinx for
ADRV9002 driver and proper device tree. Regression-check that sample
stream still works.

#### Step 1: meta-ori as real layer + static IP via systemd-networkd ✅

**Files added to `meta-ori/`:**
- `conf/layer.conf` — bitbake layer registration (collection `ori`, priority 10,
  honister-compat + kirkstone forward-compat, hard-depends on `core`,
  soft-recommends `openembedded-layer` + `petalinux`)
- `COPYING.MIT` — MIT license
- `README.md` — layer scope, activation instructions, planned contents
- `recipes-core/systemd/systemd_%.bbappend` — extends upstream systemd recipe
  to install our network config file
- `recipes-core/systemd/systemd/10-eth0.network` — static IP config:
  ```
  [Match]
  Name=eth0
  
  [Network]
  Address=10.73.1.16/24
  Gateway=10.73.1.1
  ConfigureWithoutCarrier=true
  ```

**Activation:**
```bash
cd ~/yocto/haifuraiya/sources
ln -s ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/meta-ori .

cd ~/yocto/haifuraiya/build
bitbake-layers add-layer ../sources/meta-ori
bitbake-layers show-layers | grep ori
# Expected: ori    /path/to/meta-ori    10
```

**Build + verify file is in rootfs:**
```bash
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal

zcat tmp/deploy/images/zcu102-zynqmp/petalinux-image-minimal-zcu102-zynqmp.cpio.gz | \
    cpio -ivt 2>/dev/null | grep "10-eth0"
# Expected: -rw-r--r-- 1 root root 795 ... ./etc/systemd/network/10-eth0.network
```

**Verified on hardware after deploy + JTAG boot:**
```
root@zcu102-zynqmp:~# ip addr show eth0
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    link/ether 00:0a:35:07:eb:c1
    inet 10.73.1.16/24 brd 10.73.1.255 scope global eth0      ← OUR static IP
       valid_lft forever preferred_lft forever
```

And from keroppi: `ping 10.73.1.16` → ✅ (confirmed by Paul).

#### Step 2: openssh-server in image ⏳ NOT STARTED

Add openssh to `IMAGE_INSTALL` so we can ssh into the board from keroppi
without going through JTAG console for routine work. Probably a single
line in a meta-ori bbappend or in a custom image recipe.

#### Step 3: PXE boot config to eliminate manual U-Boot typing ⏳ NOT STARTED

Drop a `pxelinux.cfg/default` file in `/tftpboot/` with kernel/dtb/initrd
labels. U-Boot autoboot will load Linux automatically without the
manual `setenv` + `tftpboot` + `booti` sequence.

#### Step 4: meta-adi-xilinx + ADRV9002 device tree ⏳ NOT STARTED

The big one — preparation for Phase 2a integration.

```bash
cd ~/yocto/haifuraiya/sources
git clone https://github.com/analogdevicesinc/meta-adi.git
cd meta-adi
git branch -a   # find branch matching 2022.2
git checkout <branch matching 2022.2 — TBD>

cd ~/yocto/haifuraiya/build
bitbake-layers add-layer ../sources/meta-adi/meta-adi-xilinx
```

Set kernel device tree to ADRV9002 variant in local.conf:
```
KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"
```

Build, deploy, verify:
```bash
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
# JTAG boot, then on target:
dmesg | grep -i adrv9002
iio_info | grep -i adrv9002
```

**Pin the meta-adi commit SHA** in the Version Stack table after this step.

### M3: Image built against Phase 2a .xsa (Haifuraiya in PL) ⏳

(Unchanged from previous plan — wait for Phase 2a `.xsa`.)

### M4: Userspace mmap reads VERSION register = 0x00010000 ⏳

(Unchanged from previous plan.)

### M5: Takadono v0 publishes channelizer state via MQTT ⏳

(Unchanged from previous plan.)

---

## 🛰️ JTAG Boot Procedure (M1 recipe — keep this current)

This is the canonical JTAG deployment recipe. Everything between
"power-on" and "root prompt" is here. Future-you returning to this for
M2/M3/M4 — start at "Quick reference" and dive into "Detailed steps" only
if something breaks.

### Quick reference (5 commands once everything is set up)

```bash
# On mymelody:
./scripts/copy_to_keroppi.sh

# On keroppi:
./run_jtag_boot.sh

# On serial console (catch the autoboot countdown):
setenv serverip 10.73.1.94 && setenv ipaddr 10.73.1.16 && \
  tftpboot 0x80000 abraxas3d-yocto/Image && \
  tftpboot 0x4000000 abraxas3d-yocto/system.dtb && \
  tftpboot 0x4100000 abraxas3d-yocto/initramfs.cpio.gz.u-boot && \
  booti 0x80000 0x4100000 0x4000000
```

### Pre-flight checklist (do these once per session)

- [ ] **Boot mode switches (SW6) set to JTAG:** all four positions OFF.
      If switches are in SD mode (1=ON), the BootROM loads BOOT.BIN from
      SD card and interferes with JTAG boot. After changing, **power-cycle
      the ZCU102** — boot mode pins are only sampled at power-on.
- [ ] **TFTP daemon running on keroppi:**
      ```
      sudo systemctl status tftpd-hpa
      ps aux | grep in.tftpd | grep -v grep
      sudo ss -ulnp | grep :69
      ```
      Should see a process and a listening port. If `Tasks: 0` despite
      "Active: running" — check `which in.tftpd` (the binary may be missing
      even though the package shows "installed").
- [ ] **hw_server running on keroppi:**
      ```
      source /tools/Xilinx/Vivado/2022.2/settings64.sh
      pgrep hw_server || hw_server -d
      ```
      Use port 3121 (default). Filtered port `3122 -e "set jtag-port-filter Xilinx"`
      from the lab doc currently catches the LibreSDR, not the ZCU102 — doc is out
      of date on this. Our script filters by target name (`PSU`, `MicroBlaze PMU`,
      `Cortex-A53 #0`) so the LibreSDR being on the chain doesn't interfere.

### Detailed steps

**Step 1: Build artifacts on mymelody** (~10 min for incremental, hours for first build)
```bash
cd ~/yocto/haifuraiya
source sources/yocto-scripts/setupsdk
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

**Step 2: Copy artifacts to keroppi**
```bash
cd ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto
./scripts/copy_to_keroppi.sh
# Also copy the scripts themselves if changed:
scp scripts/zcu102_jtag_boot.tcl scripts/run_jtag_boot.sh abraxas3d@keroppi:/tmp/abraxas3d-yocto-boot/
```

This places:
- JTAG-load artifacts in `keroppi:/tmp/abraxas3d-yocto-boot/`
- TFTP-served artifacts in `keroppi:/tftpboot/abraxas3d-yocto/`
- Short-name TFTP symlinks (`system.dtb`, `initramfs.cpio.gz.u-boot`)

**Step 3: Open serial console with logging** (separate keroppi terminal)
```bash
ssh abraxas3d@keroppi
screen -L -Logfile ~/zcu102_boot_$(date +%Y%m%d_%H%M).log /dev/zcu102_uart1 115200
```

To exit screen: `Ctrl-A` then `k` then `y`.

**Step 4: Power-cycle the ZCU102.** In JTAG boot mode, you'll see *nothing*
on the serial console at power-on — the BootROM is silent without a boot
source. That's the correct expected state.

**Step 5: Run JTAG boot** (in another keroppi terminal)
```bash
cd /tmp/abraxas3d-yocto-boot
./run_jtag_boot.sh
```

This:
1. Sources Vivado 2022.2 settings
2. Starts hw_server if not running
3. Invokes xsdb with `zcu102_jtag_boot.tcl` which:
   - Connects to local hw_server
   - System-resets the ZynqMP
   - Selects MicroBlaze PMU, resets it (wakes from sleep), loads PMU firmware, runs
   - Selects Cortex-A53 #0, processor-resets
   - Loads ATF binary at 0xfffea000 (OCM)
   - Loads FSBL ELF
   - Runs FSBL (FSBL initializes DDR, then enters wait loop)
   - Waits 8 seconds for FSBL DDR init to complete
   - Stops A53 (FSBL has completed)
   - Loads U-Boot ELF
   - **Sets PC to ATF entry (0xfffea000) via `rwr pc`** — critical for EL2 transition
   - Continues execution → ATF runs, transitions EL3→EL2, jumps to U-Boot at EL2

**Step 6: Serial console shows boot chain**

Expected sequence:
```
Xilinx Zynq MP First Stage Boot Loader 
Release 2022.2   ...
...
NOTICE:  ATF running on XCZU9EG/silicon v4/RTL5.1 at 0xfffea000   ← KEY proof ATF ran
NOTICE:  BL31: v2.4(release):xlnx_rebase_v2.4_2021.1_update1
...
U-Boot 2022.01 (Sep 20 2022 - 06:35:33 +0000)
...
DRAM:  4 GiB
PMUFW:  v1.1
EL Level:       EL2                                                  ← MUST BE EL2
Bootmode: JTAG_MODE                                                  ← confirms switches right
...
Hit any key to stop autoboot:  3
```

**If `EL Level: EL3` appears**, ATF did NOT run. Check the xsdb output for
`PC set. pc: 00000000fffea000` — that line must appear. Without ATF runtime,
Linux PSCI SMCs will fail and the kernel panics at `psci_0_2_init`.

**Step 7: Catch the autoboot countdown.** Press any key as soon as you see
`Hit any key to stop autoboot`. If you miss it, U-Boot will try DHCP + PXE
which will eventually fail and leave you at `ZynqMP>` anyway — but takes
longer.

**Step 8: Manually configure and load via TFTP** at the `ZynqMP>` prompt:
```
setenv autoload no
setenv serverip 10.73.1.94
setenv ipaddr   10.73.1.16
setenv netmask  255.255.255.0
setenv gatewayip 10.73.1.1

ping 10.73.1.94
```

Expected: `host 10.73.1.94 is alive`. If ping fails, network plumbing is wrong.

```
tftpboot 0x80000     abraxas3d-yocto/Image
tftpboot 0x4000000   abraxas3d-yocto/system.dtb
tftpboot 0x4100000   abraxas3d-yocto/initramfs.cpio.gz.u-boot

booti 0x80000 0x4100000 0x4000000
```

**Step 9: Linux boot messages scroll, login prompt appears**

```
Starting kernel ...

[    0.000000] Booting Linux on physical CPU 0x0000000000000000
[    0.000000] Linux version 5.15.36-xilinx-v2022.2 ...
...

PetaLinux 2022.2_dev zcu102-zynqmp ttyPS0

zcu102-zynqmp login: root
[root prompt appears]
```

Login: `root` with no password (`debug-tweaks` enables this).

### Future improvement: PXE boot to avoid manual typing

U-Boot's autoboot tries PXE before falling through. If we drop a
`pxelinux.cfg/default` file in `/tftpboot/`, U-Boot autoboot will find it
and execute the boot commands automatically. Format:
```
default abraxas3d-yocto
prompt 1
timeout 30

label abraxas3d-yocto
  kernel abraxas3d-yocto/Image
  fdt abraxas3d-yocto/system.dtb
  initrd abraxas3d-yocto/initramfs.cpio.gz.u-boot
  append console=ttyPS0,115200 earlycon
```

This eliminates Step 7-8's manual typing. Worth doing as M2-era polish.

---

## 🐲 Phase 2b Bug Hunt Trophy Case
*Twelve bosses slain getting from "Yocto package installed" to "Linux
root prompt". Documented for future-you and any ORI collaborator
following this same path.*

### 1. Recipe SHA drift on git-fetch recipes
**Symptom:** First bitbake fails with
```
ERROR: bmap-tools-native do_fetch: Fetcher failure: Unable to find revision
       c0673962a8...  in branch master even from upstream
ERROR: htop-3.0.5-r0 do_fetch: Fetcher failure: Unable to find revision
       ce6d60e7def... in branch master even from upstream
```
Multiple recipes pin to specific git commits that upstream has since
garbage-collected.

**Root cause:** Yocto recipes in xlnx-rel-v2022.2 (from 2022) pin specific
git SHAs. Upstream repos garbage-collected those commits. The default
PREMIRRORS don't have these specific objects (because they were never
tagged release commits, just convenient HEAD-of-the-day pins).

**Fix:** Add Yocto Project source mirror to `local.conf`:
```
SOURCE_MIRROR_URL ?= "http://sources.yoctoproject.org/releases/"
INHERIT += "own-mirrors"
BB_GENERATE_MIRROR_TARBALLS = "1"
```

**For SHAs that still aren't on any mirror,** blacklist the recipes:
```
IMAGE_INSTALL:remove = "htop"
IMAGE_FSTYPES:remove = "wic wic.bmap wic.qemu-sd"
```

`wic.qemu-sd` (the QEMU SD card image format) was a hidden third variant beyond `wic` and `wic.bmap` — easy to miss when removing wic image formats. Trace via `bitbake -e ... | grep ^IMAGE_FSTYPES=` to see effective values.

**Pattern:** First Yocto build on any new layer set will probably hit
this. Add the mirror config as a default in `local.conf` from the start.

### 2. PMU TAP vs MicroBlaze PMU naming collision in xsdb filters
**Symptom:** `targets -set -filter {name =~ "PMU"}` followed by `dow $pmu_fw`
gives "Invalid context" error. Or "MDM master access port not found" on memory ops.

**Root cause:** xsdb 2022.2 shows the JTAG target tree as:
```
1  PS TAP
   2  PMU                                ← TAP node (parent), NOT a CPU
      3  MicroBlaze PMU (Sleeping...)   ← THE actual PMU MicroBlaze
```

The glob filter `{name =~ "PMU"}` matched target 2 (the TAP) first. TAPs
have no MDM (MicroBlaze Debug Module) for memory operations. All ops fail.

**Fix:** Use exact-match filter:
```tcl
targets -set -filter {name == "MicroBlaze PMU"}
```

**Pattern:** xsdb filter `=~` is glob/substring. Use `==` for exact match
when multiple targets contain the filter string.

### 3. MicroBlaze PMU is "Sleeping. No clock" by default
**Symptom:** After selecting MicroBlaze PMU target via exact match,
`mrd 0xfffd0000` fails with the same "MDM master access port not found".
Target list shows `MicroBlaze PMU (Sleeping. No clock)`.

**Root cause:** After ZynqMP system reset, the PMU MicroBlaze is in a
power/clock-gated sleep state. Memory operations to its address space
fail because the clock isn't running.

**Fix:** Reset the MicroBlaze PMU specifically after selecting it. This
wakes it.
```tcl
targets -set -filter {name == "MicroBlaze PMU"}
rst -processor
after 500
# Now memory ops work; can dow firmware
dow $pmu_fw
```

Verify wake by checking target status changes from
`(Sleeping. No clock)` to `(External debug request)` or `(Halted)`.

**Pattern:** ZynqMP PMU bring-up requires explicit `rst -processor` to
wake from sleep state.

### 4. The MULTIBOOT register write needs to come AFTER reset, not before
**Symptom:** Initial script had `mwr 0xffca0038 0x1ff` before `rst -system`.
After reset, the register went back to default, locking out PMU access again.

**Root cause:** `rst -system` resets registers including `0xffca0038`
(MULTIBOOT_REG / JTAG access enable). Writing before reset accomplishes
nothing.

**Fix:** Move the `mwr` to after the reset's settling delay:
```tcl
rst -system
after 2000
catch {mwr 0xffca0038 0x1ff}    ;# now this sticks
```

Wrap in `catch` because the write may not be needed in all configurations.

**Pattern:** Any register configuration written via JTAG must happen
*after* any system reset, not before.

### 5. ATF must be loaded BEFORE FSBL runs
**Symptom:** Loading ATF binary at 0xfffea000 *after* FSBL runs gives
"MMU fault at VA 0xFFFEA000. Translation fault, level 1".

**Root cause:** FSBL chains to whatever's at 0xfffea000 when it finishes
DDR init. If something was already at 0xfffea000 (residual from prior boot),
FSBL chains to it. If nothing was there, FSBL crashes or runs garbage.
Either way, by the time we try to `dow` ATF, the A53 has moved past
EL3-with-MMU-off into either EL2/EL1-with-MMU-on or kernel space.

**Fix:** Load ATF binary at 0xfffea000 *before* starting FSBL:
```tcl
# Load ATF FIRST
dow -data $atf_bin 0xfffea000
# Then load and run FSBL
dow $fsbl
con
```

**Pattern:** The boot chain expects each stage to be in memory before the
previous stage chains to it. Load all stages first, then start execution.

### 6. `dow u-boot.elf` sets PC to U-Boot, bypassing ATF
**Symptom:** Sequence "load ATF binary → run FSBL → wait → stop → load U-Boot →
con" results in U-Boot booting at EL3 instead of EL2. Linux kernel panics
at `psci_0_2_init` because PSCI SMCs find no EL3 runtime.

**Root cause:** `dow u-boot.elf` sets the PC to U-Boot's entry point.
When we `con`, execution starts at U-Boot directly, never running ATF.
ATF is in OCM but is never executed.

**Fix:** After `dow u-boot.elf`, explicitly override PC to ATF entry:
```tcl
dow $uboot_elf
rwr pc 0xfffea000        ;# ATF entry
con
```

ATF then runs, transitions EL3→EL2, jumps to U-Boot at its BL33 address
(compiled to 0x8000000, matching where we loaded U-Boot).

**Pattern:** ELF downloads set the PC. Explicit `rwr pc` overrides that to
the desired actual entry point.

### 7. `mwr -force pc` writes memory, not the PC register
**Symptom:** Wrote `mwr -force pc 0xfffea000` thinking it set the program
counter. Actually it tried to write 0xfffea000 to address "pc" treated as
memory. Did not change the PC. U-Boot continued to run at its own entry.

**Root cause:** xsdb command naming.
- `mwr` / `mrd` = **m**emory write/read (with address)
- `rwr` / `rrd` = **r**egister write/read (with register name)

**Fix:** Use `rwr` for register operations:
```tcl
rwr pc 0xfffea000      ;# correct: writes PC register
```

**Pattern:** xsdb command prefix matters. `m*` for memory, `r*` for
registers. Easy to typo when both touch the same conceptual address.

### 8. Boot mode pins must be set to JTAG, not SD
**Symptom:** With SW6 set for SD boot, the BootROM autoloads BOOT.BIN
from SD card before we even start JTAG operations. JTAG-loaded code
fights the running SD-booted system. Symptoms include:
- U-Boot 2022.01 (SD's U-Boot) showing instead of 2021.01 (ours)
- "PMUFW no permission to change config object" errors
- "Net: Emergency page table not setup. ### ERROR ### Please RESET ###"

**Root cause:** ZCU102's SW6 is read by the BootROM at power-on:
- SW6 = ON OFF OFF OFF → SD boot mode
- SW6 = OFF OFF OFF OFF → JTAG boot mode (BootROM idles, waits for JTAG)

The BootROM samples this only at power-on; flipping switches mid-session
has no effect until a power cycle.

**Fix:** Set SW6 all positions OFF, power-cycle the board. U-Boot will then
report `Bootmode: JTAG_MODE` instead of `LVL_SHFT_SD_MODE1`.

**Pattern:** When in doubt about boot behavior, **check the physical
boot mode switches first**. Paul caught this; lab doc should explicitly
list switch positions for ZCU102 JTAG dev.

### 9. tftpd-hpa in "rc" (removed-but-config-retained) state
**Symptom:** `systemctl status tftpd-hpa` reports "active (exited)" since
hours ago, but `ps aux | grep tftpd` shows no process and
`ss -ulnp | grep :69` shows nothing listening. TFTP from U-Boot fails with
"TFTP server died; starting again."

**Root cause:** `dpkg -l | grep tftpd-hpa` showed status `rc` —
**r**emoved-but-**c**onfig-retained. Someone had run `apt remove tftpd-hpa`
(without `--purge`), deleting the binaries but keeping config + init script
+ systemd unit. The init script returns 0 on "start" because it doesn't
actually verify daemon launch. systemd reports "active (exited)" because
the init script exited cleanly even though no daemon spawned.

**Fix:**
```bash
sudo apt install tftpd-hpa
sudo systemctl restart tftpd-hpa
# Verify:
ps aux | grep in.tftpd | grep -v grep
sudo ss -ulnp | grep :69
```

**Pattern:** "Service shows active in systemctl" is not the same as
"daemon is actually running". Always verify with `ps` AND `ss`/`netstat`.
Particularly suspicious when `Tasks: 0` appears in `systemctl status`.

### 10. Yocto default image has root account locked
**Symptom:** Login as `root` with empty password (or any password) fails:
"Login incorrect". `/etc/shadow` shows:
```
root:*:15069:0:99999:7:::
     ↑
     asterisk = no valid password hash, account locked
```

**Root cause:** Yocto's default `petalinux-image-minimal` recipe ships
with root account locked for security. This is the safe default for
production images but inconvenient for development.

**Fix:** Add to local.conf and rebuild:
```
EXTRA_IMAGE_FEATURES = "debug-tweaks"
```

`debug-tweaks` enables:
- Empty password for root
- SSH with empty-password root allowed
- Auto-login at serial console (`serial-autologin-root`)
- Some debug-friendly tool defaults

**Pattern:** Yocto images need `debug-tweaks` for dev convenience. This
should be in our `local.conf` template from day one. Petalinux's equivalent
defaults exist because Petalinux is dev-oriented by default.

### 11. Two hw_server instances confused initial xsdb connect
**Symptom:** Script's `connect` (without explicit URL) silently connected
to wrong hw_server. `targets` listed empty. Subsequent ops gave
"Invalid context".

**Root cause:** Two hw_servers were running on keroppi during initial
debugging:
- `hw_server -d` on default port 3121 (had ZCU102 visible)
- `hw_server -s tcp::3122 -e "set jtag-port-filter Xilinx" -p 4000 -d`
  on port 3122 (caught the LibreSDR instead of ZCU102)

`connect` without explicit URL went to one or the other unpredictably.

**Fix:** Always pass explicit URL:
```tcl
connect -url tcp:127.0.0.1:3121
```

And keep only one hw_server running.

**Pattern:** When debugging xsdb-based flows, always be explicit about
which hw_server you're connecting to. Multiple instances are valid in
production lab setups (different boards on different ports), but each
client must specify.

### 12. The lab doc's port filter mapping is reversed from current reality
**Symptom:** Lab doc says `hw_server -s tcp::3122 -e "set jtag-port-filter
Xilinx"` selects the ZCU102. But this filter actually catches the
LibreSDR/Pluto on keroppi.

**Root cause:** Lab cable identities changed since doc was written.
Either the LibreSDR's JTAG cable now matches "Xilinx" in name, or the
ZCU102's cable uses a different identifier. Result: the doc's recommended
filter selects the wrong board.

**Fix:** Use default `hw_server -d` on port 3121 (no filter), and rely on
target-name filters in xsdb scripts to disambiguate (e.g., `{name =~ "PSU"}`
for the ZynqMP, which the LibreSDR's xc7z020 doesn't have).

**Pattern:** Doc instructions about JTAG cable filters can drift from
hardware reality. Verify with `xsdb` + `targets` what's actually on the
chain, and filter by board-specific target names rather than by cable
identity.

### 13. Yocto release name assumed from product year instead of verified
**Symptom:** Wrote `LAYERSERIES_COMPAT_ori = "kirkstone"` based on
assumption that Xilinx 2022.2 (released October 2022) would pair with
Yocto Kirkstone (LTS, April 2022). `bitbake-layers add-layer` failed:
```
Layer ori is not compatible with the core layer which only supports
these series: honister (layer is compatible with kirkstone)
```

**Root cause:** Xilinx 2022.2 was actually based on **Honister (3.4)**, not
Kirkstone. The dev cycle for xlnx-rel-v2022.2 started before Kirkstone was
finalized and stayed on Honister. (xlnx-rel-v2023.x moved to Langdale.)

**Fix:** Use `LAYERSERIES_COMPAT_ori = "honister kirkstone"` — declares
compatibility with the actual base AND keeps forward-compat for any
future upgrade.

**Pattern:** Don't assume Yocto release name from product year. **Ask the
system:**
```bash
grep LAYERSERIES_COMPAT_core sources/core/meta/conf/layer.conf
```
That's authoritative; everything else is inference.

### 14. Layer dependencies use COLLECTION names, not DIRECTORY names
**Symptom:** Declared `LAYERDEPENDS_ori = "core openembedded-layer meta-petalinux"`.
`bitbake-layers add-layer` failed:
```
Layer 'ori' depends on layer 'meta-petalinux', but this layer is not
enabled in your configuration
```
But `meta-petalinux` is clearly enabled in bblayers.conf.

**Root cause:** Yocto layers have two names. The directory is named
`meta-petalinux`, but its `BBFILE_COLLECTIONS` declares the collection
name as just `petalinux`. `LAYERDEPENDS` matches against collection names,
not directory names. Bitbake looked for a collection literally named
`meta-petalinux` and found nothing.

**Fix:** Use the collection name:
```
LAYERDEPENDS_ori = "core"
LAYERRECOMMENDS_ori = "openembedded-layer petalinux"
```
(Also moved most deps to RECOMMENDS to make the layer more permissive.)

**Pattern:** Always verify collection names with
`grep BBFILE_COLLECTIONS sources/<layer>/conf/layer.conf` before
declaring dependencies. See the Layer Collection Name Reference table
above for our common layers.

### 15. `.bbappend` filename's `%` got mangled to `_` in file transfer
**Symptom:** `bitbake-layers add-layer` succeeded (layer activated), but
`bitbake-layers show-appends` listed our bbappend on its own line instead
of nested under `systemd_249.7.bb`:
```
  /home/.../meta-ori/recipes-core/systemd/systemd__.bbappend     ← lonely
systemd_249.7.bb:
  /home/.../meta-xilinx/meta-microblaze/.../systemd_%.bbappend   ← properly nested
```
The bbappend wasn't being applied to any recipe — bitbake didn't know what to
attach it to.

**Root cause:** In Yocto, `.bbappend` filenames use `%` as a version
wildcard. `systemd_%.bbappend` means "apply to any version of the systemd
recipe." Our filename had `_` where the `%` should have been:
`systemd__.bbappend` (two underscores). The `%` got mangled somewhere
in the file transfer (URL encoding round-trip, copy-paste through web UI,
some path normalization step — exact cause unclear, but the symptom is
clear).

**Fix:** Rename the file:
```bash
mv systemd__.bbappend systemd_%.bbappend
```

**Pattern:** When `.bbappend` files mysteriously don't apply, check the
filename for `%` before checking the file content. The `%` character in
filenames is valid on Unix but some transfer mechanisms mangle it.

### 16. `setupsdk` from inside `build/` creates nested `build/build/`
**Symptom:** Ran `source ../setupsdk` from inside the existing `build/`
directory. Got messages like "You had no conf/local.conf file" and
ended up in `~/yocto/haifuraiya/build/build/` (note the doubled `build/`)
with no config. Original config seemed gone.

**Root cause:** AMD's setupsdk uses the current working directory as
TOPDIR. If you're inside `build/`, it creates a new `build/` inside it
and cd's you there. Your ORIGINAL `build/` is still intact — you're just
in the wrong directory now.

**Fix:** 
```bash
cd ~/yocto/haifuraiya         # go to project root
rm -rf build/build             # remove the empty nested directory
source setupsdk                # source from project root (not from build/)
```

**Pattern:** ALWAYS source setupsdk from the project root, never from
inside an existing `build/`. Already noted in the "Common setupsdk
pitfall" section above; banked here for trophy completeness.

### 17. tftpd-hpa reinstalled but service didn't auto-restart
**Symptom:** During M1 TFTP debugging, ran `sudo apt install tftpd-hpa`
to restore a missing binary. Binary appeared in `/usr/sbin/in.tftpd`,
but `ps aux | grep tftpd` still showed no process. `systemctl status`
said "active (exited) since 4 minutes ago" — the timestamp was BEFORE
the apt install.

**Root cause:** `apt install` reinstalled the package files but didn't
restart the service. The systemd state showed the previous (failed)
start attempt, not a new state reflecting the now-present binary.

**Fix:**
```bash
sudo systemctl restart tftpd-hpa
```
After restart, ps showed the daemon, ss showed port 69 listening.

**Pattern:** After any package reinstall, restart relevant services
explicitly. Don't trust systemctl status timestamps; check process
state directly with `ps` and `ss`.

### 18. Ubuntu 22.04 glibc 2.35 vs Honister uninative glibc 2.34
**Symptom:** During M2 image rebuild, bitbake emitted:
```
WARNING: Your host glibc version (2.35) is newer than that in uninative
(2.34). Disabling uninative so that sstate is not corrupted.
```
Followed by sea-of-red ERROR messages about glib-2.0 setscene failures.

**Root cause:** "uninative" is Yocto's mechanism for making sstate cache
portable across hosts (it ships a fixed glibc to use instead of the
host's). Ubuntu 22.04's glibc is newer than what Yocto Honister's
uninative expects. Yocto disabled uninative for safety, which invalidated
sstate cache entries that assumed uninative was active.

**Recovery:** Bitbake handles this automatically — when a setscene task
fails, bitbake says "real task will be run instead" and rebuilds from
scratch. The build succeeded; the errors looked alarming but were
benign.

**Pattern:** Yocto's failsafe is "if cache is suspect, rebuild." When you
see lots of `do_*_setscene` failures with "real task will be run instead"
warnings, the build will still complete correctly. The first build on a
fresh host always shows some of this; subsequent builds use the local
sstate-cache which doesn't have the uninative dependency.



- **xsdb command naming matters.** `mwr`/`mrd` = memory ops (with
  address). `rwr`/`rrd` = register ops (with register name). Easy typo,
  hard to debug.
- **xsdb filters: `=~` is glob/substring, `==` is exact.** When multiple
  targets share a substring (PMU vs MicroBlaze PMU), use `==`.
- **JTAG boot stages must be loaded in the right order.** ATF in OCM
  before FSBL runs; U-Boot in DDR after FSBL inits DDR; PC explicitly set
  to ATF entry before continuing (because `dow elf` sets PC to that elf's
  entry, bypassing ATF).
- **Always verify EL level in U-Boot banner.** `EL Level: EL2` means ATF
  ran correctly. `EL Level: EL3` means ATF was skipped — Linux PSCI will
  fail.
- **"Active (exited)" with `Tasks: 0` in systemctl is a lie.** Always
  cross-check with `ps` and `ss`/`netstat`.
- **`dpkg` `rc` state hides missing binaries.** Reinstall before
  diagnosing weird "I configured this, why doesn't it work" failures.
- **Yocto recipe SHA drift is the most common first-build failure.** Add
  the Yocto source mirror to local.conf from day one.
- **`debug-tweaks` is required for dev images.** Root login is locked
  by default without it. Should be in the standard local.conf template.
- **Lab doc instructions may be out of date.** Verify physical config
  (boot mode pins, JTAG cables, daemon state) before trusting the doc.
- **Capture serial console to file from the start.** `screen -L -Logfile
  path` is your friend. "I'll just remember what I saw" doesn't work
  when the boot scrolls past in 2 seconds.
- **Boot mode switches are sampled only at power-on.** Flipping them
  mid-session does nothing until you power-cycle.
- **D&D commit messages persist memory.** Cast PROTECTION FROM PMU SLEEP.
  Cast IDENTIFY ATF ENTRY. Cast COUNTERSPELL TRANSLATION FAULT. Cast
  AWAKEN THE MICROBLAZE.

---

## ❓ Open Questions / Issues for Investigation

These came up during M1 closeout and are not blocking but worth tracking:

1. **CPU 1 doesn't come online.** `cat /proc/cpuinfo` shows only CPUs 0, 2,
   3. ZCU102 has 4× Cortex-A53. CPU 1 fails PSCI bring-up. Not blocking
   (3 cores are plenty), but worth investigating during Phase 3 hardware
   integration. May be related to ATF handoff context being incomplete via
   JTAG (vs full BOOT.BIN flow), or device tree CPU 1 node config.

2. ~~**No persistent IPv4 on eth0.**~~ ✅ Resolved by M2 step 1 (static IP
   via systemd-networkd dropin in meta-ori). eth0 now comes up with
   10.73.1.16/24 on boot.

3. ~~**ICMP / ping from outside.**~~ ✅ Resolved — Paul confirmed ping
   from keroppi succeeds once static IP is set. Default Yocto image has
   no firewall.

4. **U-Boot env doesn't persist across boots.** Every boot starts with
   default U-Boot env. To persist, would need to enable env storage
   (QSPI, EMMC, SD FAT). For JTAG-only workflow, PXE config file in
   /tftpboot is the lighter-weight equivalent — that's M2 step 3.

5. **PXE boot file would eliminate manual TFTP typing.** Drop a
   `pxelinux.cfg/default` file in `/tftpboot/` with kernel/dtb/initrd
   labels. U-Boot's autoboot would then load Linux automatically. M2
   step 3.

6. **openssh-server not in default image.** We have ssh client but no
   server, so we can't ssh INTO the board. Add to meta-ori — M2 step 2.

---

## 🐉 Risks / Watch Points (updated post-M1)

| Risk | Likelihood | Mitigation |
|---|:-:|---|
| Yocto Honister upstream EOL (non-LTS, already EOL'd) | Medium | Pin commits explicitly; rely on Xilinx's xlnx-rel branches; document workarounds inline |
| Recipe SHA drift on first build | **Hit** | Mirror config + blacklist via :remove (see M1's local.conf) |
| meta-adi branch naming has drifted | Low | Verify branch after first clone; document |
| First build fails with cryptic error | **Hit** | All known causes now documented in trophy case |
| Disk fills up mid-build | Low | 100GB+ allocated, ~50GB used in practice |
| Power loss during long build | Low | Bitbake resumes; sstate-cache survives |
| `.xsa` from Vivado 2022.2 has format quirks | Medium | gen-machine-conf is the tool; well-documented |
| Boot mode pins set wrong | **Hit** | Pre-flight checklist now includes SW6 verification |
| TFTP daemon in `rc` state | **Hit** | Pre-flight checklist verifies `ps` + `ss`, not just `systemctl` |
| Root account locked without debug-tweaks | **Hit** | `EXTRA_IMAGE_FEATURES = "debug-tweaks"` in standard local.conf |
| CPU 1 not coming online via PSCI | Low | Not blocking; 3 cores plenty for our use case |
| Lab doc says ZCU106 on keroppi | **Hit** | Updated: actually ZCU102 + ADRV9002; 106 in reserve |
| ATF not loaded before FSBL runs | **Hit** | Load order fixed in xsdb script |
| `dow u-boot.elf` sets PC to U-Boot (skipping ATF) | **Hit** | Explicit `rwr pc 0xfffea000` after dow |
| Multiple hw_servers cause connect confusion | **Hit** | Use explicit `connect -url`; keep only one server running |
| Yocto release name confusion (Honister vs Kirkstone) | **Hit** | `grep LAYERSERIES_COMPAT_core sources/core/meta/conf/layer.conf` for ground truth, don't infer from product year |
| Layer dependencies broken by directory-vs-collection name mixup | **Hit** | `grep BBFILE_COLLECTIONS` to find actual collection names; see Layer Collection Name Reference table |
| `.bbappend` filename `%` mangled in file transfer | **Hit** | Verify filename ends in `_%.bbappend` (not `__.bbappend`) after copying |
| setupsdk creates nested build/build/ when sourced from inside build/ | **Hit** | Always source setupsdk from project root |
| tftpd-hpa reinstalled but service not auto-restarted | **Hit** | `systemctl restart` after any package reinstall; verify with `ps` and `ss` |
| Host glibc 2.35 newer than uninative 2.34 | **Hit** | Yocto handles automatically — disables uninative, falls back to fresh builds. Harmless. |

---

## 📚 References

### AMD/Xilinx Yocto documentation
- AMD Yocto wiki: https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/2824503297/Building+Linux+Images+Using+Yocto
- Older Xilinx Yocto doc: https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18841862/
- meta-xilinx: https://github.com/Xilinx/meta-xilinx
- yocto-manifests: https://github.com/Xilinx/yocto-manifests

### ADI documentation
- meta-adi: https://github.com/analogdevicesinc/meta-adi
- ADRV9002 ZCU102: https://wiki.analog.com/resources/eval/user-guides/adrv9002

### Yocto Project core
- Yocto Reference Manual (Honister): https://docs.yoctoproject.org/honister/
- Yocto release schedule: https://wiki.yoctoproject.org/wiki/Releases

### Community
- meta-xilinx ML: https://lists.yoctoproject.org/g/meta-xilinx
- ADI EngineerZone: https://ez.analog.com/linux-software-drivers/

### ORI internal
- ORI Remote Labs doc: phase4ground/documents/Remote_Labs/working-with-FPGAs.md (current TBD section: "Working on the zcu102 (zcu106 TBD)" — this plan-of-attack will be the contribution to close that gap)

---

## 🗝️ M1 Verification Data (banked 2026-05-18)

For posterity / future reference:

```
$ uname -a
Linux zcu102-zynqmp 5.15.36-xilinx-v2022.2 #1 SMP Mon Oct 3 07:50:07 UTC 2022 aarch64 GNU/Linux

$ free -h
              total        used        free      shared  buff/cache   available
Mem:           3.8G       76.9M        3.6G      159.8M      174.7M        3.5G
Swap:             0           0           0

$ cat /proc/cpuinfo | grep -E "(processor|model name|implementer)" | head -20
processor       : 0
CPU implementer : 0x41
processor       : 2
CPU implementer : 0x41
processor       : 3
CPU implementer : 0x41

$ ip addr show eth0
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0a:35:07:eb:c1 brd ff:ff:ff:ff:ff:ff
    inet6 fe80::20a:35ff:fe07:ebc1/64 scope link
       valid_lft forever preferred_lft forever
```

---

*Last updated: 2026-05-18, M2 step 1 closeout. Phase 2b chapter 1 (vanilla
Yocto JTAG boot, M1) banked with twelve bosses slain. Phase 2b chapter 2
(meta-ori layer + first recipe, M2 step 1) banked with six more bosses
slain. eth0 = 10.73.1.16/24 confirmed on hardware; ping from keroppi
succeeds (verified by Paul). meta-ori is a real Yocto layer with one
working recipe; from here every customization follows the same pattern.
Yocto base correctly identified as Honister (3.4), not Kirkstone as
previously assumed. Next focus: choose M2 step 2 (openssh-server, PXE
boot, OR jump to meta-adi-xilinx).*
