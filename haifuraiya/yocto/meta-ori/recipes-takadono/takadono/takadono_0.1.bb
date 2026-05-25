SUMMARY = "Takadono MQTT telemetry publisher for Haifuraiya channelizer"
DESCRIPTION = "Reads Haifuraiya channelizer registers via devmem and publishes \
them to MQTT under haifuraiya/status/#. Companion to the Speculator dashboard \
pattern from pluto_msk; same shell+mosquitto_pub architecture, instrumenting \
the channelizer instead of the OVP modem. See \
${datadir}/takadono/MQTT_TOPICS.md on the target for the full topic schema."
HOMEPAGE = "https://github.com/OpenResearchInstitute/Mode-Dynamic-Transponder"
SECTION = "console/network"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://takadono_pub.sh \
    file://takadono.service \
    file://MQTT_TOPICS.md \
"

S = "${WORKDIR}"

inherit systemd allarch

# systemd integration: declare the unit we own, enable it on first boot.
SYSTEMD_SERVICE:${PN} = "takadono.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Runtime dependencies.
#   mosquitto         - the broker the publisher connects to (same host)
#   mosquitto-clients - provides mosquitto_pub used by the publisher
# busybox is implicit (part of the base image) and provides devmem, sleep,
# date, printf, and the POSIX shell.
RDEPENDS:${PN} = "mosquitto mosquitto-clients"

do_install() {
    # Publisher script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/takadono_pub.sh ${D}${bindir}/takadono_pub.sh

    # systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/takadono.service \
        ${D}${systemd_system_unitdir}/takadono.service

    # Topic schema doc — referenced by the unit's Documentation= field
    install -d ${D}${datadir}/takadono
    install -m 0644 ${WORKDIR}/MQTT_TOPICS.md \
        ${D}${datadir}/takadono/MQTT_TOPICS.md
}

FILES:${PN} = " \
    ${bindir}/takadono_pub.sh \
    ${systemd_system_unitdir}/takadono.service \
    ${datadir}/takadono/MQTT_TOPICS.md \
"
