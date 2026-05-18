# meta-ori — Open Research Institute Yocto Layer

Custom Yocto layer providing project-specific configuration and tooling
for ORI's Haifuraiya channelizer running on the ZCU102 platform.

## Purpose

This layer adds ORI-specific recipes, image customizations, and device
tree fragments on top of the AMD/Xilinx Yocto stack. It is **scoped to
the Haifuraiya channelizer project**; other ORI projects (e.g., MDT-SIC,
which runs on different hardware) have their own Yocto trees.

## Layer dependencies

- core (oe-core)
- openembedded-layer (meta-openembedded/meta-oe)
- meta-petalinux

This layer is intended to be activated AFTER meta-petalinux in
`bblayers.conf` so its overrides apply on top of the petalinux distro
defaults.

## Compatibility

Currently tested with:
- Yocto release: Kirkstone (4.0)
- Vivado: 2022.2
- meta-xilinx tagged xlnx-rel-v2022.2

## Layout

```
meta-ori/
├── conf/
│   └── layer.conf                     # bitbake layer registration
├── COPYING.MIT                         # license
├── README.md                           # this file
├── recipes-core/                       # image customizations
│   └── systemd/                        # static IP via systemd-networkd
│       ├── systemd_%.bbappend          # extends systemd recipe
│       └── systemd/
│           └── 10-eth0.network         # static IP config file
├── recipes-takadono/                   # (planned) M5: MQTT telemetry publisher
└── recipes-haifuraiya/                 # (planned) M3: channelizer DT fragments
```

## How to activate

```bash
cd ~/yocto/haifuraiya
ln -s ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/meta-ori sources/

cd build
bitbake-layers add-layer ../sources/meta-ori
bitbake-layers show-layers   # verify meta-ori appears
```

## Current contents

### `recipes-core/systemd/`

Adds `/etc/systemd/network/10-eth0.network` to the rootfs, configuring
the on-board gigabit Ethernet (eth0) with a static IP address suitable
for the ORI remote lab. Address `10.73.1.16/24`, gateway `10.73.1.1`.

If you're deploying outside the ORI lab, edit `10-eth0.network` to
match your network. Otherwise eth0 will come up with the lab IP regardless
of where the board is physically located.

## Planned additions (not yet implemented)

- `recipes-haifuraiya/` — channelizer-specific device tree fragments
  added when integrating Phase 2a's `.xsa` (Vivado export). Defines the
  channelizer register block, DMA, IRQs.
- `recipes-takadono/` — Takadono v0 MQTT telemetry publisher; reads
  channelizer status registers via mmap, publishes via paho-mqtt.

## License

MIT. See COPYING.MIT.
