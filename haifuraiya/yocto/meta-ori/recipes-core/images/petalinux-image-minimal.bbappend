# petalinux-image-minimal.bbappend — ORI customization
#
# Add coreutils for GNU command-line tools (timeout, etc) missing from
# PetaLinux's BusyBox subset.
#
# Note: openssh vs dropbear is selected via project-spec/configs/rootfs_config
# at the menuconfig layer, NOT via this bbappend:
#   CONFIG_imagefeature-ssh-server-openssh=y
#   # CONFIG_imagefeature-ssh-server-dropbear is not set

IMAGE_INSTALL:append = " coreutils"
