#!/usr/bin/env bash
#
# setup-petalinux.sh
#
# Rewrites absolute paths in the Haifuraiya PetaLinux project config to
# match the current clone location. Idempotent — safe to run multiple times.
#
# Usage (direct):
#   ./haifuraiya/petalinux/scripts/setup-petalinux.sh
#
# Usage (preferred, via top-level Makefile):
#   make haifuraiya-configure
#
# Why this exists:
#   PetaLinux's `petalinux-config` menuconfig writes ABSOLUTE User Layer
#   paths into project-spec/configs/config. Committing such paths would
#   break for anyone cloning the repo to a different directory than the
#   original author's. This script rewrites those paths based on its own
#   filesystem location so that the project works for any clone path.
#
#   The committed config file ships with sentinel placeholder paths that
#   intentionally fail with an informative message — you must run this
#   script (or `make haifuraiya-configure`) before `petalinux-build`.

set -euo pipefail

# ---------------------------------------------------------------------------
# Precondition: this script requires GNU sed (Linux).
# PetaLinux Tools is Linux-only; the build host must be Linux. macOS users
# verifying the repo can read this script but should not try to run it.
# ---------------------------------------------------------------------------
if ! sed --version 2>/dev/null | grep -q "GNU"; then
    cat >&2 <<EOF
ERROR: This script requires GNU sed (Linux).

       PetaLinux Tools is Linux-only. You should be running this on a
       Linux build host (e.g., Ubuntu 20.04 or 22.04), not on macOS or
       another BSD-flavored system. See haifuraiya/haifuraiya_plan_of_attack.md
       for the supported environment.
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Locate this script and derive the MDT repo root.
# Script lives at: <REPO>/haifuraiya/petalinux/scripts/setup-petalinux.sh
# Repo root is three directories up.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDT_REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PETALINUX_PROJECT="${MDT_REPO}/haifuraiya/petalinux/haifuraiya"
CONFIG_FILE="${PETALINUX_PROJECT}/project-spec/configs/config"
METADATA_FILE="${PETALINUX_PROJECT}/.petalinux/metadata"

META_ADI_BASE="${MDT_REPO}/haifuraiya/third_party/meta-adi"
META_ADI_CORE="${META_ADI_BASE}/meta-adi-core"
META_ADI_XILINX="${META_ADI_BASE}/meta-adi-xilinx"
# ORI's own Yocto layer (in-tree, not a submodule).
META_ORI="${MDT_REPO}/haifuraiya/yocto/meta-ori"

# The integrated XSA — the canonical Haifuraiya hardware artifact, produced
# by 'make haifuraiya-xsa-integrated' (ADI baseline + channelizer splice).
# This is what 'make haifuraiya-import-xsa-integrated' imports, and what
# the deployed PetaLinux build runs against. May not exist on a fresh clone
# (the user must build Vivado first); we still rewrite the path so that
# when they DO build, PetaLinux's HARDWARE_PATH points at the right file.
XSA_PATH="${MDT_REPO}/haifuraiya/syn/zcu102_with_adrv9001/adrv9001_zcu102_ori.sdk/system_top.xsa"

# ---------------------------------------------------------------------------
# Sanity checks: fail fast with clear messages.
# ---------------------------------------------------------------------------
echo "==> Mode-Dynamic-Transponder repo root: ${MDT_REPO}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    cat >&2 <<EOF
ERROR: PetaLinux config file not found at:
       ${CONFIG_FILE}

       Is this script being run from inside the MDT repo? The script
       expects to live at <REPO>/haifuraiya/petalinux/scripts/.
EOF
    exit 1
fi

if [[ ! -f "${METADATA_FILE}" ]]; then
    cat >&2 <<EOF
ERROR: PetaLinux metadata file not found at:
       ${METADATA_FILE}

       This file is tracked in git; its absence suggests an incomplete
       checkout. Verify with: git status haifuraiya/petalinux/haifuraiya/
EOF
    exit 1
fi

if [[ ! -d "${META_ADI_CORE}" || ! -d "${META_ADI_XILINX}" ]]; then
    cat >&2 <<EOF
ERROR: meta-adi submodule is not initialized.

       Expected to find layers at:
         ${META_ADI_CORE}
         ${META_ADI_XILINX}

       Run from the repo root:
         git submodule update --init --recursive

       Then re-run this script.
EOF
    exit 1
fi


if [[ ! -d "${META_ORI}" ]]; then
    cat >&2 <<EOF
ERROR: meta-ori layer not found at expected location:
       ${META_ORI}

       This layer is in-tree (not a submodule) and ships with the repo.
       Its absence suggests an incomplete checkout. Verify with:
         git status haifuraiya/yocto/meta-ori/
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Rewrite User Layer paths.
# ---------------------------------------------------------------------------
echo "==> Rewriting User Layer paths in:"
echo "    ${CONFIG_FILE}"
echo
echo "    CONFIG_USER_LAYER_0 -> ${META_ADI_CORE}"
echo "    CONFIG_USER_LAYER_1 -> ${META_ADI_XILINX}"
echo "    CONFIG_USER_LAYER_2 -> ${META_ORI}"

# Use | as sed separator since paths contain / characters.
sed -i \
    -e "s|^CONFIG_USER_LAYER_0=.*|CONFIG_USER_LAYER_0=\"${META_ADI_CORE}\"|" \
    -e "s|^CONFIG_USER_LAYER_1=.*|CONFIG_USER_LAYER_1=\"${META_ADI_XILINX}\"|" \
    -e "s|^CONFIG_USER_LAYER_2=.*|CONFIG_USER_LAYER_2=\"${META_ORI}\"|" \
    "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Rewrite HARDWARE_PATH in .petalinux/metadata.
# This file records the path to the XSA used at last hardware import; it's
# only consulted when re-running 'petalinux-config --get-hw-description'.
# Day-to-day builds use the cached project-spec/hw-description/ directory,
# but if anyone updates the hdl submodule and re-imports the hardware, this
# path needs to point to the local clone.
# ---------------------------------------------------------------------------
echo
echo "==> Rewriting HARDWARE_PATH in:"
echo "    ${METADATA_FILE}"
echo
echo "    HARDWARE_PATH -> ${XSA_PATH}"

if [[ ! -f "${XSA_PATH}" ]]; then
    echo
    echo "    NOTE: The XSA file does not exist at this path yet. This is normal"
    echo "          on a fresh clone before Vivado has run, and IS NOT AN ERROR."
    echo
    echo "          The XSA is only consulted when REBUILDING HARDWARE via"
    echo "          'make haifuraiya-xsa-integrated' + 'make haifuraiya-import-xsa-integrated'."
    echo "          For normal PetaLinux builds ('make haifuraiya-build'),"
    echo "          the cached hw-description in project-spec/hw-description/"
    echo "          is used, NOT this XSA path."
    echo
    echo "          The HARDWARE_PATH rewrite is still applied so that when you"
    echo "          do build the bitstream, the path will be correct for your clone."
fi

sed -i \
    -e "s|^HARDWARE_PATH=.*|HARDWARE_PATH=${XSA_PATH}|" \
    "${METADATA_FILE}"

# ---------------------------------------------------------------------------
# Verify the rewrite landed.
# ---------------------------------------------------------------------------
echo
echo "==> Verification — current state of rewritten entries:"
echo
echo "    In ${CONFIG_FILE}:"
grep "^CONFIG_USER_LAYER_[012]=" "${CONFIG_FILE}" | sed 's/^/      /'
echo
echo "    In ${METADATA_FILE}:"
grep "^HARDWARE_PATH=" "${METADATA_FILE}" | sed 's/^/      /'

echo
echo "==> Configure done. (This step is a prerequisite for haifuraiya-build,"
echo "    haifuraiya-boot, haifuraiya-import-xsa-integrated, and haifuraiya-update.)"
