#!/bin/bash
# run_jtag_boot.sh
#
# Wrapper for invoking the ZCU102 JTAG boot via xsdb on keroppi.
# Run this ON keroppi (not from mymelody).
#
# Sources the Vivado settings, optionally starts hw_server if not running,
# then invokes xsdb with the boot TCL script.

set -euo pipefail

VIVADO_SETTINGS="/tools/Xilinx/Vivado/2022.2/settings64.sh"
BOOT_DIR="/tmp/abraxas3d-yocto-boot"
BOOT_TCL="${BOOT_DIR}/zcu102_jtag_boot.tcl"

echo "=== Sourcing Vivado 2022.2 settings ==="
source "${VIVADO_SETTINGS}"

# --- Check or start hw_server ---
if pgrep -x hw_server > /dev/null; then
    echo "=== hw_server already running ==="
    pgrep -ax hw_server
else
    echo "=== Starting hw_server in background ==="
    hw_server -d
    sleep 1
fi

# --- Verify boot artifacts present ---
if [ ! -f "${BOOT_TCL}" ]; then
    echo "ERROR: ${BOOT_TCL} not found"
    echo "       Did copy_to_keroppi.sh run successfully?"
    echo "       Also need to copy zcu102_jtag_boot.tcl into ${BOOT_DIR}"
    exit 1
fi

# --- Invoke xsdb ---
echo ""
echo "=== Invoking xsdb with boot script ==="
echo "Boot artifacts directory: ${BOOT_DIR}"
echo "Boot script: ${BOOT_TCL}"
echo ""

export BOOT_DIR
xsdb "${BOOT_TCL}"

echo ""
echo "=== xsdb exited ==="
echo "Check the serial console (/dev/zcu102_uart1) for U-Boot prompt."
