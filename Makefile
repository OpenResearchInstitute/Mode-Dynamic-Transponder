# Mode-Dynamic-Transponder (MDT) — Top-level Makefile
#
# REQUIRES: Linux. PetaLinux Tools 2022.2 is Linux-only (officially Ubuntu
# 18.04/20.04; works in practice on 22.04 with /bin/sh = /bin/bash). Scripts
# use GNU sed and other Linux-specific tools. Do NOT run on macOS.
#
# Dispatches to subproject builds. The MDT repo contains two separate
# projects that do NOT integrate at the bitstream level:
#
#   haifuraiya/  — Channelizer for the OPV transponder.
#                  Targets ZCU102 + ADRV9002. Builds with Vivado 2022.2 +
#                  ADI hdl_2022_r2 + PetaLinux Tools 2022.2.
#
#   mdt_sic/     — Mode-Dynamic-Transponder SIC receiver.
#                  Targets iCE40 + STM32 (different board, different flow).
#                  Builds with Lattice Radiant + STM32CubeIDE.
#                  TBD: Makefile targets not yet wired up.
#
# Targets here exist only for cross-cutting workflows. Project-specific
# scripts live under each project's own scripts/ directory.

REPO_ROOT := $(shell pwd)
HAIFURAIYA_PROJECT := $(REPO_ROOT)/haifuraiya/petalinux/haifuraiya
HAIFURAIYA_SCRIPTS := $(REPO_ROOT)/haifuraiya/petalinux/scripts
HAIFURAIYA_IMAGES := $(HAIFURAIYA_PROJECT)/images/linux

.PHONY: help haifuraiya-configure haifuraiya-build haifuraiya-boot haifuraiya-clean haifuraiya-revert-paths

help:
	@echo "Mode-Dynamic-Transponder — top-level Makefile"
	@echo
	@echo "Haifuraiya (ZCU102 + ADRV9002 channelizer):"
	@echo "  make haifuraiya-configure     Rewrite User Layer paths for this clone."
	@echo "                                Run this once after 'git clone' and"
	@echo "                                after every petalinux-config edit."
	@echo "  make haifuraiya-build         Configure + petalinux-build + package."
	@echo "  make haifuraiya-boot          Configure + JTAG boot to login (TBD;"
	@echo "                                currently prints the manual recipe)."
	@echo "  make haifuraiya-clean         Wipe build/ and images/ for a fresh start."
	@echo "  make haifuraiya-revert-paths  Reset User Layer paths to sentinel form."
	@echo "                                Run before 'git commit' if you've ever"
	@echo "                                run haifuraiya-configure."
	@echo
	@echo "MDT-SIC (iCE40 + STM32 SIC receiver):"
	@echo "  Targets not wired up. See mdt_sic/README.md for the Radiant +"
	@echo "  STM32CubeIDE workflow. (MDT-SIC and Haifuraiya are independent"
	@echo "  projects; they do not share a bitstream.)"

# ---------------------------------------------------------------------------
# Haifuraiya targets
# ---------------------------------------------------------------------------

haifuraiya-configure:
	@$(HAIFURAIYA_SCRIPTS)/setup-petalinux.sh

haifuraiya-build: haifuraiya-configure
	cd $(HAIFURAIYA_PROJECT) && petalinux-build
	cd $(HAIFURAIYA_PROJECT) && petalinux-package --boot --fsbl --fpga --u-boot --force
	cd $(HAIFURAIYA_PROJECT) && petalinux-package --prebuilt --force
	@echo
	@echo "==> Build complete."
	@echo
	@echo "==> Build artifacts (for SD card boot — write to FAT32 partition):"
	@echo "      $(HAIFURAIYA_IMAGES)/BOOT.BIN     (FSBL+PMUFW+bitstream+ATF+U-Boot)"
	@echo "      $(HAIFURAIYA_IMAGES)/image.ub     (kernel+DTB+initramfs FIT image)"
	@echo
	@echo "==> Prebuilt directory (populated for petalinux-boot --jtag --prebuilt):"
	@echo "      $(HAIFURAIYA_PROJECT)/pre-built/linux/images/"
	@echo
	@echo "==> Next step:"
	@echo "      make haifuraiya-boot     # JTAG boot via keroppi"

haifuraiya-boot: haifuraiya-configure
	@echo "==> JTAG boot script not yet automated (TBD)."
	@echo
	@echo "    Manual recipe for now:"
	@echo
	@echo "    cd $(HAIFURAIYA_PROJECT)"
	@echo "    petalinux-boot --jtag --prebuilt 3 \\"
	@echo "        --hw_server-url TCP:keroppi:3121 \\"
	@echo "        --after-connect 'targets 1' \\"
	@echo "        --tcl /tmp/boot.tcl"
	@echo
	@echo "    Edit /tmp/boot.tcl to insert two reset commands:"
	@echo "      (a) After 'connect -url ...':"
	@echo "            targets -set -nocase -filter {name =~ \"*PSU*\"}"
	@echo "            rst -system"
	@echo "            after 1000"
	@echo "      (b) Between 'psu_ps_pl_reset_config' and 'dow u-boot.elf':"
	@echo "            rst -processor -clear-registers"
	@echo
	@echo "    Then run:"
	@echo "      xsdb /tmp/boot.tcl"
	@echo
	@echo "    Monitor serial console concurrently (on keroppi):"
	@echo "      screen /dev/zcu102_uart1 115200"
	@echo
	@echo "==> See haifuraiya/haifuraiya_plan_of_attack.md (PetaLinux Build Lessons)"
	@echo "    for full context on why these two edits are required."

haifuraiya-clean:
	@echo "==> Wiping Haifuraiya build artifacts (preserving project-spec/)..."
	rm -rf $(HAIFURAIYA_PROJECT)/build
	rm -rf $(HAIFURAIYA_PROJECT)/images
	rm -rf $(HAIFURAIYA_PROJECT)/pre-built
	@echo "==> Clean. Run 'make haifuraiya-build' to rebuild from sources."

haifuraiya-revert-paths:
	@echo "==> Reverting absolute paths to sentinel form..."
	@sed -i \
	    -e 's|^CONFIG_USER_LAYER_0=.*|CONFIG_USER_LAYER_0="/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-adi-core"|' \
	    -e 's|^CONFIG_USER_LAYER_1=.*|CONFIG_USER_LAYER_1="/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-adi-xilinx"|' \
	    $(HAIFURAIYA_PROJECT)/project-spec/configs/config
	@sed -i \
	    -e 's|^HARDWARE_PATH=.*|HARDWARE_PATH=/PLEASE_RUN_make_haifuraiya-configure_FIRST/system_top.xsa|' \
	    $(HAIFURAIYA_PROJECT)/.petalinux/metadata
	@echo "==> Done. Current state:"
	@echo "    In project-spec/configs/config:"
	@grep "^CONFIG_USER_LAYER_[01]=" $(HAIFURAIYA_PROJECT)/project-spec/configs/config | sed 's/^/      /'
	@echo "    In .petalinux/metadata:"
	@grep "^HARDWARE_PATH=" $(HAIFURAIYA_PROJECT)/.petalinux/metadata | sed 's/^/      /'
	@echo
	@echo "    Safe to 'git commit' the config and metadata now."
	@echo "    Re-run 'make haifuraiya-configure' before next build."
