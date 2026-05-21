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
# Locate this script and derive the MDT repo root.
# Script lives at: <REPO>/haifuraiya/petalinux/scripts/setup-petalinux.sh
# Repo root is three directories up.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDT_REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PETALINUX_PROJECT="${MDT_REPO}/haifuraiya/petalinux/haifuraiya"
CONFIG_FILE="${PETALINUX_PROJECT}/project-spec/configs/config"

META_ADI_BASE="${MDT_REPO}/haifuraiya/third_party/meta-adi"
META_ADI_CORE="${META_ADI_BASE}/meta-adi-core"
META_ADI_XILINX="${META_ADI_BASE}/meta-adi-xilinx"

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

# ---------------------------------------------------------------------------
# Rewrite User Layer paths.
# ---------------------------------------------------------------------------
echo "==> Rewriting User Layer paths in:"
echo "    ${CONFIG_FILE}"
echo
echo "    CONFIG_USER_LAYER_0 -> ${META_ADI_CORE}"
echo "    CONFIG_USER_LAYER_1 -> ${META_ADI_XILINX}"

# Use | as sed separator since paths contain / characters.
sed -i \
    -e "s|^CONFIG_USER_LAYER_0=.*|CONFIG_USER_LAYER_0=\"${META_ADI_CORE}\"|" \
    -e "s|^CONFIG_USER_LAYER_1=.*|CONFIG_USER_LAYER_1=\"${META_ADI_XILINX}\"|" \
    "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Verify the rewrite landed.
# ---------------------------------------------------------------------------
echo
echo "==> Verification — current state of User Layer entries:"
grep "^CONFIG_USER_LAYER_[012]=" "${CONFIG_FILE}" | sed 's/^/    /'

echo
echo "==> Done. Next steps:"
echo
echo "    Build the Haifuraiya PetaLinux image:"
echo "      cd ${MDT_REPO}"
echo "      make haifuraiya-build"
echo
echo "    (Or build manually:)"
echo "      cd ${PETALINUX_PROJECT}"
echo "      petalinux-build"
