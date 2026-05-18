# petalinux-image-minimal.bbappend — ORI customization
#
# Add packages to the default petalinux-image-minimal image:
#   - openssh: SSH server + client, so we can ssh into the ZCU102 from
#     keroppi instead of always going through JTAG console.
#
# debug-tweaks (set in local.conf) enables empty-password root SSH login;
# without it, the SSH daemon would refuse root logins by default.
# For Phase 5+ we'll add authorized_keys files and disable empty-password
# root.

IMAGE_INSTALL:append = " openssh"
