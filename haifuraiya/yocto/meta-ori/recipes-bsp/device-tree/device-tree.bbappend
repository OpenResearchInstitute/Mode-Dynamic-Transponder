# Bridge the Petalinux-vs-pure-Yocto seam in meta-adi-xilinx's
# device-tree.bbappend. meta-adi's do_configure:append() unconditionally
# seds ${DT_FILES_PATH}/system-conf.dtsi, but that file is a Petalinux-
# tool artifact that pure Yocto doesn't produce. Stage a minimal stub
# here in do_configure:prepend — runs after [cleandirs] wipes
# ${DT_FILES_PATH} but before xsct and before any do_configure:append,
# so the stub is there when meta-adi's append seds it.
#
# Trophy case: "meta-adi's bbappend assumes Petalinux flow, breaks pure
# Yocto." See haifuraiya/yocto/yocto_plan_of_attack.md.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://system-conf.dtsi file://system-user.dtsi"

do_configure:prepend () {
    mkdir -p ${XSCTH_WS}/${XSCTH_PROJ}
    install -m 0644 ${WORKDIR}/system-conf.dtsi ${XSCTH_WS}/${XSCTH_PROJ}/system-conf.dtsi
    install -m 0644 ${WORKDIR}/system-user.dtsi ${XSCTH_WS}/${XSCTH_PROJ}/system-user.dtsi
}
