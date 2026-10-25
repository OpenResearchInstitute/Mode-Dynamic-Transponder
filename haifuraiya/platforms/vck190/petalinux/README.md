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
   `project-spec/configs/rootfs_config` (the symbol is 2022.2's; it sits near
   the end of the file as a `# ... is not set` line -- flip it, don't append):
   ```
   sed -i 's/^# CONFIG_imagefeature-debug-tweaks is not set/CONFIG_imagefeature-debug-tweaks=y/' mdt_vck190/project-spec/configs/rootfs_config
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
3. **dma-proxy** kernel module: Xilinx's userspace DMA example driver (Apache-2.0,
   vendored from Xilinx-Wiki-Projects/software-prototypes with BUFFER_SIZE raised to
   4 MB), matched to the `dma_proxy` node in `system-user.dtsi`. The recipe lives in
   this directory as `recipes-modules/dma-proxy/`; to add it to the image:
   ```
   cp -r recipes-modules mdt_vck190/project-spec/meta-user/
   echo 'CONFIG_dma-proxy' >> mdt_vck190/project-spec/meta-user/conf/user-rootfsconfig
   echo 'CONFIG_dma-proxy=y' >> mdt_vck190/project-spec/configs/rootfs_config
   ```
   then `make vck190-build`. The module needs 2 x 32 x 4 MB of coherent memory, so
   `system-user.dtsi` now carries `cma=512M` in bootargs (re-copy it with
   `make vck190-import-xsa`, or by hand to
   `project-spec/meta-user/recipes-bsp/device-tree/files/`). On the board:
   `ls /dev/dma_proxy_*` -> `dma_proxy_rx dma_proxy_tx`; `dmesg | grep dma_proxy`.
4. **opv_play** (dogu/tools/opv_play): the memory-loopback client -- registers via
   `/dev/uio0`, stimulus through `/dev/dma_proxy_tx`, soft bits from
   `/dev/dma_proxy_rx`. Host-side converters in `../tools/`.

## Known: absolute paths

`project-spec/configs/config` carries `/home/abraxas3d/...` paths written by
petalinux-config (hardware description, user layer). A fresh clone elsewhere needs
them rewritten, as the ZCU102's `setup-petalinux.sh` does. Not yet scripted for the
VCK190.
