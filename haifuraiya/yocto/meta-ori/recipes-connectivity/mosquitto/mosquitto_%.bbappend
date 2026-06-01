# mosquitto_%.bbappend — ORI customization for Bouro / Speculator-style dashboards
#
# Replaces the default mosquitto.conf with one that enables WebSockets on
# port 9001 (in addition to the default MQTT on 1883), so the Bouro
# browser dashboard can connect over WS from a developer laptop. Mirrors
# the broker configuration used by Speculator on the pluto_msk LibreSDR build.
#
# Why a .bbappend instead of dropping a file under /etc/mosquitto/conf.d/:
# the upstream mosquitto.conf in meta-networking does not include conf.d
# by default. Full replacement is the simplest robust path.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://mosquitto.conf"

# Defensive: make sure the websockets PACKAGECONFIG is enabled.
# meta-networking's mosquitto in Kirkstone ships
# "PACKAGECONFIG ??= 'dlt manpages ssl websockets'" by default, so this is
# usually a no-op. If a downstream layer (e.g., a paranoid PetaLinux distro
# config) ever strips websockets, this line guarantees the broker still
# speaks WS so the dashboard works.
PACKAGECONFIG:append = " websockets"

# Overwrite the default config installed by the upstream do_install. The
# :append override runs AFTER the upstream do_install, and `install -m`
# overwrites the existing file. FILES:${PN} already includes
# /etc/mosquitto from the upstream recipe, so no FILES update is needed.
do_install:append() {
    install -m 0644 ${WORKDIR}/mosquitto.conf \
        ${D}${sysconfdir}/mosquitto/mosquitto.conf
}
