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

# ADI HDL reference design — produces the XSA via 'make' in Vivado batch mode.
HAIFURAIYA_ADI_HDL := $(REPO_ROOT)/haifuraiya/third_party/hdl
HAIFURAIYA_XSA_PROJECT := $(HAIFURAIYA_ADI_HDL)/projects/adrv9001/zcu102
HAIFURAIYA_XSA := $(HAIFURAIYA_XSA_PROJECT)/adrv9001_zcu102.sdk/system_top.xsa

# Integrated build (Build 12 style — ADI baseline + Haifuraiya channelizer splice).
# This is what produces the bitstream actually deployed on real hardware. See
# haifuraiya/syn/zcu102_with_adrv9001/README.md for the architecture rationale.
HAIFURAIYA_INTEGRATED_DIR := $(REPO_ROOT)/haifuraiya/syn/zcu102_with_adrv9001
HAIFURAIYA_INTEGRATED_XSA := $(HAIFURAIYA_INTEGRATED_DIR)/adrv9001_zcu102_ori.sdk/system_top.xsa
HAIFURAIYA_HW_DESC := $(HAIFURAIYA_PROJECT)/project-spec/hw-description

.PHONY: help haifuraiya-configure haifuraiya-build haifuraiya-boot haifuraiya-clean haifuraiya-revert-paths haifuraiya-check-env haifuraiya-check-vivado haifuraiya-xsa haifuraiya-import-xsa haifuraiya-adi-lib haifuraiya-xsa-integrated haifuraiya-import-xsa-integrated haifuraiya-check-xsa haifuraiya-update

help:
	@echo "Mode-Dynamic-Transponder — top-level Makefile"
	@echo
	@echo "Haifuraiya (ZCU102 + ADRV9002 channelizer):"
	@echo "  make haifuraiya-configure     Rewrite User Layer paths for this clone."
	@echo "                                Run this once after 'git clone' and"
	@echo "                                after every petalinux-config edit."
	@echo "  make haifuraiya-build         Configure + petalinux-build + package."
	@echo "  make haifuraiya-boot          Boot ZCU102 via JTAG over keroppi"
	@echo "                                (petalinux-boot --jtag --prebuilt 3)."
	@echo "                                PREREQUISITE: power-cycle the board first.
	@echo "  make haifuraiya-clean         Wipe build/ and images/ for a fresh start."
	@echo "  make haifuraiya-revert-paths  Reset User Layer paths to sentinel form."
	@echo "                                Run before 'git commit' if you've ever"
	@echo "                                run haifuraiya-configure."
	@echo "  make haifuraiya-check-env     Verify that PetaLinux Tools is sourced"
	@echo "                                and 'petalinux-build' is on PATH."
	@echo "  make haifuraiya-update        Safely sync with origin/main after running"
	@echo "                                haifuraiya-configure (revert working tree,"
	@echo "                                git pull, re-configure for local clone)."
	@echo
	@echo "Hardware regeneration (only when RTL/IP-XACT/block-design changes):"
	@echo "  make haifuraiya-check-vivado  Verify that Vivado 2022.2 is sourced."
	@echo "  make haifuraiya-xsa           Vivado batch build of the adrv9001/zcu102"
	@echo "                                reference design. ~5 hours. Produces"
	@echo "                                system_top.xsa under the hdl submodule."
	@echo "  make haifuraiya-import-xsa    Re-import the freshly-built XSA into the"
	@echo "                                PetaLinux project. Updates hw-description"
	@echo "                                cache and HARDWARE_CHECKSUM. Run BEFORE"
	@echo "                                'make haifuraiya-build' if you've rebuilt"
	@echo "                                the XSA."
	@echo
	@echo "Integrated hardware regeneration (produces the deployed bitstream):"
	@echo "  make haifuraiya-xsa-integrated"
	@echo "                                Vivado batch build of the integrated"
	@echo "                                design (ADI baseline + channelizer splice)."
	@echo "                                Produces system_top.xsa under"
	@echo "                                haifuraiya/syn/zcu102_with_adrv9001/."
	@echo "  make haifuraiya-import-xsa-integrated"
	@echo "                                Re-import the integrated XSA into the"
	@echo "                                PetaLinux project. Auto-renames the"
	@echo "                                bad-timing bit. Auto-runs haifuraiya-check-xsa."
	@echo "  make haifuraiya-check-xsa     Sanity-check that the imported XSA contains"
	@echo "                                the channelizer at 0x84A70000. Catches the"
	@echo "                                'fresh clone imported wrong XSA' failure mode."
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

haifuraiya-check-env:
	@command -v petalinux-build >/dev/null 2>&1 || { \
	    echo "ERROR: 'petalinux-build' is not on PATH."; \
	    echo ""; \
	    echo "       PetaLinux Tools 2022.2 must be installed AND its environment"; \
	    echo "       must be sourced in your current shell."; \
	    echo ""; \
	    echo "       If PetaLinux is installed at ~/petalinux/2022.2/, run:"; \
	    echo "         source ~/petalinux/2022.2/settings.sh"; \
	    echo ""; \
	    echo "       Then retry 'make haifuraiya-build'."; \
	    echo ""; \
	    echo "       If PetaLinux is not installed, see"; \
	    echo "       haifuraiya/haifuraiya_plan_of_attack.md (PetaLinux Build"; \
	    echo "       Lessons → Workflow recipe) for installation instructions."; \
	    exit 1; \
	}
	@echo "==> PetaLinux Tools detected on PATH: $$(command -v petalinux-build)"

haifuraiya-build: haifuraiya-check-env haifuraiya-configure haifuraiya-check-xsa
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

haifuraiya-boot:
	@echo "==> Booting ZCU102 via JTAG over keroppi."
	@echo "    PREREQUISITE: power-cycle the ZCU102 before running this."
	@echo "    (PetaLinux's generated boot.tcl assumes a freshly-reset board.)"
	@echo ""
	@echo "    Monitor serial console concurrently (on keroppi):"
	@echo "      ssh keroppi 'screen /dev/zcu102_uart1 115200'"
	@echo ""
	cd $(HAIFURAIYA_PROJECT) && \
	petalinux-boot --jtag --prebuilt 3 \
	    --hw_server-url TCP:keroppi:3121 \
	    --after-connect 'targets 1'

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
            -e 's|^CONFIG_USER_LAYER_2=.*|CONFIG_USER_LAYER_2="/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-ori"|' \
	    $(HAIFURAIYA_PROJECT)/project-spec/configs/config
	@sed -i \
	    -e 's|^HARDWARE_PATH=.*|HARDWARE_PATH=/PLEASE_RUN_make_haifuraiya-configure_FIRST/system_top.xsa|' \
	    $(HAIFURAIYA_PROJECT)/.petalinux/metadata
	@echo "==> Done. Current state:"
	@echo "    In project-spec/configs/config:"
	@grep "^CONFIG_USER_LAYER_[012]=" $(HAIFURAIYA_PROJECT)/project-spec/configs/config | sed 's/^/      /'
	@echo "    In .petalinux/metadata:"
	@grep "^HARDWARE_PATH=" $(HAIFURAIYA_PROJECT)/.petalinux/metadata | sed 's/^/      /'
	@echo
	@echo "    Safe to 'git commit' the config and metadata now."
	@echo "    Re-run 'make haifuraiya-configure' before next build."

haifuraiya-update:
	@echo "==> Safely syncing with origin (revert -> pull -> reconfigure)..."
	@echo
	@echo "==> Step 1/3: Reverting working tree paths to sentinel form so 'git pull' is clean..."
	@$(MAKE) --no-print-directory haifuraiya-revert-paths
	@echo
	@echo "==> Step 2/3: Pulling latest from origin..."
	@git pull
	@echo
	@echo "==> Step 3/3: Re-applying local clone paths via setup-petalinux.sh..."
	@$(MAKE) --no-print-directory haifuraiya-configure
	@echo
	@echo "==> Done. Working tree is up to date with origin AND configured for"
	@echo "    your local clone. Ready to 'make haifuraiya-build'."
	@echo
	@echo "    Note: if 'git pull' reported any conflicts above (in files OTHER"
	@echo "    than config/metadata), those are unrelated local edits you have."
	@echo "    Resolve them manually before re-running haifuraiya-update."

# ---------------------------------------------------------------------------
# Vivado / XSA targets (only used when RTL or block-design changes)
# ---------------------------------------------------------------------------

haifuraiya-check-vivado:
	@command -v vivado >/dev/null 2>&1 || { \
	    echo "ERROR: 'vivado' is not on PATH."; \
	    echo ""; \
	    echo "       Vivado 2022.2 must be installed AND its environment must"; \
	    echo "       be sourced in your current shell."; \
	    echo ""; \
	    echo "       If Vivado is installed at /tools/Xilinx/Vivado/2022.2/, run:"; \
	    echo "         source /tools/Xilinx/Vivado/2022.2/settings64.sh"; \
	    echo ""; \
	    echo "       Then retry your make target."; \
	    echo ""; \
	    echo "       Note: Vivado is ONLY needed when rebuilding the XSA"; \
	    echo "       (e.g., after modifying RTL, IP-XACT, or the block design)."; \
	    echo "       'make haifuraiya-build' does NOT require Vivado — the"; \
	    echo "       cached hardware description is already in the repo."; \
	    exit 1; \
	}
	@echo "==> Vivado detected on PATH: $$(command -v vivado)"

haifuraiya-xsa: haifuraiya-check-vivado
	@echo "==> Building Vivado XSA for adrv9001/zcu102 reference design..."
	@echo "    Source:   $(HAIFURAIYA_XSA_PROJECT)"
	@echo "    Output:   $(HAIFURAIYA_XSA)"
	@echo "    Expected duration: ~5 hours (Vivado batch synthesis + impl)."
	@echo
	cd $(HAIFURAIYA_XSA_PROJECT) && $(MAKE)
	@test -f $(HAIFURAIYA_XSA) || { \
	    echo ""; \
	    echo "ERROR: XSA was not produced at expected path:"; \
	    echo "         $(HAIFURAIYA_XSA)"; \
	    echo "       Check the Vivado batch log for synthesis/implementation"; \
	    echo "       errors. Look in $(HAIFURAIYA_XSA_PROJECT) for *.log files."; \
	    exit 1; \
	}
	@echo
	@echo "==> XSA built successfully."
	@echo "    Path: $(HAIFURAIYA_XSA)"
	@echo
	@echo "==> Next step: run 'make haifuraiya-import-xsa' to update the"
	@echo "    PetaLinux project's hardware description and checksum."

haifuraiya-import-xsa: haifuraiya-check-env
	@test -f $(HAIFURAIYA_XSA) || { \
	    echo "ERROR: XSA not found at expected path:"; \
	    echo "         $(HAIFURAIYA_XSA)"; \
	    echo "       Run 'make haifuraiya-xsa' first to build the XSA."; \
	    exit 1; \
	}
	@echo "==> Re-importing XSA into PetaLinux project..."
	@echo "    XSA:     $(HAIFURAIYA_XSA)"
	@echo "    Project: $(HAIFURAIYA_PROJECT)"
	@echo
	cd $(HAIFURAIYA_PROJECT) && petalinux-config --silentconfig --get-hw-description=$(HAIFURAIYA_XSA)
	@echo
	@echo "==> XSA imported successfully."
	@echo "    Updated: $(HAIFURAIYA_PROJECT)/project-spec/hw-description/"
	@echo "    Updated: $(HAIFURAIYA_PROJECT)/.petalinux/metadata (HARDWARE_CHECKSUM)"
	@echo
	@echo "==> Next step: run 'make haifuraiya-build' to rebuild the PetaLinux"
	@echo "    image against the new hardware description."

# ---------------------------------------------------------------------------
# Integrated Vivado / XSA targets — ADI baseline + Haifuraiya channelizer splice.
# This is the canonical hardware build (the deployed bitstream). The plain
# 'haifuraiya-xsa' target above builds only the ADI baseline reference design
# without our channelizer, which is useful for diagnostics but is NOT what
# boots on real hardware. See haifuraiya/syn/zcu102_with_adrv9001/README.md.
# ---------------------------------------------------------------------------

# ADI HDL library IP that the adrv9001/zcu102 design depends on. This list
# mirrors LIB_DEPS in third_party/hdl/projects/adrv9001/zcu102/Makefile.
# These IP must be packaged into the Vivado IP catalog BEFORE the integrated
# block-design build can instantiate them — otherwise system_bd.tcl fails with
# "No Catalog IPs found / Please specify VLNV" on the first ad_ip_instance
# (e.g. axi_sysid). ADI's own project Makefile builds these automatically;
# our integrated build sources system_project.tcl via vivado directly, so it
# must build them itself. Each IP's Makefile builds its own sub-dependencies
# recursively and no-ops if already current, so this is cheap on rebuilds.
HAIFURAIYA_ADI_LIB_DEPS := \
	axi_adrv9001 \
	axi_dmac \
	axi_sysid \
	sysid_rom \
	util_pack/util_cpack2 \
	util_pack/util_upack2

haifuraiya-adi-lib: haifuraiya-check-vivado
	@echo "==> Building ADI HDL library IP (one-time; no-ops if already current)..."
	@for dep in $(HAIFURAIYA_ADI_LIB_DEPS); do \
	    echo "    -> $$dep"; \
	    $(MAKE) -C $(HAIFURAIYA_ADI_HDL)/library/$$dep || { \
	        echo "ERROR: failed to build ADI library IP '$$dep'"; \
	        exit 1; \
	    }; \
	done
	@echo "==> ADI library IP ready in the catalog."

haifuraiya-xsa-integrated: haifuraiya-check-vivado haifuraiya-adi-lib
	@echo "==> Building integrated Vivado XSA (ADI baseline + channelizer splice)..."
	@echo "    Source:   $(HAIFURAIYA_INTEGRATED_DIR)"
	@echo "    Output:   $(HAIFURAIYA_INTEGRATED_XSA)"
	@echo "    Expected duration: Vivado batch synth + impl."
	@echo
	cd $(HAIFURAIYA_INTEGRATED_DIR) && vivado -mode batch -source system_project.tcl
	@test -f $(HAIFURAIYA_INTEGRATED_XSA) || { \
	    echo ""; \
	    echo "ERROR: integrated XSA was not produced at:"; \
	    echo "         $(HAIFURAIYA_INTEGRATED_XSA)"; \
	    echo "       Check the Vivado batch log:"; \
	    echo "         $(HAIFURAIYA_INTEGRATED_DIR)/vivado.log"; \
	    exit 1; \
	}
	@echo
	@echo "==> Integrated XSA built successfully."
	@echo "    Path: $(HAIFURAIYA_INTEGRATED_XSA)"
	@echo
	@echo "==> Next step: run 'make haifuraiya-import-xsa-integrated' to update"
	@echo "    the PetaLinux project's hardware description."

haifuraiya-import-xsa-integrated: haifuraiya-check-env
	@test -f $(HAIFURAIYA_INTEGRATED_XSA) || { \
	    echo "ERROR: integrated XSA not found at:"; \
	    echo "         $(HAIFURAIYA_INTEGRATED_XSA)"; \
	    echo "       Run 'make haifuraiya-xsa-integrated' first."; \
	    exit 1; \
	}
	@echo "==> Re-importing integrated XSA into PetaLinux project..."
	@echo "    XSA:     $(HAIFURAIYA_INTEGRATED_XSA)"
	@echo "    Project: $(HAIFURAIYA_PROJECT)"
	@echo
	cd $(HAIFURAIYA_PROJECT) && petalinux-config --silentconfig --get-hw-description=$(HAIFURAIYA_INTEGRATED_XSA)
	@$(MAKE) --no-print-directory haifuraiya-check-xsa
	@echo
	@echo "==> Integrated XSA imported successfully."
	@echo "    Updated: $(HAIFURAIYA_HW_DESC)/"
	@echo "    Updated: $(HAIFURAIYA_PROJECT)/.petalinux/metadata (HARDWARE_CHECKSUM)"
	@echo
	@echo "==> Next step: run 'make haifuraiya-build' to rebuild the PetaLinux"
	@echo "    image against the new hardware description."

# Sanity gate: fail with a clear message if the imported XSA doesn't contain
# the channelizer at 0x84A70000. Catches the failure mode where the ADI
# baseline XSA got imported by mistake (what bit Phase 3 bring-up in green/).
# Safe to run anytime; invoked automatically by haifuraiya-import-xsa-integrated.
haifuraiya-check-xsa:
	@test -f $(HAIFURAIYA_HW_DESC)/system.xsa || { \
	    echo "ERROR: no XSA found at $(HAIFURAIYA_HW_DESC)/system.xsa"; \
	    echo "       Did 'make haifuraiya-import-xsa-integrated' run?"; \
	    exit 1; \
	}
	@unzip -p $(HAIFURAIYA_HW_DESC)/system.xsa '*.hwh' 2>/dev/null \
	    | grep -qiE '0x84A70000|84a70000' || { \
	    echo ""; \
	    echo "ERROR: imported XSA lacks channelizer at 0x84A70000."; \
	    echo ""; \
	    echo "       The XSA in:"; \
	    echo "         $(HAIFURAIYA_HW_DESC)/system.xsa"; \
	    echo ""; \
	    echo "       does not contain the Haifuraiya channelizer IP. This usually"; \
	    echo "       means the ADI baseline XSA was imported instead of the"; \
	    echo "       integrated Build 12 XSA."; \
	    echo ""; \
	    echo "       To fix:"; \
	    echo "         make haifuraiya-xsa-integrated"; \
	    echo "         make haifuraiya-import-xsa-integrated"; \
	    echo "         make haifuraiya-build"; \
	    echo ""; \
	    echo "       Or if you have a pre-built integrated XSA elsewhere, point"; \
	    echo "       petalinux-config at it directly:"; \
	    echo "         cd $(HAIFURAIYA_PROJECT) && \\"; \
	    echo "             petalinux-config --silentconfig --get-hw-description=<path>"; \
	    exit 1; \
	}
	@echo "==> Imported XSA contains channelizer at 0x84A70000. OK."
