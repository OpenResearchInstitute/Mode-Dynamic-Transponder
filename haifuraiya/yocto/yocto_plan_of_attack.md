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
| ✅ | Decision: Vivado 2022.2 (locked) | License constraint; pairs with Yocto Kirkstone |
| ✅ | Decision: meta-ori layer scope | Lives at `haifuraiya/yocto/meta-ori/`; per-project (not parent-repo-wide) |
| ✅ | Host packages installed | Ubuntu 22.04 deps via apt; en_US.UTF-8 locale generated |
| ✅ | Build tree `repo init` + `repo sync` | At `~/yocto/haifuraiya/`; all 5 required layers populated at `xlnx-rel-v2022.2` |
| ✅ | Version stack pinned (commit SHAs) | See "Pinned Version Stack" below — all five layers locked |
| 🎯 | **Next concrete action** | **`source yocto-scripts/setupsdk` and start the first vanilla bitbake (M1)** |
| ⏳ | M1: vanilla zcu102 image boots | First milestone — proves build environment works |
| ⏳ | M2: ADI-flavored image w/ ADRV9002 device tree boots | Second milestone — matches existing Petalinux baseline |
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
| Yocto release | **Kirkstone (4.0)** | Pairs with Vivado 2022.2 |
| Xilinx manifest | **`rel-v2022.2`** from `github.com/Xilinx/yocto-manifests.git` | AMD-recommended, pulls a consistent layer set |
| Host OS | **Ubuntu 22.04 LTS** | Yocto Kirkstone's primary supported host |
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

**Important nomenclature note:** AMD's manifest names `poky/` as `core/` —
it contains oe-core + bitbake but without the meta-poky / meta-yocto-bsp
layers that the upstream Poky distribution would include (Xilinx provides
machine support via meta-xilinx-bsp instead). Throughout this doc,
references to "core" mean the AMD-shipped `sources/core/` directory.

### Caveat worth knowing

Yocto Kirkstone's nominal LTS window ended in April 2026. Community-
extended LTS continues with security patches, but upstream community focus
has shifted to Scarthgap (2024) and Walnascar (2025). For our use case —
an FPGA dev/deployment host with no internet-facing exposure — this is
fine. The risk is bug reports against meta-xilinx getting "please retest
on scarthgap" responses. Mitigation: the pins above are explicit; we
document the workarounds we discover; we treat this version stack as our
stable platform.

This is *not* the wrong stack. It's the right stack given our license
constraint, and it's well-trodden by the community.

---

## 📚 What AMD's Manifest Actually Pulled

The `rel-v2022.2` manifest is much bigger than just the 5 required layers.
After `repo sync`, `sources/` contains:

### Required (we activate these in bblayers.conf)

| Directory | What it is |
|---|---|
| **`core/`** | oe-core + bitbake (the build engine — Poky-equivalent without meta-poky/meta-yocto-bsp) |
| **`meta-openembedded/`** | oe-core extras: meta-oe (mosquitto, libpaho), meta-python, meta-networking, meta-webserver, meta-multimedia, meta-perl |
| **`meta-xilinx/`** | Xilinx hardware support (Zynq, ZynqMP, MicroBlaze) |
| **`meta-xilinx-tools/`** | Xilinx toolchain integration (XSCT-dependent recipes) |
| **`meta-petalinux/`** | "petalinux-image-minimal" recipe lives here despite the name |

### Available but inactive (pulled by repo sync, not in bblayers.conf)

| Directory | What it is | Relevance to us |
|---|---|---|
| `meta-jupyter` | JupyterLab on target | **Likely add in M3/M4** for live debug + spectrum prototyping |
| `meta-openamp` | OpenAMP for R5F real-time cores | Future (Phase 5 if we use R5F) |
| `meta-security` | Hardening recipes | Future polish for production deployment |
| `meta-xilinx-tsn` | Time-Sensitive Networking | Not now |
| `meta-som` | Kria System-on-Module support | Not relevant (we're on ZCU102) |
| `meta-vitis` | Vitis acceleration framework | Not now |
| `meta-virtualization` | Xen/KVM | Overkill |
| `meta-ros` | ROS2 | Not relevant |
| `meta-qt5` | Qt5 desktop GUI | Not relevant — Takadono is web-based |
| `meta-browser` | Web browsers on target | Not relevant |
| `meta-clang` | Clang/LLVM | Optional |
| `meta-mingw` | Windows cross-compile SDK | Not relevant |
| `meta-python2` | Legacy Python 2 | Hopefully never |

### Infrastructure (not layers per se)

| Directory | What it is |
|---|---|
| `manifest/` | repo tool metadata |
| `yocto-scripts/` | helper scripts incl. `setupsdk` (the build-environment activator) |

---

## 🖥️ Build Host Setup

### Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| Disk space | 65 GB | **100+ GB** (first build downloads ~15-20 GB of sources; build tree grows to ~50 GB; sstate cache is multi-GB) |
| RAM | 8 GB | **32 GB** (parallel compile is RAM-hungry) |
| CPU cores | 4 | 8+ (Yocto parallelizes well; more cores = shorter builds) |
| Network | broadband | broadband (first build fetches a *lot* of source) |

A first-time-from-scratch build takes 4-6 hours on a modern desktop
(coffee + Sunday morning kind of thing). Subsequent builds with cached
sstate are minutes.

### Operating system

**Ubuntu 22.04 LTS (Jammy)** is the primary supported host for Yocto
Kirkstone. Other Ubuntu LTS releases (20.04, 24.04) might work but will
have rough edges — recommend a VM or container if your host OS is
different.

**Do NOT use ZFS or any case-insensitive filesystem for the build tree.**
Bitbake assumes case-sensitive filenames and ZFS's deduplication can
corrupt sstate. Use ext4 or btrfs.

### Required packages (✅ done 2026-05-17)

```bash
sudo apt update && sudo apt install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev \
    python3-subunit mesa-common-dev zstd liblz4-tool file locales \
    libacl1

sudo locale-gen en_US.UTF-8
```

`repo` tool install (✅ done 2026-05-17):

```bash
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH="$HOME/bin:$PATH"
```

---

## 📁 Directory Layout

Two distinct trees: what's in git (small, reviewable) vs. what's on disk
(huge, regenerable).

### In the repo (`haifuraiya/yocto/`)

```
haifuraiya/yocto/
├── yocto_plan_of_attack.md          # this doc
├── meta-ori/                         # our custom Yocto layer
│   ├── conf/
│   │   └── layer.conf                # layer metadata (TBD)
│   ├── recipes-core/
│   │   └── images/                   # custom image recipes (TBD)
│   │       └── haifuraiya-image.bb   
│   ├── recipes-takadono/             # Takadono v0 publisher
│   │   └── takadono/
│   │       ├── takadono_0.1.bb       # recipe
│   │       └── files/                # source
│   └── recipes-haifuraiya/           # channelizer-specific
│       └── ...                       # device tree fragments, etc.
├── scripts/
│   ├── setup_build_host.sh           # apt install + repo install
│   ├── init_yocto_tree.sh            # repo init + sync
│   ├── pin_versions.sh               # capture & print current commit SHAs
│   └── build.sh                      # wrapper around bitbake
└── .gitignore                        # belt-and-suspenders gitignore
```

### On disk, out of repo (`~/yocto/haifuraiya/`)

```
~/yocto/haifuraiya/                   # NOT in git
├── .repo/                            # repo tool metadata
├── sources/                          # meta layers populated by repo sync
│   ├── core/                         # oe-core + bitbake (the "poky" of this stack)
│   ├── meta-openembedded/
│   ├── meta-xilinx/
│   ├── meta-xilinx-tools/
│   ├── meta-petalinux/
│   ├── meta-adi/                     # added separately (not in manifest) — M2
│   ├── meta-jupyter/                 # available, may activate in M3+
│   ├── [many more meta-* layers, all inactive by default]
│   ├── yocto-scripts/                # contains setupsdk
│   ├── manifest/                     # repo metadata
│   └── meta-ori -> /home/abraxas3d/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/meta-ori
│                                     # symlinked from the repo so layer
│                                     # edits in the repo flow into the build
└── build/                            # bitbake's working tree (created by setupsdk)
    ├── conf/                         # bblayers.conf, local.conf
    ├── tmp/                          # build artifacts (MASSIVE)
    ├── downloads/                    # fetched source (LARGE)
    └── sstate-cache/                 # build cache (LARGE)
```

The symlink for `meta-ori` is key: we edit our layer in the repo
(reviewable, committed), but bitbake sees it inside the build tree
naturally. No need to copy files back and forth.

### What goes in `.gitignore`

```
# Build trees (regenerable, huge)
build/
sources/
.repo/

# Per-developer host config
local.conf
bblayers.conf

# Yocto-generated SDK installers
*.sh.tar.gz
```

---

## 🏗️ Layer Stack

In dependency order (top has no deps; bottom depends on everything above):

```
core (oe-core + bitbake — Yocto's "poky" core, named "core" in AMD's manifest)
  └── meta-openembedded    (community extras — meta-oe, meta-python, meta-networking,
                            meta-webserver, meta-multimedia)
       └── meta-xilinx      (AMD/Xilinx hardware support — Zynq, ZynqMP, MicroBlaze)
            └── meta-xilinx-tools  (XSCT-dependent baremetal recipes)
                 └── meta-petalinux  (petalinux-image-minimal recipe)
                      └── meta-adi-xilinx  (ADRV9002 driver, libiio, device trees)
                           └── meta-ori   (Takadono publisher, channelizer device
                                           tree fragments, custom image)
```

Optional layers added later (when triggered by a specific need):

- **`meta-jupyter`** in M3/M4 if interactive debugging would help
- **`meta-security`** in Phase 5+ when going on a real public network

---

## 🎯 Milestones

Each milestone is a "stop here, save state, commit, take a break"
checkpoint. The deliberate-and-clean working style: prove M_N before
attempting M_N+1.

### M1: Vanilla zcu102-zynqmp image boots

**Goal:** prove the build environment is working end-to-end. No custom
hardware design, no custom layers, no ADI — just stock AMD content.

**Steps:**
```bash
cd ~/yocto/haifuraiya
source sources/yocto-scripts/setupsdk
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

(The `setupsdk` script is AMD's wrapper around `oe-init-build-env`. It
creates the `build/` directory with `conf/local.conf` and
`conf/bblayers.conf` configured for Xilinx defaults.)

**Deliverable:** SD card image at
`build/tmp/deploy/images/zcu102-zynqmp/*.wic`. Flash to SD, boot the
ZCU102, see Linux login prompt. Stock kernel, no ADRV9002 driver
loaded, no Haifuraiya — just baseline Linux.

**What this proves:** Yocto build host configured correctly, AMD layer
stack consistent at this manifest pin, ZCU102 boot chain (FSBL → ATF →
U-Boot → kernel) works.

### M2: ADI-flavored image with ADRV9002 device tree boots

**Goal:** add meta-adi-xilinx, build an image with the ADRV9002 driver
loaded and the ADI device tree active. Confirm sample stream still
works (regression-check our existing Petalinux baseline).

**Steps:**
```bash
# Clone meta-adi alongside the other meta layers
cd ~/yocto/haifuraiya/sources
git clone https://github.com/analogdevicesinc/meta-adi.git
cd meta-adi
# Check available branches; pick the one matching xlnx-rel-v2022.2
git branch -a
git checkout <branch matching 2022.2 — TBD>

# Add meta-adi-xilinx to bblayers.conf
cd ~/yocto/haifuraiya/build
bitbake-layers add-layer ../sources/meta-adi/meta-adi-xilinx

# Set kernel device tree to ADRV9002 variant
echo 'KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"' >> conf/local.conf

# Build
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

**Deliverable:** image boots, `dmesg | grep -i adrv9002` shows driver
loaded, `iio_info` lists the ADRV9002 device.

**Pin the meta-adi commit SHA** in the Version Stack table after this
step.

**What this proves:** meta-adi integrates cleanly with our manifest pin,
the ADI Linux kernel fork builds, device tree works.

### M3: Image built against Phase 2a .xsa (Haifuraiya in PL)

**Goal:** integrate our Phase 2a hardware design. Bitstream contains
ADRV9002 RX path + Haifuraiya channelizer + AXI-DMA + Takadono control
plane access.

**Steps:**
- Export `.xsa` from the Phase 2a Vivado project
- Place the `.xsa` somewhere accessible to the build
- Use the AMD `gen-machine-conf` tool to generate a machine config from
  the `.xsa`, OR override the existing machine config to point at our
  bitstream + device tree
- Modify the device tree to expose the channelizer at its assigned
  address (the IP-XACT memory map from Phase 1 gives us the
  authoritative offsets)
- Build

**Deliverable:** boot the ZCU102, see the Haifuraiya channelizer in the
device tree, confirm via `cat /proc/device-tree/...` or `ls
/sys/firmware/devicetree/base/...` that it's mounted.

**Optional: consider activating `meta-jupyter` at this point.**
JupyterLab running on the target lets us interactively poke at the
channelizer once it's in the bitstream. Live notebooks for:
- Reading registers and plotting per-channel power as a bar chart
- Time-domain captures + FFT of channel data
- Prototyping spectrum-view widgets before they become Takadono
  production UI

Add via:
```bash
cd ~/yocto/haifuraiya/build
bitbake-layers add-layer ../sources/meta-jupyter
```

Then add `IMAGE_INSTALL:append = " jupyter-lab"` (or equivalent) to
local.conf or a custom image recipe.

**What this proves:** Phase 1's IP-XACT memory map is consumable by the
Linux kernel device tree compiler. Hardware design integrates with
runtime.

### M4: Userspace mmap reads VERSION register = 0x00010000

**Goal:** prove round-trip Linux-to-IP register access works.

**Steps:**
- Boot the M3 image
- From userspace, `mmap` the channelizer's AXI-Lite address window via
  `/dev/mem` (or a UIO driver if we wire one up via meta-ori)
- Read offset 0x00 (VERSION register)
- Expect `0x00010000` (v0.1.0)

**Deliverable:** a one-liner that returns `0x00010000`. Could be C:
```c
fd = open("/dev/mem", O_RDWR | O_SYNC);
void *map = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd,
                 CHANNELIZER_BASE_ADDR);
uint32_t version = *((volatile uint32_t *)map);
printf("0x%08x\n", version);
```

**What this proves:** memory map matches; the IP-XACT register
encoding from Phase 1 is correct end-to-end. Foundational to everything
downstream — every Takadono publish, every diagnostic readback, every
spectrum view depends on this.

### M5: Takadono v0 publishes channelizer state via MQTT

**Goal:** first observability output. Tiny C program reads the
channelizer's registers in a loop, publishes them as MQTT messages.

**Components to build into the image (via `meta-ori`):**
- `mosquitto` MQTT broker (already in meta-oe)
- `mosquitto-clients` (CLI tools for debugging)
- `libpaho-mqtt` (C client library; in meta-oe)
- `takadono_publisher` recipe — our C program

**Topic design:**
```
haifuraiya/channelizer/version          → "0x00010000"
haifuraiya/channelizer/status           → "0x00000001" (ready)
haifuraiya/channelizer/frame_count      → integer counter
haifuraiya/channelizer/dropped_frames   → integer
haifuraiya/channelizer/power/0          → integer (per channel)
haifuraiya/channelizer/power/1          → integer
...
haifuraiya/channelizer/power/63         → integer
```

**Deliverable:** SSH into the ZCU102, run `mosquitto_sub -t
'haifuraiya/#'`, see live register values stream in. From another
host on the same network, subscribe to the same broker — observability
plumbing works.

**What this proves:** Takadono observability foundation. Phase 4b's
HTML/CSS dashboard will subscribe to these same topics. No more
write-once-tweak-everywhere.

**Bonus:** the C source for the publisher can be auto-generated from
`haifuraiya/component.xml` once we write the IP-XACT-to-C generator.
That's a Phase 4-era polish task; for M5 we hand-code 72 register
offsets and call it done.

---

## 🐉 Risks / Watch Points

| Risk | Likelihood | Mitigation |
|---|:-:|---|
| Yocto Kirkstone LTS sunset noise | Medium | Pin commits explicitly; document workarounds inline |
| meta-adi branch naming has drifted | Low | Verify branch after first clone; document the actual branch we used |
| First build fails with cryptic error | High | Yocto failure modes are well-Googled; allocate evening for first build |
| Disk fills up mid-build | Medium | Pre-allocate 100GB+; monitor with `df -h` during build |
| Power loss during 4-hour build | Low | Bitbake resumes; sstate-cache survives |
| `.xsa` from Vivado 2022.2 has format quirks | Low | gen-machine-conf is the tool; well-documented |
| Channelizer's IP-XACT address not auto-imported | Medium | Device tree fragment may need hand-tweak in meta-ori |
| Performance of mmap-based register reads | Low | AXI-Lite is fast enough for telemetry; not a bottleneck |
| First reboot needs serial console to debug | High | Have a USB-UART cable + minicom ready before first boot |

---

## 🎲 Current Concrete Action — M1 launch

Now that the build host is set up, packages installed, repo synced, and
pins captured: **start the first bitbake.**

```bash
cd ~/yocto/haifuraiya
source sources/yocto-scripts/setupsdk
MACHINE=zcu102-zynqmp bitbake petalinux-image-minimal
```

The `setupsdk` step is fast (creates the `build/` tree). The `bitbake`
step is the multi-hour run — leave it going with a free evening or a
Sunday morning.

When it succeeds, the deliverable is at:
```
build/tmp/deploy/images/zcu102-zynqmp/petalinux-image-minimal-zcu102-zynqmp-*.wic
```

Flash to SD with:
```bash
sudo dd if=tmp/deploy/images/zcu102-zynqmp/petalinux-image-minimal-*.wic \
        of=/dev/sdX bs=1M status=progress conv=fsync
```

(Where `/dev/sdX` is the SD card device — **double-check this**, `dd` is
unforgiving.)

---

## 📚 References

### AMD/Xilinx Yocto documentation
- AMD Yocto wiki (recommended workflow):
  https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/2824503297/Building+Linux+Images+Using+Yocto
- Older Xilinx Yocto build doc (for 2022.2 era specifics):
  https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18841862/
- meta-xilinx repository: https://github.com/Xilinx/meta-xilinx
- yocto-manifests (the repo init source):
  https://github.com/Xilinx/yocto-manifests

### ADI documentation
- meta-adi repository: https://github.com/analogdevicesinc/meta-adi
- meta-adi-xilinx README:
  https://github.com/analogdevicesinc/meta-adi/blob/main/meta-adi-xilinx/README.md
- ADI Linux kernel fork: https://github.com/analogdevicesinc/linux
- ADRV9002 ZCU102 quick start:
  https://wiki.analog.com/resources/eval/user-guides/adrv9002

### Yocto Project core docs
- Yocto Project Reference Manual (Kirkstone):
  https://docs.yoctoproject.org/kirkstone/
- Yocto release schedule:
  https://wiki.yoctoproject.org/wiki/Releases

### Community resources
- meta-xilinx mailing list:
  https://lists.yoctoproject.org/g/meta-xilinx
- ADI EngineerZone Linux Software Drivers forum:
  https://ez.analog.com/linux-software-drivers/

---

*Last updated: 2026-05-17, after host setup + repo sync + version pin
capture. Version stack fully locked at xlnx-rel-v2022.2 across all five
required AMD layers. Next action: source setupsdk and start the first
multi-hour bitbake (M1).*
