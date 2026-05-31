SUMMARY = "Bouro MQTT telemetry publisher for Haifuraiya channelizer"
DESCRIPTION = "Reads Haifuraiya channelizer registers via devmem and publishes \
them to MQTT under haifuraiya/status/#. Companion to the Speculator dashboard \
pattern from pluto_msk; same shell+mosquitto_pub architecture, instrumenting \
the channelizer instead of the OVP modem. Also installs the bouro.html \
dashboard and Paho MQTT JS library into /usr/share/bouro/www/, served \
statically by mosquitto's WebSocket listener on port 9001. See \
${datadir}/bouro/MQTT_TOPICS.md on the target for the full topic schema."
HOMEPAGE = "https://github.com/OpenResearchInstitute/Mode-Dynamic-Transponder"
SECTION = "console/network"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://bouro_pub.sh \
    file://bouro.service \
    file://MQTT_TOPICS.md \
    file://www/bouro.html \
    file://www/mqttws31.min.js \
"

S = "${WORKDIR}"

inherit systemd allarch

# systemd integration: declare the unit we own, enable it on first boot.
SYSTEMD_SERVICE:${PN} = "bouro.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Runtime dependencies.
#   mosquitto         - the broker the publisher connects to (same host).
#                       Also serves the dashboard via http_dir on its
#                       WebSocket listener (port 9001).
#   mosquitto-clients - provides mosquitto_pub used by the publisher
# busybox is implicit (part of the base image) and provides devmem, sleep,
# date, printf, and the POSIX shell.
RDEPENDS:${PN} = "mosquitto mosquitto-clients"

do_install() {
    # Publisher script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/bouro_pub.sh ${D}${bindir}/bouro_pub.sh

    # systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/bouro.service \
        ${D}${systemd_system_unitdir}/bouro.service

    # Topic schema doc — referenced by the unit's Documentation= field
    install -d ${D}${datadir}/bouro
    install -m 0644 ${WORKDIR}/MQTT_TOPICS.md \
        ${D}${datadir}/bouro/MQTT_TOPICS.md

    # Dashboard — HTML + vendored Paho MQTT JS, served by mosquitto via
    # its http_dir setting on the WebSocket listener.
    install -d ${D}${datadir}/bouro/www
    install -m 0644 ${WORKDIR}/www/bouro.html \
        ${D}${datadir}/bouro/www/bouro.html
    install -m 0644 ${WORKDIR}/www/mqttws31.min.js \
        ${D}${datadir}/bouro/www/mqttws31.min.js
}

FILES:${PN} = " \
    ${bindir}/bouro_pub.sh \
    ${systemd_system_unitdir}/bouro.service \
    ${datadir}/bouro/MQTT_TOPICS.md \
    ${datadir}/bouro/www \
"
