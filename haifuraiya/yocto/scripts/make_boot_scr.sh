#!/usr/bin/env bash
# make_boot_scr.sh — Generate boot.scr from boot-script.txt using mkimage
#
# boot.scr is a U-Boot-wrapped script that xsdb loads to memory at
# 0x20000000. U-Boot's autoboot finds it there and runs it immediately,
# setting up static IPs and TFTP-booting Linux without needing DHCP.
#
# Requires: u-boot-tools package (provides mkimage)
#   sudo apt install u-boot-tools

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE="${SCRIPT_DIR}/boot-script.txt"
OUTPUT="${SCRIPT_DIR}/boot.scr"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: source file not found: $SOURCE" >&2
    exit 1
fi

if ! command -v mkimage > /dev/null; then
    echo "ERROR: mkimage not found. Install with:" >&2
    echo "  sudo apt install u-boot-tools" >&2
    exit 1
fi

echo "=== Generating $OUTPUT from $SOURCE ==="
mkimage \
    -A arm64 \
    -O linux \
    -T script \
    -C none \
    -n "Haifuraiya boot" \
    -d "$SOURCE" \
    "$OUTPUT"

echo ""
echo "=== Done. ==="
ls -la "$OUTPUT"
echo ""
echo "Copy $OUTPUT to keroppi's JTAG artifacts directory:"
echo "  scp $OUTPUT abraxas3d@keroppi:/tmp/abraxas3d-yocto-boot/boot.scr"
