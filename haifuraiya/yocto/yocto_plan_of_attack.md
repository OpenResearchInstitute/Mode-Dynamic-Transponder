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
| ✅ | **openssh-server in image** | **`ssh root@10.73.1.16` from keroppi succeeds (empty password via debug-tweaks). Dev workflow no longer requires JTAG console for interactive work.** |
| ✅ | **Auto-boot via boot.scr at 0x20000000** | **Zero keystrokes during boot. U-Boot's autoboot finds boot.scr (loaded by xsdb via `dow -data`), runs setenv + tftpboot + booti automatically.** |
| ✅ | **M2 step 4 (phase 1): meta-adi layers registered** | **`bitbake-layers show-layers` lists `adi-core` (priority 6) and `adi-xilinx` (priority 8). Honister LAYERSERIES_COMPAT confirmed on `2022_R2` branch. Layer.conf hard dep `LAYERDEPENDS_adi-xilinx += "adi-core"` discovered — both layers required, dep order matters.** |
| ✅ | **M2 step 4 (phase 1): ADI kernel compiles cleanly** | **`linux-xlnx-5.15.36-adi_master+gitAUTOINC+machine-r0: task do_compile: Succeeded`. meta-adi's bbappend swaps `KERNELURI` to `analogdevicesinc/linux@cd7e20c4...` 2022_R2 branch while keeping `linux-xlnx` recipe name (no PREFERRED_PROVIDER swap needed). 24 minutes wall clock for first kernel build.** |
| ✅ | **Conf templates updated** | **`haifuraiya/yocto/conf/*.template` capture tonight's project-wide decisions: meta-adi layers, KERNEL_DTB, SRCREV pin, KUIPER_COMPAT suppression. Live build configs verified to match templates functionally (one cosmetic whitespace diff on `INHERIT += "plnx-mirrors"`).** |
| ✅ | **M2.5: ADI HDL submodule + reference design built** | **`analogdevicesinc/hdl` added as submodule at `haifuraiya/third_party/hdl`, pinned to `hdl_2022_r2`. `make` in `projects/adrv9001/zcu102/` produces `system_top.xsa` (2.3 MB) and `system_top.bit` (9.9 MB). 26 min wall clock. Eight library IPs + project. Clean Vivado 2022.2 build, no timing failures.** |
| 🎯 | **Next concrete action** | **M2 step 4 (phase 2): integrate ADI XSA into Yocto build via XSA-substitution mechanism (TBD); write system-conf.dtsi stub via meta-ori bbappend (closes Petalinux-vs-Yocto seam); rebuild Yocto; update JTAG boot to load bitstream; validate `dmesg \| grep -i adrv9002` and `iio_info`.** |
| ⏳ | M3: image built against Phase 2a .xsa (Haifuraiya in PL) | Hardware design integrated; channelizer in bitstream |
| ⏳ | M4: userspace mmap reads VERSION register = 0x00010000 | Round-trip Linux-to-IP communication confirmed |
| ⏳ | M5: Takadono v0 MQTT publish working | First observability output |
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
| `meta-adi-xilinx` | **3a5de5c** | "ci: add build script for the release branch" (branch `2022_R2`) |
| `analogdevicesinc/hdl` (submodule) | **__ae6e248f219a5bb2e63733c762e9561c072d037e__** | (branch `hdl_2022_r2`, pinned via `.gitmodules` at `haifuraiya/third_party/hdl`) |

### Kernel SRCREV pin

meta-adi-xilinx's `linux-xlnx_%.bbappend` defaults `SRCREV` to `AUTOREV` in
online builds — every build could pull a different HEAD of ADI's `2022_R2`
branch. We pin explicitly in `local.conf`:

```
SRCREV:pn-linux-xlnx = "cd7e20c430dc19df7c32610e9d5b494d8f313e07"
```

This is the same commit ADI's own offline CI uses (the bbappend's
`BB_NO_NETWORK` fallback). Source: `analogdevicesinc/linux` at the
`adi_master` branch, kernel version 5.15.36 + ADI patches.

To refresh this pin: check `git log` on `analogdevicesinc/linux@adi_master`,
pick a commit, update `local.conf.template` and our live `local.conf`.
```

Update the "Tool versions" table — find the `Vivado` row and add a build
date column or append to the rationale:

```markdown
| Vivado | **2022.2** (build 3671981, 2022-10-14) | License-constrained; install at `/opt/Xilinx/Vivado/2022.2/` (also reachable via `/tools/Xilinx/Vivado/2022.2/` symlink on CHONC-shared lab VMs). Source `settings64.sh` before any Vivado-using command. |
```

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

### M2: meta-ori layer + static IP + openssh + auto-boot + ADRV9002 device tree ⏳ IN PROGRESS

**Status as of 2026-05-18: steps 1-3 complete; step 4 split into two
phases. Phase 1 (layer registration + kernel compile + conf template
updates) complete. Phase 2 (XSA integration + image rebuild + JTAG deploy
+ ADRV9002 driver probe validation) is the current 🎯 and is gated on
M2.5 being banked first (see below).**

The original M2 step 4 ("add meta-adi-xilinx, set KERNEL_DTB, rebuild")
turned out to be more involved than anticipated because (a) meta-adi-xilinx
was written assuming a Petalinux-tool flow that produces `system-conf.dtsi`
and pure Yocto doesn't, and (b) booting `zynqmp-zcu102-rev10-adrv9002.dts`
meaningfully requires matching PL hardware — which means building ADI's
HDL reference design (`adrv9001_zcu102`). Step 4 is therefore phased and a
new M2.5 milestone was inserted between phases.

**Goal:** turn `meta-ori/` into a real Yocto layer with `conf/layer.conf`,
add static IP via systemd-networkd dropin, add openssh for non-JTAG
interactive access, eliminate manual typing during boot, then add
meta-adi-xilinx for ADRV9002 driver and proper device tree.

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

**Validated on hardware:**
```
root@zcu102-zynqmp:~# ip addr show eth0
inet 10.73.1.16/24 brd 10.73.1.255 scope global eth0    ← OUR static IP
```
And `ping 10.73.1.16` from keroppi succeeds (verified by Paul).

#### Step 2: openssh-server in image ✅

**Files added to `meta-ori/`:**
- `recipes-core/images/petalinux-image-minimal.bbappend`:
  ```
  IMAGE_INSTALL:append = " openssh"
  ```

**Validated on hardware:**
```
abraxas3d@keroppi:~$ ssh root@10.73.1.16
The authenticity of host '10.73.1.16 (10.73.1.16)' can't be established.
RSA key fingerprint is SHA256:47319/zshswCgelsjEl4SKbmsSxGk15u23BxqieuZCo.
Are you sure you want to continue connecting (yes/no)? yes
root@zcu102-zynqmp:~#
```

Empty password root login (via debug-tweaks). SSH from keroppi works,
no JTAG console needed for routine interactive work.

**Known sub-issue resolved:** an intermediate build showed `dropbear`
as the SSH service (inactive). DISTRO_FEATURES in meta-petalinux
includes `ssh-server-dropbear`. Adding openssh via IMAGE_INSTALL worked
eventually but the cleaner long-term fix is a meta-ori distro
override removing dropbear and adding ssh-server-openssh. Tracked for
later polish.

#### Step 3: Auto-boot via boot.scr at 0x20000000 ✅

**Files added to `scripts/`:**
- `scripts/boot-script.txt`: U-Boot boot script source with static IPs
  + tftpboot + booti
- `scripts/make_boot_scr.sh`: wraps source with mkimage to produce
  `boot.scr`
- `scripts/zcu102_jtag_boot.tcl` updated: also loads `boot.scr` to
  0x20000000 via `dow -data` after loading U-Boot ELF
- `scripts/copy_to_keroppi.sh` updated: also copies boot.scr + JTAG
  scripts to keroppi (single-command full deployment)

**Boot script content:**
```
setenv autoload no
setenv serverip 10.73.1.94
setenv ipaddr   10.73.1.16
setenv netmask  255.255.255.0
setenv gatewayip 10.73.1.1
tftpboot 0x80000   abraxas3d-yocto/Image
tftpboot 0x4000000 abraxas3d-yocto/system.dtb
tftpboot 0x4100000 abraxas3d-yocto/initramfs.cpio.gz.u-boot
booti 0x80000 0x4100000 0x4000000
```

**Validated on hardware:** Power-cycle → `./run_jtag_boot.sh` → ~30
seconds later → SSH root prompt. **Zero human keystrokes between
power-on and shell.**

The PXE approach was tried first but failed: PXE requires DHCP-populated
serverip, and our lab has no DHCP server. The 0x20000000 script approach
works without DHCP because U-Boot's autoboot checks that memory address
before any network attempt. See Trophy Case entries 19, 20, 21.

#### Step 4 phase 1: meta-adi layers + kernel + conf templates ✅ COMPLETE

**Recipe inventory of meta-adi-xilinx on `2022_R2`:** 6 files only —
`linux-xlnx_%.bbappend`, `device-tree.bbappend`, `libiio_%.bbappend`,
`adrv9009-zu11eg-fan-control_dev.bb`, `fpga-manager-util_%.bbappend`,
and the dynamic-layer `petalinux-image-minimal.bbappend`. A *thin* layer
that mostly steers existing Xilinx recipes.

**Layers registered** (priorities 6 and 8 respectively; below our meta-ori
at 10, above oe-core):

```bash
bitbake-layers add-layer ~/yocto/haifuraiya/sources/meta-adi/meta-adi-core
bitbake-layers add-layer ~/yocto/haifuraiya/sources/meta-adi/meta-adi-xilinx
```

**local.conf additions** (also captured in
`haifuraiya/yocto/conf/local.conf.template`):

```
KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"
SRCREV:pn-linux-xlnx = "cd7e20c430dc19df7c32610e9d5b494d8f313e07"
KUIPER_COMPAT_USERADD = ""
KUIPER_COMPAT_SUDOERS = ""
```

**Validated:** parse-only `bitbake -n petalinux-image-minimal` succeeds
across 4230 tasks (3962 sstate hits from M1, ~268 new tasks). Real build
gets through ADI kernel `do_compile` cleanly (24 min wall clock from a
cold start). Hits `system-conf.dtsi missing` at device-tree `do_configure`
— see Trophy Case for the diagnosis.

**Conf templates updated** at `haifuraiya/yocto/conf/`:
- `local.conf.template` — Kirkstone→Honister header fix + new "M2 step 4"
  block with KERNEL_DTB + SRCREV pin + KUIPER_COMPAT suppression.
- `bblayers.conf.template` — meta-ori + meta-adi-core + meta-adi-xilinx
  promoted from comments into active BBLAYERS list; "Layer history"
  comment rewritten.

Verified live `local.conf` matches template functionally (one cosmetic
whitespace diff on `INHERIT += "plnx-mirrors"` vs `INHERIT+="plnx-mirrors"`
— bitbake parses both identically). Live `bblayers.conf` has 40 active
layer paths matching the template's 40.

#### Step 4 phase 2: Yocto XSA integration + ADRV9002 validation ⏳ NEXT

Gated on M2.5 (below) being banked first — we need a real ADRV9002-aware
`.xsa` and matching bitstream before the device-tree-with-pl-content stack
can meaningfully boot.

Work items (in order):
1. **Research the XSA substitution mechanism in meta-xilinx-tools.** The
   build currently uses `Xilinx-zcu102-zynqmp.xsa` shipped by
   meta-xilinx-tools. To swap in our M2.5 XSA, likely candidates are
   `HDF_BASE_PATH` / `HDF_EXT_PATH` overrides, or feeding via
   `gen-machine-conf`. Verify and document.
2. **Write `meta-ori/recipes-bsp/device-tree/device-tree.bbappend`**
   providing a minimal `system-conf.dtsi` stub (just `/dts-v1/; / { };`
   or equivalent) to satisfy meta-adi's sed. This is the pure-Yocto-vs-
   Petalinux flow bridge.
3. **Rebuild Yocto** — first build with the new XSA + stub. Expect kernel
   sstate to mostly survive; device-tree + image regen will rerun.
4. **Update `scripts/zcu102_jtag_boot.tcl`** to load `system_top.bit`
   onto the PL before kernel boot (`fpga -f <bitstream>` step).
5. **Deploy and validate.** On boot:
   - `dmesg | grep -i adrv9002` — driver probes successfully
   - `ls /sys/bus/iio/devices/` — IIO device for ADRV9002 visible
   - `iio_info` — enumerates the chip with its channels
   - Bonus: `iio_attr -d adrv9002-phy` — reads phy attributes

If those all pass, that's full **M2 step 4 banked** — ADI's reference
ADRV9002 stack working end-to-end on our Yocto build, validating the
toolchain before Phase 2a's Haifuraiya XSA arrives in M3.

---

### M2.5: ADI HDL reference design build ✅ COMPLETE (2026-05-18)

**Why this exists:** M2 step 4 phase 1 proved meta-adi's machinery works
inside our Yocto stack (layer registration, kernel compile, conf templates
captured). But validating the ADRV9002 driver against real hardware needs
two things that pure Yocto can't produce by itself:
1. An `.xsa` containing ADRV9002-compatible PL infrastructure (AXI DMAC,
   JESD204 framers, AXI register interfaces matching the device tree).
2. A bitstream that loads that PL infrastructure onto the actual ZCU102.

ADI's `adrv9001_zcu102` reference HDL project produces both. M2.5 is
"build that reference design from source, banking the XSA + bitstream
artifacts for M2 step 4 phase 2 integration."

**Architectural payoff:** Phase 2a (Haifuraiya channelizer in PL) will
*modify* ADI's reference design rather than build from scratch — the
channelizer slots between `axi_adrv9001` (sample source) and `axi_dmac`
(path to memory). So building ADI's reference now also banks reusable
Vivado IP (`axi_adrv9001`, `axi_dmac`, `axi_sysid`, `sysid_rom`,
`util_cpack2`, `util_upack2`, plus transitive deps `util_cdc` and
`util_axis_fifo`) that Phase 2a inherits.

**Submodule setup:**

```bash
cd ~/brown/Mode-Dynamic-Transponder
git submodule add https://github.com/analogdevicesinc/hdl.git haifuraiya/third_party/hdl
git config -f .gitmodules submodule.haifuraiya/third_party/hdl.branch hdl_2022_r2
cd haifuraiya/third_party/hdl
git checkout hdl_2022_r2
cd ~/brown/Mode-Dynamic-Transponder
git add .gitmodules haifuraiya/third_party/hdl
git commit
```

Pin recorded in `.gitmodules`. Submodule size is large (~1-2 GB) but
peripheral to runtime — only consumed during Vivado synthesis.

**Build invocation:**

```bash
source /tools/Xilinx/Vivado/2022.2/settings64.sh    # symlink to /opt
cd ~/brown/Mode-Dynamic-Transponder/haifuraiya/third_party/hdl/projects/adrv9001/zcu102
time make 2>&1 | tee /tmp/adrv9001-zcu102-build-$(date +%Y%m%d-%H%M).log
```

ADI's build framework (`projects/scripts/project-xilinx.mk`) cascades:
1. `lib:` target — `make xilinx` in each LIB_DEPS library directory. For
   adrv9001_zcu102: `util_cdc`, `axi_adrv9001`, `util_axis_fifo`, `axi_dmac`,
   `axi_sysid`, `sysid_rom`, `util_cpack2`, `util_upack2` (8 IPs total —
   the 6 explicitly listed plus 2 transitive deps).
2. `$(PROJECT_NAME).sdk/system_top.xsa` target — `vivado -mode batch -source
   system_project.tcl` for synth + place + route + write_hw_platform.

**Artifacts produced:**

```
projects/adrv9001/zcu102/
├── adrv9001_zcu102.sdk/system_top.xsa      ← 2.3 MB (feeds Yocto build)
├── adrv9001_zcu102.runs/impl_1/system_top.bit  ← 9.9 MB (PL bitstream)
└── adrv9001_zcu102_vivado.log               ← full build log
```

**Verified outcome:** 8/8 library IPs built OK, project built OK. 26 min
real / 29 min user / 6 min sys wall clock on mymelody (parallelism modest
but functional). Vivado log tail: "Successfully created Hardware Platform",
"Exiting Vivado at Mon May 18 21:56:41 2026", no timing failures.

**What this proves:**
- ✅ adi-hdl submodule integration works
- ✅ `hdl_2022_r2` branch is buildable end-to-end on Vivado 2022.2
- ✅ ADRV9002 reference design XSA + bitstream now sit on mymelody, ready
   to feed M2 step 4 phase 2
- ✅ Vivado licensing on mymelody is functional via CHONC-shared install
   at `/opt/Xilinx/` (`/tools` symlink)


### M3: Image built against Phase 2a .xsa (Haifuraiya in PL) ⏳

(Unchanged from previous plan — wait for Phase 2a `.xsa`.)

### M4: Userspace mmap reads VERSION register = 0x00010000 ⏳

(Unchanged from previous plan.)

### M5: Takadono v0 publishes channelizer state via MQTT ⏳

(Unchanged from previous plan.)

---

## 🛰️ JTAG Boot Procedure (canonical recipe — keep this current)

This is the canonical JTAG deployment recipe. Everything between
"power-on" and "root prompt via SSH" is here. As of M2 step 3, **the boot
requires zero human keystrokes during the process** — U-Boot's autoboot
finds our boot.scr at memory address 0x20000000 and runs through the
setenv/tftpboot/booti sequence automatically.

### Quick reference (truly: 3 commands once everything is set up)

```bash
# On mymelody (build host):
./scripts/copy_to_keroppi.sh

# On keroppi (lab VM), in one terminal:
screen -L -Logfile ~/boot_$(date +%H%M).log /dev/zcu102_uart1 115200
# (have Paul or remote-power-control power-cycle the ZCU102 here)

# On keroppi, in another terminal:
cd /tmp/abraxas3d-yocto-boot && ./run_jtag_boot.sh

# ~30 seconds later, from keroppi:
ssh root@10.73.1.16
# → root shell on ZCU102
```

That's it. No more catching the autoboot countdown, no more typing
`setenv serverip` + `tftpboot` + `booti` at U-Boot prompts. The
hands-off boot replaces the manual sequence entirely.

### Pre-flight checklist (do these once per session)

- [ ] **SD card pulled from ZCU102.** Without this, U-Boot's autoboot
      eventually falls through to mmc0 if the boot.scr-at-0x20000000
      path has any hiccup, and it might load an old kernel from SD with
      mismatched rootfs expectations. SD-free = clean fallback chain.
- [ ] **Boot mode switches (SW6) set to JTAG:** all four positions OFF.
      Only sampled at power-on; after changing, **power-cycle**.
      Confirmed via U-Boot reporting `Bootmode: JTAG_MODE`.
- [ ] **TFTP daemon running on keroppi:**
      ```
      sudo systemctl status tftpd-hpa
      ps aux | grep in.tftpd | grep -v grep
      sudo ss -ulnp | grep :69
      ```
      Should see a process and a listening port. If `Tasks: 0` despite
      "Active: running" — check `which in.tftpd` (the binary may be missing
      despite the package showing "installed"); reinstall.
- [ ] **hw_server running on keroppi:**
      ```
      source /tools/Xilinx/Vivado/2022.2/settings64.sh
      pgrep hw_server || hw_server -d
      ```
      Default port 3121. Our xsdb script connects with explicit
      `connect -url tcp:127.0.0.1:3121`.
- [ ] **boot.scr exists** in `~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/scripts/`.
      If not, regenerate from boot-script.txt:
      ```
      cd haifuraiya/yocto/scripts
      ./make_boot_scr.sh
      ```

### How the hands-off boot works (mental model)

```
xsdb script loads to memory:
  PMU firmware  → /tmp/.../ (loaded into PMU MicroBlaze)
  FSBL.elf      → 0xfffc0000 (OCM, Cortex-A53)
  ATF.bin       → 0xfffea000 (OCM, BL31 runtime)
  U-Boot.elf    → 0x08000000 (DDR)
  boot.scr      → 0x20000000 (DDR, U-Boot autoboot will find it here)

  Then: rwr pc 0xfffea000 (override to ATF entry, not U-Boot entry)
  Then: con

Execution chain:
  ATF runs, transitions EL3 → EL2, jumps to U-Boot
  U-Boot starts at EL2, prints banner
  U-Boot's autoboot checks 0x20000000 → finds our boot.scr → runs it
  boot.scr does: setenv (static IPs) + tftpboot kernel/dtb/initramfs + booti
  Linux kernel boots
  systemd starts
  systemd-networkd applies /etc/systemd/network/10-eth0.network
  → eth0 = 10.73.1.16/24
  sshd starts → port 22 listening
  → login prompt on serial, AND SSH reachable
```

### Detailed steps

**Step 1: Build artifacts on mymelody** (10-15 min incremental, hours first build)
```bash
cd ~/yocto/haifuraiya
source setupsdk
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

**Step 2: Generate boot.scr if needed** (only if boot-script.txt changed)
```bash
cd ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/scripts
./make_boot_scr.sh
```

**Step 3: Deploy to keroppi** (single command, copies everything needed)
```bash
./copy_to_keroppi.sh
```

This copies:
- Yocto-built FSBL/PMU/ATF/U-Boot → `/tmp/abraxas3d-yocto-boot/`
- boot.scr + zcu102_jtag_boot.tcl + run_jtag_boot.sh → `/tmp/abraxas3d-yocto-boot/`
- Kernel + dtb + initramfs → `/tftpboot/abraxas3d-yocto/`

**Step 4: Open serial console with logging on keroppi**
```bash
ssh abraxas3d@keroppi
screen -L -Logfile ~/boot_$(date +%Y%m%d_%H%M).log /dev/zcu102_uart1 115200
```

**Step 5: Power-cycle the ZCU102.** In JTAG boot mode, serial console
shows nothing at power-on (BootROM is silent without a boot source).
That's correct.

**Step 6: Run JTAG boot from another keroppi terminal**
```bash
cd /tmp/abraxas3d-yocto-boot
./run_jtag_boot.sh
```

**Step 7: Watch the serial console.** The boot is hands-off but worth
watching for the success markers:
- `NOTICE:  ATF running on XCZU9EG/...` — ATF runs
- `EL Level: EL2` — exception level correct
- `Bootmode: JTAG_MODE` — boot mode pins correct
- `JTAG: Trying to boot script at 20000000` — autoboot finds our script
- `## Executing script at 20000000` — boot.scr is running
- `our IP address is 10.73.1.16` — static IPs took effect
- `Bytes transferred = 21592576` (kernel) — TFTP succeeded
- `Starting kernel ...` — booti called
- `zcu102-zynqmp login:` — Linux up

**Step 8: SSH in from keroppi**
```bash
ssh root@10.73.1.16
# First time: accept the host key fingerprint
# No password (debug-tweaks)
# Returns: root@zcu102-zynqmp:~#
```

### Troubleshooting

**If U-Boot reaches autoboot but doesn't find our script** (you see
`JTAG: SCRIPT FAILED: continuing...` followed by BOOTP retries):
- boot.scr may not have been loaded correctly
- Check xsdb output for `boot.scr loaded.` confirmation
- Verify `dow -data` line ran without error in run_jtag_boot.sh output

**If `EL Level: EL3` instead of EL2:**
- ATF wasn't run; PC redirect to ATF entry didn't take effect
- Check xsdb output for `PC set. pc: 00000000fffea000`
- If missing, the `rwr pc 0xfffea000` line is wrong/missing in the .tcl

**If `Bootmode: LVL_SHFT_SD_MODE1` instead of `JTAG_MODE`:**
- Boot mode switches still set to SD; flip to all-OFF and power-cycle

**If SSH won't connect but Linux booted:**
- First time may need host key acceptance — answer `yes`
- After image rebuild, host key changes; clean stale entry:
  ```
  ssh-keygen -R 10.73.1.16
  ```
  then retry.

**If `Loading: T T T T...` for the kernel TFTP** (lots of T retries):
- TFTP server may not be running; restart `tftpd-hpa`
- Or files in `/tftpboot/abraxas3d-yocto/` aren't world-readable; fix
  with `chmod a+r`.

### The development loop (what bitbake actually does for us)

**For future-you returning to this section** — this is the dev workflow
that closes the loop, explained without bitbake jargon.

A typical "change something, see it on the board" cycle:

```bash
# 1. Edit a recipe or config file in meta-ori
nano meta-ori/recipes-core/systemd/systemd/10-eth0.network

# 2. Rebuild the image
cd ~/yocto/haifuraiya/build
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

What bitbake does (the short version):
- **Parses recipes** (~10 sec): reads .bb files + .bbappend files, figures
  out what depends on what
- **Checks sstate cache** (~10 sec): for each task it needs to run, looks
  up "have I run this exact thing before with these exact inputs?" If
  yes, reuses the cached output instead of rebuilding
- **Runs the tasks that aren't cached**: for our scenario, this is usually
  just the affected recipe (e.g., systemd because we changed our
  .bbappend's input file) plus the rootfs assembly (because the resulting
  package changed)
- **Assembles the rootfs**: takes all packages, lays them out, produces
  the final cpio.gz / tar.gz / etc.

For a small change (config file edit, IMAGE_INSTALL append), this takes
**5-15 minutes** because sstate covers ~99% of the work.

For a big change (kernel config, new recipe with C compilation),
takes **30-60 minutes**.

For a clean fresh build (no sstate, rare), takes **4-6 hours**.

```bash
# 3. Redeploy to keroppi (auto-runs because copy_to_keroppi.sh checks
#    that boot.scr exists and bails if not)
cd ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/scripts
./copy_to_keroppi.sh

# 4. Power-cycle the ZCU102 (have Paul do this if remote)

# 5. Re-boot the system via JTAG
ssh abraxas3d@keroppi
cd /tmp/abraxas3d-yocto-boot && ./run_jtag_boot.sh

# 6. SSH in to verify
ssh root@10.73.1.16
# (after rebuild, ssh-keygen -R 10.73.1.16 if host key complaints)
```

End to end: **~5 minutes for small change**, mostly waiting for bitbake
to verify cache and reassemble the rootfs.

### Common patterns for meta-ori additions

**Pattern 1: Drop a config file into an existing package's rootfs install**
- Create `.bbappend` in `meta-ori/recipes-<category>/<package>/<package>_%.bbappend`
- Create `<package>/` subdirectory in the same location with your config file
- In .bbappend: `FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"` + `SRC_URI += "file://yourfile"` + `do_install:append() { install ... }` + `FILES:${PN}-subpackage += "..."`
- Example: our systemd_%.bbappend for the static IP config

**Pattern 2: Add a package to the image**
- Create `petalinux-image-minimal.bbappend` (or other image recipe) in `meta-ori/recipes-core/images/`
- Single line: `IMAGE_INSTALL:append = " package-name"`
- Example: our openssh addition

**Pattern 3: Add a device tree fragment** (coming for M3)
- Will document when we hit it for the Haifuraiya channelizer DT

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

### 19. PXE boot requires DHCP-populated serverip; static-IP labs need a different approach
**Symptom:** Dropped `pxelinux.cfg/default` into `/tftpboot/`, expected
U-Boot autoboot to find it. Instead saw:
```
BOOTP broadcast 1...17
Retry time exceeded; starting again
...
Retrieving file: pxelinux.cfg/01-00-0a-35-07-eb-c1
*** ERROR: `serverip' not set
```
PXE couldn't even attempt to fetch our config because serverip was never set.

**Root cause:** U-Boot's PXE flow does DHCP first to get serverip/ipaddr,
THEN attempts to fetch pxelinux.cfg. Our lab has no DHCP server (the
rogue Raspberry Pi that previously responded has been retired). Our
U-Boot has no persistent env storage configured (every boot starts with
empty env: `Loading Environment from nowhere... OK`). With no DHCP and
no persistent env, U-Boot can't get the network info PXE needs.

Petalinux setups typically work because they configure U-Boot to store
env in QSPI, so after a one-time `setenv` + `saveenv`, future boots
have the IPs persistent. Our Yocto build doesn't enable QSPI env.

**Fix:** Use a U-Boot boot script (`boot.scr`) loaded to memory
0x20000000. U-Boot's autoboot checks 0x20000000 FIRST, before any
network attempt. Our script there explicitly sets static IPs and does
tftpboot directly:
```
setenv serverip 10.73.1.94
setenv ipaddr   10.73.1.16
tftpboot 0x80000 abraxas3d-yocto/Image
...
booti 0x80000 0x4100000 0x4000000
```
Compiled with mkimage to produce boot.scr, loaded via xsdb's
`dow -data boot.scr 0x20000000`.

**Pattern:** When working in a static-IP, no-DHCP lab, PXE isn't a
viable path without persistent U-Boot env. The 0x20000000 script
approach replaces it cleanly.

### 20. U-Boot autoboot's check at 0x20000000 is the magic injection point
**Symptom (positive observation):** During autoboot, U-Boot prints:
```
JTAG: Trying to boot script at 20000000
## Executing script at 20000000
```
**Before any other boot attempt.** Including before mmc, qspi, network,
USB, anything.

**Root cause / mechanism:** AMD's U-Boot for ZynqMP includes a custom
autoboot sequence (visible in `bootcmd`'s default) that begins with a
"JTAG script" check at a fixed memory address (0x20000000 in our case).
This is specifically designed for JTAG-deployed development where the
debugger has loaded a U-Boot script to known memory.

**Use:** Put a `mkimage`-wrapped U-Boot script at 0x20000000 via xsdb,
and U-Boot will run it automatically with no human interaction needed.
Bypasses DHCP, PXE, MMC, QSPI, USB — all of them.

**Pattern:** For JTAG-only labs, the 0x20000000 script is the cleanest
"no-typing boot" mechanism. Better than PXE (no DHCP), better than env
persistence (no flash writes), better than command-line injection (no
custom xsdb hacks).

### 21. Boot mode pins don't stop U-Boot from accessing SD/QSPI fallback
**Symptom:** With SW6 set correctly to JTAG (all OFF), board still
showed U-Boot eventually loading an old kernel from SD card:
```
Bootmode: JTAG_MODE                                     ← correct mode
...
[much boot sequence failure later...]
switch to partitions #0, OK
mmc0 is current device
Scanning mmc 0:1...
Found U-Boot script /boot.scr                           ← OLD script from SD
33221120 bytes read in 2971 ms (10.7 MiB/s)             ← OLD kernel
...
[    0.000000] Linux version 5.10.0-xilinx-v2021.1 ...  ← OLD Yocto
```

**Root cause:** Boot mode pins (SW6) are sampled by the BootROM at
power-on. They control what the BootROM loads. Once U-Boot is running
(loaded via JTAG), it can access ALL connected storage devices including
SD card, QSPI, eMMC, USB. U-Boot's autoboot tries them in sequence as
fallbacks if the primary boot fails. The SD card with leftover content
from a previous project is in the fallback chain regardless of pin
settings.

**Fix:** Physically remove the SD card from the board for JTAG-only
development. Alternatives: rename `/boot.scr` on the SD card so U-Boot
doesn't find it; or overwrite SD card content with our new image.

**Pattern:** Boot mode pins only affect the BootROM. Storage media
present on the board can still interfere with U-Boot's autoboot
fallback. When debugging unexpected boot behavior, **physically
inventory what's attached to the board** — including SD cards that
might've been left in from a previous session.

### 22. dropbear vs openssh: Petalinux distro_features chooses dropbear by default
**Symptom (sub-issue from an intermediate build):** Added `openssh` to
IMAGE_INSTALL, but `systemctl status sshd` showed:
```
* dropbear.service - LSB: Dropbear Secure Shell server
     Loaded: loaded
     Active: inactive (dead)
```
Dropbear was present (not openssh's sshd) AND inactive. SSH from
keroppi was hit-or-miss depending on the build.

**Root cause:** Yocto/Petalinux distros include a `DISTRO_FEATURES`
list that influences which packages are pulled into images. Petalinux's
distro includes `ssh-server-dropbear`, which causes dropbear to be
installed as the SSH server. Adding `openssh` to IMAGE_INSTALL adds the
openssh package files but doesn't override the systemd unit selection —
result was dropbear installed AND openssh package files installed,
with confused service activation.

**Eventual fix (what worked in the final M2 build):** The openssh
package's recipe registered sshd.service correctly. After a clean
rebuild (no stale state), openssh's sshd was active and responding;
dropbear was either inactive or shadowed. SSH from keroppi worked.

**Cleaner long-term fix (for later):** Override DISTRO_FEATURES to
remove ssh-server-dropbear and add ssh-server-openssh, in a meta-ori
distro layer override. For now the current behavior works.

**Pattern:** When dealing with conflicts between similar packages
(SSH, NTP daemons, init systems), check DISTRO_FEATURES first
(`bitbake -e <image> | grep ^DISTRO_FEATURES=`) before adding overlapping
packages via IMAGE_INSTALL. Yocto's preferred mechanism for "use X
instead of Y" is `DISTRO_FEATURES_remove` + `DISTRO_FEATURES_append`,
not multiple IMAGE_INSTALL additions.

### 23. meta-adi's bbappend assumes Petalinux flow, breaks pure Yocto

**Symptom:** Yocto build of `petalinux-image-minimal` proceeds through ADI
kernel compile cleanly, then fails at device-tree `do_configure`:

```
sed: can't read .../device-tree-build/device-tree/system-conf.dtsi: No such file or directory
WARNING: exit code 2 from a shell command.
ERROR: Task (.../meta-xilinx-core/recipes-bsp/device-tree/device-tree.bb:do_configure) failed
```

**Diagnosis:** `system-conf.dtsi` is a **Petalinux-tool artifact**, generated
by `petalinux-config --get-hw-description=<xsa>` as part of Petalinux's own
flow. It contains software-side decisions (bootargs, root filesystem type,
chosen node) that don't come from the .xsa itself. In pure Yocto with
meta-xilinx-tools, `hsi` runs (and produces `system.dts`, `system-top.dts`,
`pl.dtsi`, etc. — 26 files) but **not** `system-conf.dtsi`. meta-adi-xilinx's
`device-tree.bbappend` `seds` that file unconditionally in its
`do_configure:append()`, assuming Petalinux flow.

**Trace:** the file `hsi` actually produces vs the file meta-adi expects:
```
Produced by hsi:                   Expected by meta-adi:
  system.dts ✅                       system-conf.dtsi ❌ (missing)
  system-top.dts ✅
  pl.dtsi ✅
  zcu102-rev1.0.dtsi ✅
  zynqmp.dtsi ✅
  hardware_description.xsa ✅
  ... (20 others) ...
```

**Fix (planned):** `meta-ori/recipes-bsp/device-tree/device-tree.bbappend`
providing a minimal `system-conf.dtsi` stub (`/dts-v1/; / { };` or
equivalent). The stub satisfies meta-adi's sed without changing hardware
behavior. This is **not throwaway** — it's required for any pure-Yocto
build using meta-adi-xilinx, regardless of which .xsa is in use.

**Lesson:** "Yocto support" in vendor layers often means "Petalinux's
underlying Yocto" — pure-Yocto users hit assumption seams. Read bbappends
before assuming compatibility.

---

### 23. ADI kernel bbappend defaults to AUTOREV in online mode

**Symptom:** Not really a symptom — a reproducibility gun pointed at our
foot. `meta-adi-xilinx/recipes-kernel/linux/linux-xlnx_%.bbappend`:

```
SRCREV = "${@ "cd7e20c430..." if bb.utils.to_boolean(d.getVar('BB_NO_NETWORK')) else d.getVar('AUTOREV')}"
```

In online builds (BB_NO_NETWORK unset, which is our default), SRCREV is
**AUTOREV** — meaning every build pulls whatever HEAD of `analogdevicesinc/linux@adi_master`
is at fetch time. Two builds an hour apart could pull different commits
without any local change.

**Fix:** explicit pin in `local.conf`:
```
SRCREV:pn-linux-xlnx = "cd7e20c430dc19df7c32610e9d5b494d8f313e07"
```

Convenient detail: that exact commit is what ADI's own offline-CI build
uses (the bbappend's BB_NO_NETWORK fallback). So pinning to it doesn't
just freeze drift — it aligns us with ADI's reference build.

**Lesson:** any kernel recipe that uses AUTOREV is a footgun. Pin SRCREV
or accept silent commit drift between builds.

---

### 24. meta-adi keeps `linux-xlnx` recipe name but swaps the source

**Subtle pattern worth knowing.** meta-adi-xilinx's `linux-xlnx_%.bbappend`
does NOT use a `PREFERRED_PROVIDER_virtual/kernel` swap. The recipe name
stays `linux-xlnx`. Instead, the bbappend overrides `KERNELURI` to point
at `analogdevicesinc/linux.git`, and changes `KBUILD_DEFCONFIG` to
`adi_zynqmp_defconfig`. Net effect: the recipe identity is unchanged, the
source is *completely* replaced.

**Consequences:**
- No need to add `PREFERRED_PROVIDER_virtual/kernel = "linux-adi"` to
  local.conf. Don't waste time looking for a `linux-adi` recipe.
- Kernel sstate from M1 is fully invalidated because the SRC_URI and
  KBUILD_DEFCONFIG changed → different task hashes → full kernel rebuild.
- Kernel version (5.15.36) stays the same as Xilinx stock; only the
  *contents* differ (ADI's driver set baked in).

**Lesson:** when checking which kernel will actually build, look at the
recipe's `SRC_URI`/`KERNELURI` not just the recipe name. Vendor layers
sometimes graft new source onto old recipes.

---

### 25. KUIPER_COMPAT silently overrides debug-tweaks

**Symptom (subtle):** after adding meta-adi-xilinx, root password becomes
"analog" instead of empty. SSH still works with the new password but the
empty-password convenience of `EXTRA_IMAGE_FEATURES = "debug-tweaks"` is
gone, and the change happens silently — no warning during build.

**Diagnosis:** `meta-adi-xilinx/dynamic-layers/meta-petalinux/recipes-core/images/petalinux-image-minimal.bbappend`
adds machinery for Kuiper-Linux compatibility (Kuiper is ADI's Raspbian-
based reference image). The Kuiper convention is root password = "analog".
The bbappend sets `EXTRA_USERS_PARAMS` via `KUIPER_COMPAT_USERADD` /
`KUIPER_COMPAT_SUDOERS` variables, which apply *after* debug-tweaks and
overwrite it.

**Fix:** suppress KUIPER_COMPAT explicitly in local.conf:
```
KUIPER_COMPAT_USERADD = ""
KUIPER_COMPAT_SUDOERS = ""
```

Empty strings → no users get added by meta-adi's append → debug-tweaks
empty-password root survives.

**Lesson:** debug-tweaks gives weak defaults; downstream bbappends in
vendor layers can override them silently. If you depend on debug-tweaks
behavior, audit any new layer's image bbappends for `EXTRA_USERS_PARAMS`.

---

### 26. ADI HDL's `project-xilinx.mk` lives in `projects/scripts/`, not repo root `scripts/`

**Symptom:** project Makefile says `include ../../scripts/project-xilinx.mk`,
but the repo root `scripts/` directory contains only `adi_env.tcl` — no
`project-xilinx.mk`. Looks broken.

**Diagnosis:** path-math error on the reader's part (not the framework's).
From `projects/adrv9001/zcu102/`, `../../scripts/` resolves to
`projects/scripts/` — *not* the repo root's `scripts/`. ADI has TWO
`scripts/` directories:

```
hdl/
├── scripts/                    ← top-level utilities (adi_env.tcl)
└── projects/
    └── scripts/                ← project build framework (project-xilinx.mk,
                                   project-toplevel.mk, project-intel.mk)
```

The Makefile's include is correct; the relative path navigates exactly
right.

**Lesson:** when chasing missing-file errors in a multi-level build system,
do the path math manually before concluding the framework is broken. ADI's
HDL repo is well-trodden and unlikely to ship a release branch with an
obviously-broken include.

### Cross-cutting lessons (Phase 2b chapter)

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
- **Boot mode pins don't stop U-Boot from accessing flash/SD fallback.**
  Pin settings only affect the BootROM. Pull physical media you don't
  want in the boot fallback chain.
- **0x20000000 is U-Boot's first autoboot check** on ZynqMP. Loading a
  mkimage-wrapped script there via xsdb gives you full control with
  zero typing required.
- **DISTRO_FEATURES governs which "system services flavor" gets included.**
  Check it first before adding similar packages via IMAGE_INSTALL.
  `bitbake -e <image> | grep ^DISTRO_FEATURES=`
- **D&D commit messages persist memory.** Cast PROTECTION FROM PMU SLEEP.
  Cast IDENTIFY ATF ENTRY. Cast COUNTERSPELL TRANSLATION FAULT. Cast
  AWAKEN THE MICROBLAZE. Cast SCRIBE BUILD INVOCATION. Cast SUMMON
  FAMILIAR. Cast TELEPORT.

---

## ❓ Open Questions / Issues for Investigation

These came up during M1/M2 closeout and are not blocking but worth tracking:

1. **CPU 1 doesn't come online.** `cat /proc/cpuinfo` shows only CPUs 0, 2,
   3. ZCU102 has 4× Cortex-A53. CPU 1 fails PSCI bring-up. Not blocking
   (3 cores are plenty), but worth investigating during Phase 3 hardware
   integration. May be related to ATF handoff context being incomplete via
   JTAG (vs full BOOT.BIN flow), or device tree CPU 1 node config.

2. ~~**No persistent IPv4 on eth0.**~~ ✅ Resolved by M2 step 1 (static IP
   via systemd-networkd dropin in meta-ori).

3. ~~**ICMP / ping from outside.**~~ ✅ Resolved by M2 step 1 — Paul confirmed
   ping from keroppi succeeds.

4. ~~**U-Boot env doesn't persist across boots.**~~ ✅ Worked around via M2
   step 3 (boot.scr at 0x20000000 sets env at runtime, no persistence
   needed). Not strictly resolved (env is still volatile) but no longer
   matters for our workflow.

5. ~~**PXE boot file would eliminate manual TFTP typing.**~~ ✅ Resolved by
   M2 step 3 via the boot.scr-at-0x20000000 approach (cleaner than PXE
   for no-DHCP labs).

6. ~~**openssh-server not in default image.**~~ ✅ Resolved by M2 step 2
   (added to IMAGE_INSTALL via meta-ori bbappend).

7. ~~**dropbear vs openssh DISTRO_FEATURES override.**~~ Still open — long-term polish; tracked but not blocking.

8. **SSH host key changes on every boot** (rootfs is ephemeral
   initramfs). Each new boot generates fresh host keys, triggering
   "REMOTE HOST IDENTIFICATION HAS CHANGED" warnings on the keroppi side.
   Workaround: `ssh-keygen -R 10.73.1.16` before each reconnect.
   Long-term fix involves persistent storage for /etc/ssh/ — see item 9.

9. **Non-volatile storage transition (Phase 4+).** The satellite needs
   persistent storage in flight; the ephemeral-initramfs JTAG-deploy
   workflow won't work there. Options to evaluate when we get to Phase
   4/5:
   - QSPI flash for FSBL + U-Boot + Linux + bootloader env (standard sat
     pattern, what ZCU102's QSPI is already wired for)
   - eMMC for rootfs (if flight board has it)
   - NAND (less common for ARM SoCs but option exists)
   - SD card (mechanically iffy in space, radiation concerns — usually
     not flight-suitable)
   For Phase 2-3 (now through First Light), JTAG+TFTP is intentional:
   always-clean state, no flash wear, fast iteration.
   
10. **meta-adi 2022_R2 LAYERDEPENDS includes `adi-core`**. ✅ Resolved
    — both `meta-adi-core` and `meta-adi-xilinx` are now registered. Order
    matters: core must be added before xilinx.

11. **Kernel-fork swap mechanism in meta-adi-xilinx.** ✅ Resolved — no
    PREFERRED_PROVIDER swap. Recipe stays `linux-xlnx`; bbappend overrides
    KERNELURI to ADI's fork. See Trophy Case.

12. **ADI HDL branch alignment with meta-adi 2022_R2.** ✅ Resolved —
    `hdl_2022_r2` is the matching branch on `analogdevicesinc/hdl`. Pinned
    via .gitmodules.
    
13. **Yocto XSA substitution mechanism.** Current build uses
    `Xilinx-zcu102-zynqmp.xsa` from meta-xilinx-tools by default. To swap
    in our M2.5 `system_top.xsa`, options include `HDF_BASE_PATH` /
    `HDF_EXT_PATH` overrides in local.conf, or feeding via
    `gen-machine-conf`. Needs research — first work item of M2 step 4
    phase 2.

14. **JTAG bitstream-load integration.** Current `zcu102_jtag_boot.tcl`
    boots PMU → FSBL → ATF → U-Boot → Linux without loading a PL bitstream.
    For ADRV9002 device tree to find matching hardware, we need an
    `fpga -f system_top.bit` step inserted before kernel handoff. Update
    the .tcl and document in JTAG Boot Procedure section.

15. **system-conf.dtsi stub recipe.** meta-ori needs a
    `recipes-bsp/device-tree/device-tree.bbappend` providing a minimal
    `system-conf.dtsi` file. The stub bridges the Petalinux-flow assumption
    in meta-adi-xilinx's bbappend with pure-Yocto reality. See Trophy Case
    for full diagnosis.

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
| Rogue DHCP server in lab (a Raspberry Pi) | **Hit (now retired)** | When lab convention says "static IPs only", verify NO DHCP server is actually running. Rogue devices can mask real issues. |
| PXE boot requires DHCP for serverip | **Hit** | Use boot.scr at 0x20000000 instead (works without DHCP) |
| Boot mode pins don't stop U-Boot's storage fallback | **Hit** | Physically remove SD card / unwanted media for clean JTAG-only boot |
| DISTRO_FEATURES conflicts (dropbear vs openssh) | **Hit** | Long-term: override DISTRO_FEATURES in meta-ori distro layer. Short-term: works as-is. |
| meta-adi-xilinx assumes Petalinux flow (system-conf.dtsi) | **Hit** | Fix planned via meta-ori device-tree.bbappend stub. Trophy case entry. |
| ADI kernel bbappend defaults to AUTOREV | **Hit** | Pin SRCREV:pn-linux-xlnx explicitly in local.conf. Trophy case entry. |
| KUIPER_COMPAT silently overrides debug-tweaks | **Hit** | Suppress with KUIPER_COMPAT_USERADD="" + KUIPER_COMPAT_SUDOERS="". |
| adi-hdl submodule is large (~1-2 GB) | Low | One-time clone cost; pinned via .gitmodules for reproducibility. |
| Vivado XSA may need substitution mechanism research | Medium | M2 step 4 phase 2 work item 1; HDF_BASE_PATH or gen-machine-conf candidates. |
| Bitstream loading not yet in JTAG boot script | Medium | Update zcu102_jtag_boot.tcl with fpga -f step before kernel handoff. |

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
- ADI HDL build framework (project-xilinx.mk):
  `~/brown/Mode-Dynamic-Transponder/haifuraiya/third_party/hdl/projects/scripts/project-xilinx.mk`
- ADI HDL Wiki (build instructions): https://wiki.analog.com/resources/fpga/docs/build
- ADRV9002 device tree source (the file KERNEL_DTB selects):
  `analogdevicesinc/linux@adi_master:arch/arm64/boot/dts/xilinx/zynqmp-zcu102-rev10-adrv9002.dts`
- ADI HDL adrv9001/zcu102 project on 2022_R2:
  https://github.com/analogdevicesinc/hdl/tree/hdl_2022_r2/projects/adrv9001/zcu102

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

*Last updated: 2026-05-18 (continued session), M2 step 4 phase 1 + M2.5
banked. Phase 2b chapter 4: meta-adi-core + meta-adi-xilinx registered;
ADI kernel (linux-xlnx with source swapped to analogdevicesinc/linux@cd7e20c4
on 2022_R2) compiles cleanly in 24 min; conf templates updated and verified
to match live build. Phase 2b chapter 5: adi-hdl added as submodule pinned
to hdl_2022_r2; `adrv9001_zcu102` reference design built in Vivado 2022.2
producing system_top.xsa (2.3 MB) + system_top.bit (9.9 MB) in 26 min,
clean Vivado log, no timing failures. Five new trophy case entries banked
(Petalinux-vs-Yocto seam, AUTOREV gotcha, kernel-source-swap pattern,
KUIPER_COMPAT override, project-xilinx.mk location). Next focus: M2 step 4
phase 2 — Yocto XSA integration + system-conf.dtsi stub + JTAG bitstream
load + real ADRV9002 driver probe on hardware.*
