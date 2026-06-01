# petalinux-image-minimal.bbappend — ORI customization
#
# Adds packages required by the Open Research Institute customizations on
# top of PetaLinux's minimal image.
#
# Note: openssh vs dropbear is selected via project-spec/configs/rootfs_config
# at the menuconfig layer, NOT via this bbappend:
#   CONFIG_imagefeature-ssh-server-openssh=y
#   # CONFIG_imagefeature-ssh-server-dropbear is not set

IMAGE_INSTALL:append = " \
    coreutils \
    mosquitto \
    mosquitto-clients \
    bouro \
"

# Package roles:
#   coreutils         - GNU command-line tools (timeout, etc) missing from busybox subset
#   mosquitto         - MQTT broker, listens on 1883 (TCP) and 9001 (WebSockets)
#   mosquitto-clients - provides mosquitto_pub used by bouro_pub.sh
#   bouro          - the channelizer telemetry publisher (see recipes-bouro/)
#                       RDEPENDS on mosquitto and mosquitto-clients, so the
#                       explicit listing here is belt-and-suspenders.
