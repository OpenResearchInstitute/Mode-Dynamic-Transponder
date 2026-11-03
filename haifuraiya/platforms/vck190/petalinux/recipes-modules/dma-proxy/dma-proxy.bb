SUMMARY = "Xilinx dma-proxy: userspace access to AXI DMA channels through dmaengine"
DESCRIPTION = "Xilinx's 'Linux DMA From User Space 2.0' example driver (Xilinx-Wiki-Projects/software-prototypes, \
linux-user-space-dma), vendored with BUFFER_SIZE raised to 4 MB for the VCK190 memory loopback. \
Exposes /dev/dma_proxy_tx and /dev/dma_proxy_rx for the dma_proxy node in system-user.dtsi; \
opv_play (dogu/tools) is the client."
SECTION = "PETALINUX/modules"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57"

inherit module

INHIBIT_PACKAGE_STRIP = "1"

# Load at boot (writes /etc/modules-load.d/dma-proxy.conf). Without this the
# module is in the image but /dev/dma_proxy_* only appear after a manual
# `modprobe dma_proxy` (first VCK190 boot, 2026-10-24).
KERNEL_MODULE_AUTOLOAD += "dma-proxy"

SRC_URI = "file://Makefile \
           file://dma-proxy.c \
           file://dma-proxy.h \
           file://LICENSE \
          "

S = "${WORKDIR}"

# The inherit of module.bbclass will automatically name module packages with
# "kernel-module-" prefix as required by the oe-core build environment.
