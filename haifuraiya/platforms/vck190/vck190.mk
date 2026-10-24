# vck190.mk -- VCK190 memory-loopback build targets (included by the top-level
# Makefile with one line: `include haifuraiya/platforms/vck190/vck190.mk`).
#
# Mirrors the ZCU102 flow's shape -- Vivado batch -> XSA -> PetaLinux import ->
# petalinux-build -> package -> JTAG boot -- for the VCK190 memory-loopback
# platform (see VCK190_PLAYBACK_PLAN.md).  Nothing here touches the ZCU102
# targets or paths.  REQUIRES: Linux, Vivado 2022.2 (Enterprise: the
# XCVC1902 is not in the free edition's device list -- Vivado itself is
# the authority on that), PetaLinux Tools 2022.2.
#
# Typical first bring-up, in order:
#   make vck190-xsa                 Vivado batch: project, BD, synth, impl, XSA (hours)
#   make vck190-petalinux-create    once: petalinux-create -t project --template versal
#   make vck190-import-xsa          petalinux-config --get-hw-description
#   make vck190-build               petalinux-build + package (BOOT.BIN, image.ub, boot.scr)
#   make vck190-boot                petalinux-boot --jtag --prebuilt 3
#
# STATUS 2026-10-23: written alongside the (not yet run) Vivado scripts; the
# PetaLinux steps follow the 2022.2 Versal flow and have not been exercised
# on chococat yet.

VCK190_DIR        := $(REPO_ROOT)/haifuraiya/platforms/vck190
VCK190_SYN        := $(VCK190_DIR)/syn
VCK190_XSA        := $(VCK190_SYN)/mdt_vck190_playback.xsa
VCK190_PL_NAME    := mdt_vck190
VCK190_PL_DIR     := $(VCK190_DIR)/petalinux
VCK190_PL_PROJECT := $(VCK190_PL_DIR)/$(VCK190_PL_NAME)
VCK190_PL_IMAGES  := $(VCK190_PL_PROJECT)/images/linux
VCK190_HW_DESC    := $(VCK190_PL_PROJECT)/project-spec/hw-description
VCK190_USER_DTSI  := $(VCK190_DIR)/petalinux/system-user.dtsi
# the receiver's control registers in the BD (vck190_playback_bd.tcl, section 6)
VCK190_RX_CTRL_ADDR := A4010000

.PHONY: vck190-help vck190-license-up vck190-license-down vck190-check-license vck190-check-vivado vck190-check-env vck190-xsa vck190-project \
        vck190-petalinux-create vck190-import-xsa vck190-check-xsa vck190-build \
        vck190-boot vck190-clean

vck190-help:
	@echo "VCK190 memory-loopback targets:"
	@echo "  make vck190-license-up        ssh tunnel to the ORI FlexLM server; then export XILINXD_LICENSE_FILE=2100@127.0.0.1 in your shell."
	@echo "  make vck190-license-down      drop the tunnel."
	@echo "  make vck190-project           Vivado batch: project + block design + wrapper only (fast; validates the BD)."
	@echo "  make vck190-xsa               ... plus synth/impl/device image -> $(notdir $(VCK190_XSA)), timing + utilization reports."
	@echo "  make vck190-petalinux-create  One-time: create the PetaLinux 2022.2 Versal project under platforms/vck190/petalinux/."
	@echo "  make vck190-import-xsa        Import the XSA into the PetaLinux project (+ apply system-user.dtsi)."
	@echo "  make vck190-check-xsa         Verify the imported XSA carries the receiver at 0x$(VCK190_RX_CTRL_ADDR)."
	@echo "  make vck190-build             petalinux-build + package (BOOT.BIN/PDI, image.ub, boot.scr, prebuilt)."
	@echo "  make vck190-boot              petalinux-boot --jtag --prebuilt 3 (hw_server must be reachable)."
	@echo "  make vck190-clean             Remove the Vivado project directory and reports (keeps the XSA)."

# Paul's Remote Lab license flow: an ssh tunnel to the ORI FlexLM server
# (local 2100/2101 -> server 2100/2101) and XILINXD_LICENSE_FILE=2100@127.0.0.1.
# The project/BD step needs no license; synthesis of the XCVC1902 does.
VCK190_LIC_HOST := abraxas3d@flexlm-server.openresearch.institute

vck190-license-up:
	@lsof -t -i :2100 >/dev/null 2>&1 && echo "==> license tunnel already up" || \
	    ssh -f -N -L 2100:127.0.0.1:2100 -L 2101:127.0.0.1:2101 $(VCK190_LIC_HOST)
	@echo "==> now, in THIS shell (make cannot export into it):"
	@echo "    export XILINXD_LICENSE_FILE=2100@127.0.0.1"

vck190-license-down:
	-kill -HUP `lsof -t -i :2100` 2>/dev/null
	@lsof -i :2100 || echo "==> license tunnel down"

vck190-check-license:
	@lsof -t -i :2100 >/dev/null 2>&1 || { \
	    echo "ERROR: no license tunnel on port 2100 -- run 'make vck190-license-up'"; exit 1; }
	@test "$$XILINXD_LICENSE_FILE" = "2100@127.0.0.1" || { \
	    echo "ERROR: XILINXD_LICENSE_FILE is '$$XILINXD_LICENSE_FILE', expected 2100@127.0.0.1"; \
	    echo "       export XILINXD_LICENSE_FILE=2100@127.0.0.1"; exit 1; }
	@echo "==> license tunnel up, XILINXD_LICENSE_FILE=$$XILINXD_LICENSE_FILE"

vck190-check-vivado:
	@command -v vivado >/dev/null 2>&1 || { \
	    echo "ERROR: 'vivado' is not on PATH -- source /tools/Xilinx/Vivado/2022.2/settings64.sh"; exit 1; }
	@echo "==> Vivado detected on PATH: $$(command -v vivado)"

vck190-check-env:
	@command -v petalinux-build >/dev/null 2>&1 || { \
	    echo "ERROR: 'petalinux-build' is not on PATH -- source /tools/Xilinx/PetaLinux/2022.2/settings.sh"; exit 1; }
	@echo "==> PetaLinux Tools detected on PATH: $$(command -v petalinux-build)"

vck190-project: vck190-check-vivado
	@echo "==> Vivado batch: VCK190 playback project + block design (no synthesis)..."
	cd $(VCK190_SYN) && vivado -mode batch -nojournal -log vck190_project.log -source vck190_playback_project.tcl
	@echo "==> Block design validated. Log: $(VCK190_SYN)/vck190_project.log"

vck190-xsa: vck190-check-vivado vck190-check-license
	@echo "==> Vivado batch: VCK190 playback project, synthesis, implementation, device image, XSA..."
	@echo "    Output: $(VCK190_XSA)"
	cd $(VCK190_SYN) && vivado -mode batch -nojournal -log vck190_build.log -source vck190_playback_project.tcl -tclargs build
	@test -f $(VCK190_XSA) || { echo "ERROR: XSA not produced at $(VCK190_XSA) -- see $(VCK190_SYN)/vck190_build.log"; exit 1; }
	@echo "==> XSA built: $(VCK190_XSA)"
	@echo "    Reports: $(VCK190_SYN)/timing_summary.rpt  $(VCK190_SYN)/utilization.rpt"
	@echo "==> Next: make vck190-import-xsa"

vck190-petalinux-create: vck190-check-env
	@test ! -d $(VCK190_PL_PROJECT) || { echo "PetaLinux project already exists at $(VCK190_PL_PROJECT)"; exit 0; }
	@mkdir -p $(VCK190_PL_DIR)
	cd $(VCK190_PL_DIR) && petalinux-create -t project --template versal -n $(VCK190_PL_NAME)
	@echo "==> Created $(VCK190_PL_PROJECT). Next: make vck190-import-xsa"

vck190-import-xsa: vck190-check-env
	@test -f $(VCK190_XSA) || { echo "ERROR: XSA not found at $(VCK190_XSA) -- run 'make vck190-xsa' first"; exit 1; }
	@test -d $(VCK190_PL_PROJECT) || { echo "ERROR: no PetaLinux project -- run 'make vck190-petalinux-create' first"; exit 1; }
	cd $(VCK190_PL_PROJECT) && petalinux-config --silentconfig --get-hw-description=$(VCK190_XSA)
	@# our device-tree additions (UIO for the receiver registers; DMA proxy node)
	cp $(VCK190_USER_DTSI) $(VCK190_PL_PROJECT)/project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi
	@$(MAKE) vck190-check-xsa
	@echo "==> XSA imported. Next: make vck190-build"

vck190-check-xsa:
	@test -f $(VCK190_HW_DESC)/system.xsa || { echo "ERROR: no XSA at $(VCK190_HW_DESC)/system.xsa -- run 'make vck190-import-xsa'"; exit 1; }
	@unzip -p $(VCK190_HW_DESC)/system.xsa '*.hwh' 2>/dev/null | grep -qiE '0x$(VCK190_RX_CTRL_ADDR)|$(shell echo $(VCK190_RX_CTRL_ADDR) | tr A-Z a-z)' || { \
	    echo "ERROR: imported XSA lacks the receiver control block at 0x$(VCK190_RX_CTRL_ADDR)."; \
	    echo "       Either the wrong XSA was imported or assign_bd_address placed it elsewhere;"; \
	    echo "       check $(VCK190_SYN)/vck190_build.log for the INFO line with the addresses."; exit 1; }
	@echo "==> XSA carries the receiver at 0x$(VCK190_RX_CTRL_ADDR)."

vck190-build: vck190-check-env vck190-check-xsa
	cd $(VCK190_PL_PROJECT) && petalinux-build
	cd $(VCK190_PL_PROJECT) && petalinux-package --boot --u-boot --force
	cd $(VCK190_PL_PROJECT) && petalinux-package --prebuilt --force
	@echo "==> Images in $(VCK190_PL_IMAGES):"
	@ls -la $(VCK190_PL_IMAGES)/BOOT.BIN $(VCK190_PL_IMAGES)/image.ub $(VCK190_PL_IMAGES)/boot.scr 2>/dev/null || true
	@echo "==> Next: make vck190-boot (JTAG), or copy BOOT.BIN, image.ub, boot.scr to an SD card."

vck190-boot: vck190-check-env
	cd $(VCK190_PL_PROJECT) && petalinux-boot --jtag --prebuilt 3

vck190-clean:
	rm -rf $(VCK190_SYN)/mdt_vck190_playback_project $(VCK190_SYN)/*.log $(VCK190_SYN)/*.jou \
	       $(VCK190_SYN)/timing_summary.rpt $(VCK190_SYN)/utilization.rpt
	@echo "==> Vivado project removed (XSA kept: $(VCK190_XSA))"
