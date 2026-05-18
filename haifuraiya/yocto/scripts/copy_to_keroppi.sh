#!/bin/bash
# copy_to_keroppi.sh
#
# Copy Yocto-built artifacts from mymelody (build host) to keroppi (lab VM
# connected to ZCU102). Splits artifacts into two destinations:
#   - JTAG-load files → /tmp/abraxas3d-yocto-boot/ on keroppi
#   - TFTP-served files → /tftpboot/abraxas3d-yocto/ on keroppi
#
# Assumes:
#   - SSH key-based access to abraxas3d@keroppi works (no password prompts)
#   - You're a member of the 'tftp' group on keroppi (per lab doc)
#   - Run from anywhere on mymelody; uses absolute paths
#
# Usage:
#   ./copy_to_keroppi.sh

set -euo pipefail

# --- Source paths on mymelody ---
DEPLOY_DIR="$HOME/yocto/haifuraiya/build/tmp/deploy/images/zcu102-zynqmp"

# --- Destination on keroppi ---
KEROPPI_USER="abraxas3d"
KEROPPI_HOST="keroppi"
JTAG_DIR="/tmp/abraxas3d-yocto-boot"
TFTP_DIR="/tftpboot/abraxas3d-yocto"

echo "=== Creating destination directories on keroppi ==="
ssh ${KEROPPI_USER}@${KEROPPI_HOST} "
    mkdir -p ${JTAG_DIR}
    mkdir -p ${TFTP_DIR}
    chmod 755 ${JTAG_DIR} ${TFTP_DIR}
"

echo ""
echo "=== Copying JTAG-load files (FSBL/PMU/ATF/U-Boot) ==="
# These are loaded into RAM via xsdb during JTAG boot
scp ${DEPLOY_DIR}/fsbl-zcu102-zynqmp.elf \
    ${DEPLOY_DIR}/pmu-firmware-zcu102-zynqmp.elf \
    ${DEPLOY_DIR}/arm-trusted-firmware.bin \
    ${DEPLOY_DIR}/u-boot.elf \
    ${KEROPPI_USER}@${KEROPPI_HOST}:${JTAG_DIR}/

echo ""
echo "=== Copying TFTP-served files (kernel/dtb/initramfs) ==="
# These are fetched by U-Boot from the TFTP server (keroppi) into RAM
scp ${DEPLOY_DIR}/Image \
    ${DEPLOY_DIR}/zynqmp-zcu102-rev1.0.dtb \
    ${DEPLOY_DIR}/petalinux-image-minimal-zcu102-zynqmp.cpio.gz.u-boot \
    ${KEROPPI_USER}@${KEROPPI_HOST}:${TFTP_DIR}/

# Rename the rootfs symlink target to a shorter TFTP-friendly name
echo ""
echo "=== Creating short-name symlinks on keroppi (TFTP-friendly) ==="
ssh ${KEROPPI_USER}@${KEROPPI_HOST} "
    cd ${TFTP_DIR}
    ln -sf petalinux-image-minimal-zcu102-zynqmp.cpio.gz.u-boot initramfs.cpio.gz.u-boot
    ln -sf zynqmp-zcu102-rev1.0.dtb system.dtb
    ls -la
"

echo ""
echo "=== Copy complete ==="
echo "JTAG-load files in:  keroppi:${JTAG_DIR}"
echo "TFTP-served files:   keroppi:${TFTP_DIR}"
echo ""
echo "Next: ssh to keroppi and run zcu102_jtag_boot.tcl"
