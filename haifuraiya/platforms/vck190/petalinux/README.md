# VCK190 PetaLinux project notes

`mdt_vck190/` is the PetaLinux 2022.2 project (created by `make vck190-petalinux-create`,
hardware imported by `make vck190-import-xsa`). Tracked: `config.project` and
`project-spec/`; everything else is build product and ignored.

## Settings applied on top of the template (2026-10-24, after the first boot)

Applied with `petalinux-config -c rootfs` / `petalinux-config`, or by editing the
config files directly as noted. Each is a one-line change in a tracked file.

1. **Root login enabled, no password** (the ZCU102 image's behaviour; 2022.2 locks
   root by default and forces a `petalinux` user password change on every boot of
   the RAM-disk image):
   `project-spec/configs/rootfs_config`:
   ```
   CONFIG_YOCTO_ENABLE_DEBUG_TWEAKS=y
   ```
   (`debug-tweaks` = root login with empty password, no forced change.)
2. **Static IPv4 on eth0** (the lab segment gave no DHCP lease at first boot; the
   ZCU102 lives at 10.73.1.16, so this board takes the next address -- change here
   if the lab plan differs):
   `project-spec/configs/systemd-conf/wired.network` (systemd-networkd is the
   template's network manager on Versal):
   ```
   [Match]
   Name=eth0
   [Network]
   Address=10.73.1.17/24
   Gateway=10.73.1.1
   ```
   Confirm `Gateway` against the lab router before building.
3. **dma-proxy** kernel module: Xilinx's userspace DMA example driver, matched to the
   `dma_proxy` node in `system-user.dtsi`. Added as a module recipe under
   `project-spec/meta-user/recipes-modules/dma-proxy/` -- NOT YET DONE; the source
   is Xilinx wiki "Linux DMA from User Space 2.0". Until it exists the node is inert.

## Known: absolute paths

`project-spec/configs/config` carries `/home/abraxas3d/...` paths written by
petalinux-config (hardware description, user layer). A fresh clone elsewhere needs
them rewritten, as the ZCU102's `setup-petalinux.sh` does. Not yet scripted for the
VCK190.
