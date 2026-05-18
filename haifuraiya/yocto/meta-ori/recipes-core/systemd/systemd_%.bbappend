# systemd_%.bbappend — ORI customization
#
# Adds /etc/systemd/network/10-eth0.network to the rootfs, configuring
# the on-board gigabit Ethernet (eth0) with a static IP suitable for
# the ORI remote lab.
#
# Why a .bbappend instead of a new recipe: systemd-network is a
# subpackage of the upstream systemd recipe. We extend the existing
# recipe by adding our config file to its SRC_URI and to the subpackage's
# FILES list.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://10-eth0.network"

# Install our config into the systemd network directory.
do_install:append() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0.network \
        ${D}${sysconfdir}/systemd/network/10-eth0.network
}

# Add our file to the systemd-network subpackage. PN here is "systemd"
# so PN-network resolves to "systemd-network", the subpackage that ends
# up in the rootfs.
FILES:${PN}-network += "${sysconfdir}/systemd/network/10-eth0.network"
