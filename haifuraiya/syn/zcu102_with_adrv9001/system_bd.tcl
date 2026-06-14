# =============================================================================
# system_bd.tcl
# Haifuraiya — ZCU102 + ADRV9002 Integrated Synthesis
# =============================================================================
#
# Builds the Vivado block design in two phases:
#
#   Phase A: Reproduce ADI's adrv9001/zcu102 reference design by sourcing
#            their bd helpers verbatim. This builds the PS, DDR, clocks,
#            ADRV9002 IP, RX1/RX2/TX1/TX2 datapaths, and util_cpack2 /
#            util_upack2 packing.
#
#   Phase B: Splice the Haifuraiya channelizer into the RX1 datapath:
#              - register Haifuraiya IP repo (so the channelizer is findable)
#              - reconfigure axi_adrv9001_rx1_dma from FIFO mode to AXIS mode
#              - delete util_adc_1_pack (no longer needed on RX1)
#              - insert axis_iq_wrapper_rx1 (parallel I/Q → AXIS adapter)
#              - insert channelizer_rx1 (haifuraiya_channelizer_axi v0.1)
#              - invert reset polarity for AXIS components
#              - wire ADRV9002 → wrapper → channelizer → DMA
#              - expose channelizer control AXI-Lite at 0x84A70000
#
# RX2, TX1, TX2 paths are NOT modified — they remain identical to ADI's
# reference, providing a sanity baseline if the RX1 channelizer path
# misbehaves.
#
# Why everything is in this one file:
#   The pluto_msk libre project keeps all block-design construction in a
#   single system_bd.tcl. Splitting Phase B into a separate splice file
#   introduces ordering bugs: add_files calls and project state are
#   sensitive to the relative timing of adi_project_create() (which
#   sources this file) and adi_project_files() (called from
#   system_project.tcl AFTER adi_project_create returns). Keeping
#   everything here side-steps that whole class of problem.
#
# =============================================================================


# -----------------------------------------------------------------------------
# Phase A: Build the base ADI design, exactly as upstream would.
# -----------------------------------------------------------------------------

source $ad_hdl_dir/projects/common/zcu102/zcu102_system_bd.tcl
source $ad_hdl_dir/projects/adrv9001/common/adrv9001_bd.tcl
source $ad_hdl_dir/projects/scripts/adi_pd.tcl

# Pass CMOS/LVDS mode through to axi_adrv9001.
ad_ip_parameter axi_adrv9001 CONFIG.USE_RX_CLK_FOR_TX [expr $ad_project_params(CMOS_LVDS_N) == 0]

# System ID ROM. Baked-in metadata identifying this bitstream's
# CMOS_LVDS_N configuration so software can introspect it at runtime.
set mem_init_sys_path [get_env_param ADI_PROJECT_DIR ""]mem_init_sys.txt
ad_ip_parameter axi_sysid_0 CONFIG.ROM_ADDR_BITS 9
ad_ip_parameter rom_sys_0   CONFIG.PATH_TO_FILE "[pwd]/$mem_init_sys_path"
ad_ip_parameter rom_sys_0   CONFIG.ROM_ADDR_BITS 9

set sys_cstring "CMOS_LVDS_N=${ad_project_params(CMOS_LVDS_N)}"
sysid_gen_sys_init_file $sys_cstring

# Implementation strategy. Same as upstream.
set_property strategy Flow_RunPostRoutePhysOpt [get_runs impl_1]


# -----------------------------------------------------------------------------
# Phase B: Haifuraiya channelizer integration.
#
# Locate the directory this script lives in, so add_files / IP-repo paths
# work regardless of Vivado's current working directory.
# -----------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]

puts "INFO: haifuraiya — beginning RX1 channelizer integration"


# -----------------------------------------------------------------------------
# B.1 Add the Haifuraiya IP repository (path-portable, derived from script
#     location). The channelizer's component.xml lives at the haifuraiya/
#     root, two directories up from this script.
# -----------------------------------------------------------------------------

set haifuraiya_ip_repo [file normalize "${script_dir}/../../"]

if {![file exists "${haifuraiya_ip_repo}/component.xml"]} {
    error "system_bd.tcl: component.xml not found at ${haifuraiya_ip_repo}.\n\
           This script expects to live at haifuraiya/syn/zcu102_with_adrv9001/."
}

puts "INFO: haifuraiya — IP repo: ${haifuraiya_ip_repo}"

set existing_repos [get_property ip_repo_paths [current_fileset]]
set_property ip_repo_paths [list {*}$existing_repos $haifuraiya_ip_repo] [current_fileset]
update_ip_catalog


# -----------------------------------------------------------------------------
# B.2 Reconfigure axi_adrv9001_rx1_dma from FIFO mode (DMA_TYPE_SRC=2,
#     DATA_WIDTH=64) to AXIS mode (DMA_TYPE_SRC=1, DATA_WIDTH=32).
#     This is THE key one-line change inherited from the pluto_msk libre
#     precedent.
# -----------------------------------------------------------------------------

ad_ip_parameter axi_adrv9001_rx1_dma CONFIG.DMA_TYPE_SRC        1
ad_ip_parameter axi_adrv9001_rx1_dma CONFIG.DMA_DATA_WIDTH_SRC  16


# -----------------------------------------------------------------------------
# B.3 Remove the util_adc_1_pack instance and all its connections — it is
#     no longer in the datapath. (RX2 retains util_adc_2_pack.)
# -----------------------------------------------------------------------------

delete_bd_objs [get_bd_cells util_adc_1_pack]


#------------------------------------------------------------------------------
# B.3.5 Tie off axi_adrv9001 RX1 overflow status input
#------------------------------------------------------------------------------
# The upstream ADI reference (adrv9001_bd.tcl:226) wires:
#   axi_adrv9001/adc_1_dovf  <-  util_adc_1_pack/fifo_wr_overflow
# where util_adc_1_pack is a pass-through exposing the RX1 DMA's
# fifo_wr_overflow output (which exists in parallel slave mode).
#
# Our AXIS-mode RX1 DMA (CONFIG.DMA_TYPE_SRC=1) does not have a
# fifo_wr_overflow port -- the entire fifo_wr_* group is disabled when
# the slave port is AXIS (see [BD 41-1684] warning from this script).
# In AXIS mode, overflow at the DMA boundary is impossible by construction:
# the DMA asserts backpressure via s_axis_ready, and the upstream channelizer
# honors AXIS protocol. Samples are never lost at this interface.
#
# We therefore tie axi_adrv9001/adc_1_dovf to constant 0, which is the
# semantically correct value for an AXIS-DMA configuration. Without this
# explicit tie-off, adc_1_dovf becomes a driverless net inside
# axi_adrv9001's i_xfer_status block. opt_design then trims related
# logic but leaves a LUT5 with a dangling I3 input, producing the
# [Opt 31-67] connectivity-check error during impl_1.
#------------------------------------------------------------------------------

ad_ip_instance xlconstant axi_adrv9001_rx1_dovf_tie
ad_ip_parameter axi_adrv9001_rx1_dovf_tie CONFIG.CONST_VAL   0
ad_ip_parameter axi_adrv9001_rx1_dovf_tie CONFIG.CONST_WIDTH 1

ad_connect axi_adrv9001/adc_1_dovf  axi_adrv9001_rx1_dovf_tie/dout


# -----------------------------------------------------------------------------
# B.4 Add the parallel-to-AXIS adapter VHDL to the project, then instantiate
#     it as a block design cell.
#
#     The add_files call MUST happen here (in the bd tcl), not in
#     system_project.tcl, because adi_project_create() builds the block
#     design BEFORE returning, so any adi_project_files calls made after
#     adi_project in system_project.tcl run too late — the wrapper module
#     wouldn't be findable when create_bd_cell tries to reference it.
#     Matches the pluto_msk libre clk_div_by4 integration pattern.
# -----------------------------------------------------------------------------

add_files -norecurse [file join $script_dir "axis_iq_wrapper.vhd"]
update_compile_order -fileset sources_1

create_bd_cell -type module -reference axis_iq_wrapper axis_iq_wrapper_rx1


# -----------------------------------------------------------------------------
# B.5 Instantiate the Haifuraiya channelizer from the IP repo registered
#     in section B.1.
# -----------------------------------------------------------------------------

create_bd_cell -type ip \
    -vlnv openresearch.institute:ip:haifuraiya_rx_axi:0.4 \
    channelizer_rx1


# -----------------------------------------------------------------------------
# B.6 Create an active-low reset for the channelizer and wrapper.
#     ADI uses adc_1_rst (active high); AXIS components want aresetn.
# -----------------------------------------------------------------------------

ad_ip_instance util_vector_logic adc_1_rst_inv [list \
    C_OPERATION {not} \
    C_SIZE 1 \
]
ad_connect axi_adrv9001/adc_1_rst adc_1_rst_inv/Op1
# adc_1_rst_inv/Res is now the active-low reset


# -----------------------------------------------------------------------------
# B.7 Clock + reset distribution.
#
#     Architecture: wrapper runs at adc_1_clk (the ADRV9002 data domain),
#     but the channelizer and downstream DMA run at PS clock (pl_clk0,
#     100 MHz). An axis_data_fifo in section B.8 bridges the two domains.
#
#     This matches the channelizer's documented design point. From the
#     header of haifuraiya_channelizer_axi.vhd:
#
#         "At 100 MHz aclk with 10 MSps complex input and M_DECIMATION=16:
#            Input AXIS  : up to 1 beat per 10 clocks (~10% of capacity)
#            Output AXIS : 64 beats every 160 clocks  (~40% of capacity)
#          Comfortable margins on both sides for downstream DMA pacing."
#
#     For Haifuraiya/FunCube+ the 10 MSps input rate corresponds to a
#     10 MHz regulatory subband of our 5 GHz amateur allocation, complex
#     baseband sampled at Nyquist. 64 channels across that subband gives
#     ~156 kHz per-channel spacing; M_DECIMATION=16 yields ~625 kSps
#     per-channel output rate.
#
#     Why split adc_1_clk from channelizer aclk:
#       - The channelizer IP has a single aclk port; aresetn's
#         ASSOCIATED_RESET association means ALL its bus interfaces
#         (s_axis_data, m_axis_soft_bit, s_axi_ctrl) share that clock.
#       - If we ran aclk at adc_1_clk, s_axi_ctrl would be on a different
#         clock domain from the PS interconnect — failing validate_bd_design
#         with ERROR [BD 41-237] CLK_DOMAIN mismatch. Resolving that needs
#         an axi_clock_converter on the AXI-Lite path: more BD complexity.
#       - Running aclk at PS clock instead, plus a CDC FIFO on the data
#         path, is fewer cells AND matches the IP's documented operating
#         point (100 MHz aclk).
# -----------------------------------------------------------------------------

# Wrapper: at adc_1_clk (matches ADRV9002's data interface clock).
ad_connect axi_adrv9001/adc_1_clk axis_iq_wrapper_rx1/clk
ad_connect adc_1_rst_inv/Res      axis_iq_wrapper_rx1/aresetn

# Channelizer: at PS clock (avoids AXI-Lite CDC complexity).
ad_connect $sys_cpu_clk    channelizer_rx1/aclk
ad_connect $sys_cpu_resetn channelizer_rx1/aresetn


# -----------------------------------------------------------------------------
# B.8 CDC FIFO between wrapper (adc_1_clk) and channelizer (PS clock).
#     Async FIFO handles the clock domain crossing safely. Depth 64 is
#     ample for handling transient skew at our sample rates; can be
#     deepened if overflow ever observed.
# -----------------------------------------------------------------------------

ad_ip_instance axis_data_fifo data_cdc_fifo_rx1
ad_ip_parameter data_cdc_fifo_rx1 CONFIG.IS_ACLK_ASYNC  {1}
ad_ip_parameter data_cdc_fifo_rx1 CONFIG.TDATA_NUM_BYTES {4}
ad_ip_parameter data_cdc_fifo_rx1 CONFIG.FIFO_DEPTH      {64}

# CDC clocks/resets: slave side at adc_1_clk, master side at PS clock.
#
# Note: axis_data_fifo with IS_ACLK_ASYNC=1 exposes only s_axis_aresetn —
# the m_axis_aresetn pin does not exist in this configuration. The IP
# internally synchronizes the slave-side reset to the master clock
# domain via its own reset CDC. Trying to connect m_axis_aresetn
# produces "No pins matched" warnings and downstream errors, as the
# pin simply isn't there. (Pluto_msk hit this too; root cause was the
# same — pin doesn't exist in async mode, not an ad_connect quirk.)
ad_connect axi_adrv9001/adc_1_clk data_cdc_fifo_rx1/s_axis_aclk
ad_connect adc_1_rst_inv/Res      data_cdc_fifo_rx1/s_axis_aresetn
ad_connect $sys_cpu_clk           data_cdc_fifo_rx1/m_axis_aclk


# -----------------------------------------------------------------------------
# B.9 Datapath: ADRV9002 → wrapper → CDC FIFO → channelizer → DMA
# -----------------------------------------------------------------------------

ad_connect axi_adrv9001/adc_1_data_i0  axis_iq_wrapper_rx1/i_data
ad_connect axi_adrv9001/adc_1_data_q0  axis_iq_wrapper_rx1/q_data
ad_connect axi_adrv9001/adc_1_valid_i0 axis_iq_wrapper_rx1/in_valid

ad_connect axis_iq_wrapper_rx1/m_axis    data_cdc_fifo_rx1/S_AXIS
ad_connect data_cdc_fifo_rx1/M_AXIS      channelizer_rx1/s_axis_data
# Soft-bit width adapter (3-bit -> byte). rx_axi emits m_axis_soft_bit as a
# 3-bit soft value (0..7); the S2MM DMA source is now byte-wide, so zero-extend
# each value into a byte -> the DMA writes one byte per soft bit, the layout
# opv-decode -3 reads. (axis_dma_adapter.vhd is the transmit-side NARROWER and
# is deliberately NOT used here -- this widens in the receive direction.)
add_files -norecurse [file join $script_dir "axis_softbit_widen.vhd"]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference axis_softbit_widen soft_widen_rx1
ad_connect $sys_cpu_clk    soft_widen_rx1/aclk
ad_connect $sys_cpu_resetn soft_widen_rx1/aresetn
ad_connect channelizer_rx1/m_axis_soft_bit soft_widen_rx1/s_axis
ad_connect soft_widen_rx1/m_axis           axi_adrv9001_rx1_dma/s_axis

# DMA AXIS-side clock = PS clock (matches channelizer output domain).
ad_connect $sys_cpu_clk axi_adrv9001_rx1_dma/s_axis_aclk


# -----------------------------------------------------------------------------
# B.10 AXI-Lite control interface for the channelizer.
#      No clock converter needed — channelizer is now on PS clock, matching
#      the cpu interconnect's domain.
#
#      ZynqMP gotcha: ad_cpu_interconnect translates the TCL address by
#      adding 0x40000000. So 0x44A_xxxx values shown in adrv9001_bd.tcl
#      actually appear in /proc/iomem at 0x84A_xxxx.
#
#      ADI's ZynqMP allocations after translation:
#        axi_adrv9001          0x84A00000 (64K)
#        axi_adrv9001_rx1_dma  0x84A30000 (64K)
#        axi_adrv9001_rx2_dma  0x84A40000 (64K)
#        axi_adrv9001_tx1_dma  0x84A50000 (64K)
#        axi_adrv9001_tx2_dma  0x84A60000 (64K)
#
#      We use 0x44A70000 → 0x84A70000, the next clean 64K slot.
# -----------------------------------------------------------------------------

ad_cpu_interconnect 0x44A70000 channelizer_rx1 s_axi_ctrl
# ad_cpu_interconnect names the master segment after the CELL
# (SEG_data_channelizer_rx1); a 2nd slave on the same cell collides.
# Rename the first segment before mapping the second.
set_property name SEG_data_channelizer_rx1_ctrl [get_bd_addr_segs sys_ps8/Data/SEG_data_channelizer_rx1]
ad_cpu_interconnect 0x44A80000 channelizer_rx1 s_axi_demod
set_property name SEG_data_channelizer_rx1_demod [get_bd_addr_segs sys_ps8/Data/SEG_data_channelizer_rx1]
puts "INFO: haifuraiya - demod control AXI-Lite at 0x84A80000 (TCL arg 0x44A80000)"

puts "INFO: haifuraiya — RX1 channelizer integration complete"
puts "INFO: haifuraiya — channelizer control AXI-Lite at 0x84A70000 (TCL arg 0x44A70000)"
puts "INFO: haifuraiya — channelizer output via axi_adrv9001_rx1_dma at 0x84A30000 (unchanged)"
puts "INFO: haifuraiya — channelizer + DMA run at PS clock; wrapper at adc_1_clk; CDC FIFO bridges"



##############################################################################
# ILA Debug Core - RX demod bring-up
##############################################################################
# Confirms on real silicon: (a) the target channel carries signal (dbg_tgt_i/q),
# (b) Costas locks (cst_lock_f1/f2), (c) frame sync asserts and frames_received
# climbs. All in the PS clock domain (100 MHz).
#   probe0 dbg_tgt_i[15:0]   probe1 dbg_tgt_q[15:0]   probe2 dbg_tgt_valid
#   probe3 frame_sync_locked probe4 cst_lock_f1       probe5 cst_lock_f2
#   probe6 frames_received[31:0]
##############################################################################
#create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_rx_demod
#set_property -dict [list \
#    CONFIG.C_PROBE0_WIDTH {16} \
#    CONFIG.C_PROBE1_WIDTH {16} \
#    CONFIG.C_PROBE2_WIDTH {1} \
#    CONFIG.C_PROBE3_WIDTH {1} \
#    CONFIG.C_PROBE4_WIDTH {1} \
#    CONFIG.C_PROBE5_WIDTH {1} \
#    CONFIG.C_PROBE6_WIDTH {32} \
#    CONFIG.C_NUM_OF_PROBES {7} \
#    CONFIG.C_DATA_DEPTH {4096} \
#    CONFIG.C_TRIGIN_EN {false} \
#] [get_bd_cells ila_rx_demod]

#ad_connect $sys_cpu_clk ila_rx_demod/clk
#ad_connect channelizer_rx1/dbg_tgt_i         ila_rx_demod/probe0
#ad_connect channelizer_rx1/dbg_tgt_q         ila_rx_demod/probe1
#ad_connect channelizer_rx1/dbg_tgt_valid     ila_rx_demod/probe2
#ad_connect channelizer_rx1/frame_sync_locked ila_rx_demod/probe3
#ad_connect channelizer_rx1/cst_lock_f1       ila_rx_demod/probe4
#ad_connect channelizer_rx1/cst_lock_f2       ila_rx_demod/probe5
#ad_connect channelizer_rx1/frames_received   ila_rx_demod/probe6

#puts "INFO: haifuraiya - RX demod ILA inserted (7 probes, depth 4096)"


##############################################################################
# ILA 1/2 -- ila_rx_demod : carrier-loop view, storage-qualified on dbg_tgt_valid
##############################################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_rx_demod
set_property -dict [list \
    CONFIG.C_MONITOR_TYPE {Native} \
    CONFIG.C_TRIGIN_EN {false} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_DATA_DEPTH {2048} \
    CONFIG.C_NUM_OF_PROBES {16} \
] [get_bd_cells ila_rx_demod]
set_property -dict [list \
    CONFIG.C_PROBE0_WIDTH {16}  CONFIG.C_PROBE1_WIDTH {16} \
    CONFIG.C_PROBE2_WIDTH {1}   CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {32}  CONFIG.C_PROBE5_WIDTH {32} \
    CONFIG.C_PROBE6_WIDTH {32}  CONFIG.C_PROBE7_WIDTH {32} \
    CONFIG.C_PROBE8_WIDTH {32}  CONFIG.C_PROBE9_WIDTH {32} \
    CONFIG.C_PROBE10_WIDTH {16} CONFIG.C_PROBE11_WIDTH {16} \
    CONFIG.C_PROBE12_WIDTH {1}  CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1}  CONFIG.C_PROBE15_WIDTH {1} \
] [get_bd_cells ila_rx_demod]
ad_connect $sys_cpu_clk ila_rx_demod/clk
ad_connect channelizer_rx1/dbg_tgt_i           ila_rx_demod/probe0
ad_connect channelizer_rx1/dbg_tgt_q           ila_rx_demod/probe1
ad_connect channelizer_rx1/dbg_tgt_valid       ila_rx_demod/probe2
ad_connect channelizer_rx1/dbg_cst_iq_delta    ila_rx_demod/probe3
ad_connect channelizer_rx1/dbg_cst_acc_i       ila_rx_demod/probe4
ad_connect channelizer_rx1/dbg_cst_acc_q       ila_rx_demod/probe5
ad_connect channelizer_rx1/dbg_f1_err          ila_rx_demod/probe6
ad_connect channelizer_rx1/dbg_f2_err          ila_rx_demod/probe7
ad_connect channelizer_rx1/dbg_lpf_acc_f1      ila_rx_demod/probe8
ad_connect channelizer_rx1/dbg_lpf_acc_f2      ila_rx_demod/probe9
ad_connect channelizer_rx1/dbg_cst_locktime_f1 ila_rx_demod/probe10
ad_connect channelizer_rx1/dbg_cst_locktime_f2 ila_rx_demod/probe11
ad_connect channelizer_rx1/cst_lock_f1         ila_rx_demod/probe12
ad_connect channelizer_rx1/cst_lock_f2         ila_rx_demod/probe13
ad_connect channelizer_rx1/dbg_cst_unlock_f1   ila_rx_demod/probe14
ad_connect channelizer_rx1/dbg_cst_unlock_f2   ila_rx_demod/probe15

##############################################################################
# ILA 2/2 -- ila_rx_fsync : frame-sync view, storage-qualified on dbg_sym_valid
##############################################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_rx_fsync
set_property -dict [list \
    CONFIG.C_MONITOR_TYPE {Native} \
    CONFIG.C_TRIGIN_EN {false} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_NUM_OF_PROBES {8} \
] [get_bd_cells ila_rx_fsync]
set_property -dict [list \
    CONFIG.C_PROBE0_WIDTH {16} CONFIG.C_PROBE1_WIDTH {3} \
    CONFIG.C_PROBE2_WIDTH {32} CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {3}  CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {32} CONFIG.C_PROBE7_WIDTH {1} \
] [get_bd_cells ila_rx_fsync]
ad_connect $sys_cpu_clk ila_rx_fsync/clk
ad_connect channelizer_rx1/dbg_soft_corr     ila_rx_fsync/probe0
ad_connect channelizer_rx1/dbg_fs_soft_q     ila_rx_fsync/probe1
ad_connect channelizer_rx1/dbg_fs_corr       ila_rx_fsync/probe2
ad_connect channelizer_rx1/dbg_fs_corr_peak  ila_rx_fsync/probe3
ad_connect channelizer_rx1/dbg_fs_state      ila_rx_fsync/probe4
ad_connect channelizer_rx1/frame_sync_locked ila_rx_fsync/probe5
ad_connect channelizer_rx1/frames_received   ila_rx_fsync/probe6
ad_connect channelizer_rx1/dbg_sym_valid     ila_rx_fsync/probe7

puts "INFO: haifuraiya - RX ILAs: ila_rx_demod (16p carrier) + ila_rx_fsync (8p frame-sync)"
