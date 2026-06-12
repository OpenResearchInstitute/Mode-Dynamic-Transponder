# =============================================================================
# system_project.tcl
# Haifuraiya — ZCU102 + ADRV9002 Integrated Synthesis
# =============================================================================
#
# Creates a Vivado project that integrates the Haifuraiya channelizer IP
# into the Analog Devices adrv9001/zcu102 reference design.
#
# Files we own (kept in this directory):
#   system_project.tcl      this file
#   system_bd.tcl           builds the entire block design (Phase A: source
#                           ADI's reference bd; Phase B: splice the channelizer)
#   axis_iq_wrapper.vhd     parallel-to-AXIS adapter (added to project inside
#                           system_bd.tcl, not here, for ordering reasons —
#                           see system_bd.tcl Phase B.4 comment)
#   README.md               docs
#
# Files we reference via $ad_hdl_dir (pinned by submodule, never copied):
#   $ad_hdl_dir/projects/adrv9001/zcu102/system_top.v
#   $ad_hdl_dir/projects/adrv9001/zcu102/system_constr.xdc
#   $ad_hdl_dir/projects/adrv9001/zcu102/cmos_constr.xdc
#   $ad_hdl_dir/projects/adrv9001/zcu102/lvds_constr.xdc
#   $ad_hdl_dir/projects/adrv9001/common/adrv9001_bd.tcl
#   $ad_hdl_dir/projects/common/zcu102/zcu102_system_bd.tcl
#   $ad_hdl_dir/projects/common/zcu102/zcu102_system_constr.xdc
#   $ad_hdl_dir/library/common/ad_iobuf.v
#
# See README.md for the rationale on referencing vs copying.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Source ADI's environment and project helpers.
# adi_env.tcl establishes $ad_hdl_dir (path to the hdl submodule root).
# -----------------------------------------------------------------------------

source ../../third_party/hdl/scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl

# -----------------------------------------------------------------------------
# Sanity check: verify every upstream file we depend on still exists at the
# path the submodule should have. If the hdl submodule structure changes in
# a future revision (or the submodule isn't initialized), this fails fast
# with an actionable message instead of producing a cryptic Vivado error
# deep in the build.
# -----------------------------------------------------------------------------

set adi_zcu102_dir $ad_hdl_dir/projects/adrv9001/zcu102
set upstream_files_needed [list \
    "$adi_zcu102_dir/system_top.v" \
    "$adi_zcu102_dir/system_constr.xdc" \
    "$adi_zcu102_dir/cmos_constr.xdc" \
    "$adi_zcu102_dir/lvds_constr.xdc" \
    "$ad_hdl_dir/projects/adrv9001/common/adrv9001_bd.tcl" \
    "$ad_hdl_dir/projects/common/zcu102/zcu102_system_bd.tcl" \
    "$ad_hdl_dir/projects/common/zcu102/zcu102_system_constr.xdc" \
    "$ad_hdl_dir/library/common/ad_iobuf.v" \
]

foreach f $upstream_files_needed {
    if {![file exists $f]} {
        error "system_project.tcl: required upstream file missing:\n\
                  $f\n\
               The hdl submodule may need to be initialized or has changed\n\
               structure in an unexpected way. Run from the MDT repo root:\n\
                  git submodule status haifuraiya/third_party/hdl\n\
                  git submodule update --init --recursive\n\
               If the submodule is initialized but the file path has\n\
               moved upstream, this script must be updated to match."
    }
}
puts "INFO: system_project — all required upstream files present"

# -----------------------------------------------------------------------------
# CMOS or LVDS interface mode. CMOS=1 (default), LVDS=0. Matches ADI's default.
# -----------------------------------------------------------------------------

set CMOS_LVDS_N [get_env_param CMOS_LVDS_N 1]

# -----------------------------------------------------------------------------
# Create the Vivado project. Renamed from "adrv9001_zcu102" to
# "adrv9001_zcu102_ori" so this project and ADI's reference project can
# coexist in the same workspace if needed.
# -----------------------------------------------------------------------------

adi_project adrv9001_zcu102_ori 0 [list \
    CMOS_LVDS_N $CMOS_LVDS_N \
]

# -----------------------------------------------------------------------------
# Project files. Bare names = files in this directory. $ad_hdl_dir paths =
# direct references into the pinned hdl submodule (read-only, never modified
# by Vivado, never copied into this directory).
# -----------------------------------------------------------------------------

adi_project_files {} [list \
    "$adi_zcu102_dir/system_top.v" \
    "$adi_zcu102_dir/system_constr.xdc" \
    "$ad_hdl_dir/library/common/ad_iobuf.v" \
    "$ad_hdl_dir/projects/common/zcu102/zcu102_system_constr.xdc" \
]

# CMOS vs LVDS constraints: pick one based on the build-time variable.
if {$CMOS_LVDS_N == 0} {
    adi_project_files {} [list "$adi_zcu102_dir/lvds_constr.xdc"]
} else {
    adi_project_files {} [list "$adi_zcu102_dir/cmos_constr.xdc"]
}

# -----------------------------------------------------------------------------
# Note on VHDL standard for the receiver IP:
#
# The receiver IP's VHDL standard is declared per-file in
# haifuraiya/component.xml via <spirit:fileType> on each .vhd entry, not
# here. That is the correct place: Vivado synthesizes each BD-instantiated
# IP in its OWN sub-project (under .gen/.../ipshared/), whose file
# properties derive from the IP's component.xml. A top-level
# set_property FILE_TYPE override in this script would NOT propagate down
# into the IP sub-synth.
#
# The AXI-Lite slaves (axi_lite_regs, haifuraiya_demod_regs) are written
# VHDL-93-clean: they use internal mirror signals for the AXI handshake
# 'ready' outputs rather than reading from 'out' ports, so they carry
# <spirit:fileType>vhdlSource</spirit:fileType>. Tag a specific file
# vhdlSource-2008 only if it genuinely requires 2008 idioms; reading from
# an 'out' port under VHDL-93 would otherwise produce:
#   ERROR: [Synth 8-10557] cannot read from 'out' object 's_axi_awready';
#                                   use 'buffer' or 'inout' instead
# -----------------------------------------------------------------------------
# Build the project. adi_project_run triggers Vivado to source system_bd.tcl
# from the current directory (i.e., OUR system_bd.tcl in this folder), which
# in turn sources ADI's adrv9001_bd.tcl and our haifuraiya_splice.tcl.
# -----------------------------------------------------------------------------

adi_project_run adrv9001_zcu102_ori
