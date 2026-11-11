# vck190_playback_bd.tcl -- VCK190 playback self-test: block design
#
# STATUS: validates and generates in Vivado 2022.2 on chococat (2026-10-23,
# after three fixes: catalog CIPS version, plain-VHDL module-reference tops,
# slave-side address assignment).  Written from the Versal CIPS/NoC
# block-automation flow and the ZCU102 integration
# (syn/zcu102_with_adrv9001/system_bd.tcl).
#
# WHAT THIS BUILDS (one sentence): the receiver as simulated, fed from DDR
# by a DMA engine metered to the ADC sample rate, with its soft bits written
# back to DDR, all controlled from the A72s over AXI-Lite.
#
#   DDR  --NoC--> axi_dma (MM2S, 32-bit I/Q beats, every clock)
#                   --> axis_sample_pacer (one beat per PERIOD clocks = 20 MSps)
#                   --> haifuraiya_rx_axi.s_axis_data          (the sim DUT)
#        haifuraiya_rx_axi.m_axis_soft_bit (3-bit + TLAST)
#                   --> axis_softbit_widen (byte per soft bit, opv-decode -3)
#                   --> axi_dma (S2MM) --NoC--> DDR
#   CIPS M_AXI_FPD --> smartconnect --> axi_dma S_AXI_LITE
#                                   --> haifuraiya_rx_axi.s_axi_ctrl   (channelizer regs)
#                                   --> haifuraiya_rx_axi.s_axi_demod  (demod regs)
#   Clock: CIPS pl0_ref_clk at 100 MHz for everything in the PL (the
#   receiver's aclk design point); reset: pl0_resetn via proc_sys_reset.
#
# This TCL is sourced by vck190_playback_project.tcl after the RTL has been
# added to the project; it assumes `set_property board_part` is done.

set bd_name playback
create_bd_design $bd_name
current_bd_design $bd_name
# tier is set by vck190_playback_project.tcl (VCK190_TIER); 1 when sourced alone
if {![info exists tier]} { set tier 1 }

# -----------------------------------------------------------------------------
# 1. CIPS + NoC + DDR4 from the board preset.
#    The cips block automation (2022.2) adds an axi_noc with one DDR4 memory
#    controller on the board's DIMM, wires the PS NoC ports, and brings out
#    one PL clock and one PL reset.
# -----------------------------------------------------------------------------
# take the catalog's own versal_cips version (pinning 3.2 against a newer
# catalog creates the cell LOCKED, and block automation then refuses it)
set cips_vlnv [lindex [lsort -dictionary [get_ipdefs -all -filter {VLNV =~ "xilinx.com:ip:versal_cips:*"}]] end]
puts "INFO: using $cips_vlnv"
create_bd_cell -type ip -vlnv $cips_vlnv cips
apply_bd_automation -rule xilinx.com:bd_rule:cips -config { \
    board_preset {Yes} \
    boot_config {Custom} \
    configure_noc {Add new AXI NoC} \
    debug_config {JTAG} \
    design_flow {Full System} \
    mc_type {DDR} \
    num_mc_ddr {1} \
    num_mc_lpddr {None} \
    pl_clocks {1} \
    pl_resets {1} \
} [get_bd_cells cips]

# PL clock 0 = 100 MHz (receiver aclk design point), and the PL AXI master
# the control plane hangs from.  These are PS_PMC_CONFIG keys; if the
# automation already set some of them, re-setting is harmless.
set_property -dict [list CONFIG.PS_PMC_CONFIG { \
    PS_USE_M_AXI_FPD {1} \
    PS_M_AXI_FPD_DATA_WIDTH {32} \
    PS_PL_CONNECTIVITY_MODE {Custom} \
    PS_NUM_FABRIC_RESETS {1} \
    PS_USE_PMCPL_CLK0 {1} \
    PMC_CRP_PL0_REF_CTRL_FREQMHZ {100} \
    PS_IRQ_USAGE {{CH0 1} {CH1 1}} \
}] [get_bd_cells cips]
# PS_IRQ_USAGE enables PL-to-PS interrupt inputs pl_ps_irq0/1 (2026-10-24:
# the first boot's xilinx-vdma probe failed with "failed to get irq" --
# the DMA engine's two interrupt outputs were not connected, and the
# driver will not bind without them; see section 3)

set noc [get_bd_cells axi_noc_0]
if {$noc eq ""} { error "cips automation did not create axi_noc_0 -- check the automation config names for this Vivado version" }

# -----------------------------------------------------------------------------
# 2. PL clock/reset
# -----------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl0
connect_bd_net [get_bd_pins cips/pl0_ref_clk] [get_bd_pins rst_pl0/slowest_sync_clk]
connect_bd_net [get_bd_pins cips/pl0_resetn] [get_bd_pins rst_pl0/ext_reset_in]
set pl_clk  [get_bd_pins cips/pl0_ref_clk]
set pl_rstn [get_bd_pins rst_pl0/peripheral_aresetn]

# -----------------------------------------------------------------------------
# 3. DMA engine: scatter-gather so a one-second (83 MB) playback streams
#    across descriptors without a gap; MM2S 32-bit (I/Q beat), S2MM 8-bit
#    (one byte per soft bit, the layout opv-decode -3 reads).
# -----------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma
set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_s_axis_s2mm_tdata_width {8} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_addr_width {64} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
] [get_bd_cells axi_dma]
# ^ c_sg_include_stscntrl_strm: the IP's default (1, when SG is on) adds the
#   optional status/control streams (S_AXIS_STS in, M_AXIS_CNTRL out).  With
#   them present, the S2MM channel completes an END-OF-PACKET descriptor only
#   after a status word arrives on S_AXIS_STS -- which nothing here drives, so
#   it was tied to '0' and every TLAST-terminated frame wedged the channel
#   (data written, status never written, never idle).  Count-terminated
#   descriptors completed, which is how it was bracketed.  Found 2026-10-25
#   with the ILA on M_AXI_SG / M_AXI_S2MM: all write responses OKAY, then
#   nothing.  Off = plain SG DMA; TLAST alone ends a packet.
connect_bd_net $pl_clk  [get_bd_pins axi_dma/s_axi_lite_aclk]
connect_bd_net $pl_clk  [get_bd_pins axi_dma/m_axi_sg_aclk]
connect_bd_net $pl_clk  [get_bd_pins axi_dma/m_axi_mm2s_aclk]
connect_bd_net $pl_clk  [get_bd_pins axi_dma/m_axi_s2mm_aclk]
connect_bd_net $pl_rstn [get_bd_pins axi_dma/axi_resetn]
# DMA interrupts to the PS: MM2S on pl_ps_irq0, S2MM on pl_ps_irq1.  The
# device-tree generator turns these into the dma node's "interrupts"
# property, which the xilinx_dma driver requires to probe.
connect_bd_net [get_bd_pins axi_dma/mm2s_introut] [get_bd_pins cips/pl_ps_irq0]
connect_bd_net [get_bd_pins axi_dma/s2mm_introut] [get_bd_pins cips/pl_ps_irq1]

# DMA memory masters into the NoC: three more slave ports on the NoC,
# each routed to the DDR controller.  (NoC port naming: S00_AXI.. are the
# PS ports the automation made; we append.)
set n_si [get_property CONFIG.NUM_SI $noc]
set_property CONFIG.NUM_SI [expr {$n_si + 3}] $noc
set_property CONFIG.NUM_CLKS [expr {[get_property CONFIG.NUM_CLKS $noc] + 1}] $noc
set si_sg   [format "S%02d_AXI" $n_si]
set si_mm2s [format "S%02d_AXI" [expr {$n_si + 1}]]
set si_s2mm [format "S%02d_AXI" [expr {$n_si + 2}]]
set noc_clk [format "aclk%d" [expr {[get_property CONFIG.NUM_CLKS $noc] - 1}]]
foreach si [list $si_sg $si_mm2s $si_s2mm] {
    # route each new slave port to memory controller port 0 (the DDR4)
    set_property -dict [list CONFIG.CONNECTIONS {MC_0 { read_bw {800} write_bw {800} read_avg_burst {4} write_avg_burst {4}} }] \
        [get_bd_intf_pins $noc/$si]
    set_property -dict [list CONFIG.CATEGORY {pl}] [get_bd_intf_pins $noc/$si]
}
set_property -dict [list CONFIG.ASSOCIATED_BUSIF "$si_sg:$si_mm2s:$si_s2mm"] [get_bd_pins $noc/$noc_clk]
connect_bd_net $pl_clk [get_bd_pins $noc/$noc_clk]
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_SG]   [get_bd_intf_pins $noc/$si_sg]
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_MM2S] [get_bd_intf_pins $noc/$si_mm2s]
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_S2MM] [get_bd_intf_pins $noc/$si_s2mm]

# -----------------------------------------------------------------------------
# 4. The receiver (module reference: the same RTL xsim ran, no IP packaging)
#    plus the pacer and the soft-bit widener.
# -----------------------------------------------------------------------------
create_bd_cell -type module -reference haifuraiya_rx_axi   rx
create_bd_cell -type module -reference axis_sample_pacer   pacer
create_bd_cell -type module -reference axis_softbit_widen  widen
set_property -dict [list CONFIG.OUT_WIDTH {8}] [get_bd_cells widen]

foreach c [list rx pacer widen] {
    connect_bd_net $pl_clk  [get_bd_pins $c/aclk]
    connect_bd_net $pl_rstn [get_bd_pins $c/aresetn]
}

# sample period: 5 clocks = 20 MSps at 100 MHz (the sim's SMP_PERIOD=5).
# A constant for the first build; make it a register when a second rate
# is needed.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 period_const
set_property -dict [list CONFIG.CONST_WIDTH {8} CONFIG.CONST_VAL {5}] [get_bd_cells period_const]
connect_bd_net [get_bd_pins period_const/dout] [get_bd_pins pacer/period]

# data path
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXIS_MM2S] [get_bd_intf_pins pacer/s_axis]
connect_bd_intf_net [get_bd_intf_pins pacer/m_axis]        [get_bd_intf_pins rx/s_axis_data]
connect_bd_intf_net [get_bd_intf_pins rx/m_axis_soft_bit]  [get_bd_intf_pins widen/s_axis]
connect_bd_intf_net [get_bd_intf_pins widen/m_axis]        [get_bd_intf_pins axi_dma/S_AXIS_S2MM]

# -----------------------------------------------------------------------------
# 4t. Tier 2 (VCK190_TIER=2): the ESIstream digital loopback between the pacer
#     and the receiver, around a real GTY quad in near-end PMA loopback.
#
#       pacer --> esi_link/esi (esi_link_hw: packer, Teledyne TX, [GT], Teledyne RX,
#                 reassembler, AXI-Lite registers at 0xA403_0000) --> rx
#
#     The GT cells and their wiring are Teledyne's gty_txrx_8lanes_64b block
#     design reduced to one quad and channels 0-1 (validated stand-alone in
#     gt_scratch.tcl, 2026-11-09; ESISTREAM_NOTES.md section 4.2 tells the story):
#       gt_bridge_ip 1.1   pass-through ("bypass") mode, 2 lanes, Teledyne's
#                          line-rate settings verbatim: 10.0 Gb/s, LCPLL,
#                          156.25 MHz refclk R0, RAW 64/64, buffered TX and RX
#       gt_quad_base 1.1   the GTY quad; refclk0 from an IBUFDS_GTE on the
#                          FMC1 GBTCLK/SI570 pins (xdc), ch0 tx/rxoutclk through
#                          BUFG_GTs as the user clocks of the bridge AND all four
#                          channels (validate insists on all four)
#     Only txdata_ext/rxdata_ext (63:0 of 128) carry data, as in Teledyne's
#     wrapper; the bridge's other *_ext ports stay at their defaults.
# -----------------------------------------------------------------------------
if {$tier == 2} {
    # the splice: break pacer -> rx and put the link in between
    delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins pacer/m_axis]]
    create_bd_cell -type module -reference esi_link_hw esi
    connect_bd_net $pl_clk  [get_bd_pins esi/aclk]
    connect_bd_net $pl_rstn [get_bd_pins esi/aresetn]
    connect_bd_intf_net [get_bd_intf_pins pacer/m_axis] [get_bd_intf_pins esi/s_axis]
    connect_bd_intf_net [get_bd_intf_pins esi/m_axis]   [get_bd_intf_pins rx/s_axis_data]

    # --- the transceiver: Teledyne's cells, one quad, two lanes
    set br [create_bd_cell -type ip -vlnv xilinx.com:ip:gt_bridge_ip:1.1 gt_bridge_ip]
    set lr0 "PRESET None RX_PAM_SEL NRZ TX_PAM_SEL NRZ RX_GRAY_BYP true TX_GRAY_BYP true RX_GRAY_LITTLEENDIAN true TX_GRAY_LITTLEENDIAN true RX_PRECODE_BYP true TX_PRECODE_BYP true RX_PRECODE_LITTLEENDIAN false TX_PRECODE_LITTLEENDIAN false INTERNAL_PRESET None GT_TYPE GTY GT_DIRECTION DUPLEX TX_LINE_RATE 10.0 TX_PLL_TYPE LCPLL TX_REFCLK_FREQUENCY 156.25 TX_ACTUAL_REFCLK_FREQUENCY 156.250000000000 TX_FRACN_ENABLED false TX_FRACN_NUMERATOR 0 TX_REFCLK_SOURCE R0 TX_DATA_ENCODING RAW TX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 64 TX_BUFFER_MODE 1 TX_BUFFER_BYPASS_MODE Fast_Sync TX_PIPM_ENABLE false TX_OUTCLK_SOURCE TXPLLREFCLK TXPROGDIV_FREQ_ENABLE false TXPROGDIV_FREQ_SOURCE LCPLL TXPROGDIV_FREQ_VAL 322.265625 TX_DIFF_SWING_EMPH_MODE CUSTOM TX_64B66B_SCRAMBLER false TX_64B66B_ENCODER false TX_64B66B_CRC false TX_RATE_GROUP A RX_LINE_RATE 10.0 RX_PLL_TYPE LCPLL RX_REFCLK_FREQUENCY 156.25 RX_ACTUAL_REFCLK_FREQUENCY 156.250000000000 RX_FRACN_ENABLED false RX_FRACN_NUMERATOR 0 RX_REFCLK_SOURCE R0 RX_DATA_DECODING RAW RX_USER_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64 RX_BUFFER_MODE 1 RX_OUTCLK_SOURCE RXPLLREFCLK RXPROGDIV_FREQ_ENABLE false RXPROGDIV_FREQ_SOURCE LCPLL RXPROGDIV_FREQ_VAL 322.265625 INS_LOSS_NYQ 20 RX_EQ_MODE AUTO RX_COUPLING AC RX_TERMINATION PROGRAMMABLE RX_RATE_GROUP A RX_TERMINATION_PROG_VALUE 800 RX_PPM_OFFSET 0 RX_64B66B_DESCRAMBLER false RX_64B66B_DECODER false RX_64B66B_CRC false OOB_ENABLE false RX_COMMA_ALIGN_WORD 1 RX_COMMA_SHOW_REALIGN_ENABLE true PCIE_ENABLE false TX_LANE_DESKEW_HDMI_ENABLE false RX_COMMA_P_ENABLE false RX_COMMA_M_ENABLE false RX_COMMA_DOUBLE_ENABLE false RX_COMMA_P_VAL 0101111100 RX_COMMA_M_VAL 1010000011 RX_COMMA_MASK 0000000000 RX_SLIDE_MODE OFF RX_SSC_PPM 0 RX_CB_NUM_SEQ 0 RX_CB_LEN_SEQ 1 RX_CB_MAX_SKEW 1 RX_CB_MAX_LEVEL 1 RX_CB_MASK_0_0 false RX_CB_VAL_0_0 00000000 RX_CB_K_0_0 false RX_CB_DISP_0_0 false RX_CB_MASK_0_1 false RX_CB_VAL_0_1 00000000 RX_CB_K_0_1 false RX_CB_DISP_0_1 false RX_CB_MASK_0_2 false RX_CB_VAL_0_2 00000000 RX_CB_K_0_2 false RX_CB_DISP_0_2 false RX_CB_MASK_0_3 false RX_CB_VAL_0_3 00000000 RX_CB_K_0_3 false RX_CB_DISP_0_3 false RX_CB_MASK_1_0 false RX_CB_VAL_1_0 00000000 RX_CB_K_1_0 false RX_CB_DISP_1_0 false RX_CB_MASK_1_1 false RX_CB_VAL_1_1 00000000 RX_CB_K_1_1 false RX_CB_DISP_1_1 false RX_CB_MASK_1_2 false RX_CB_VAL_1_2 00000000 RX_CB_K_1_2 false RX_CB_DISP_1_2 false RX_CB_MASK_1_3 false RX_CB_VAL_1_3 00000000 RX_CB_K_1_3 false RX_CB_DISP_1_3 false RX_CC_NUM_SEQ 0 RX_CC_LEN_SEQ 1 RX_CC_PERIODICITY 5000 RX_CC_KEEP_IDLE DISABLE RX_CC_PRECEDENCE ENABLE RX_CC_REPEAT_WAIT 0 RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000 RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00000000 RX_CC_K_0_0 false RX_CC_DISP_0_0 false RX_CC_MASK_0_1 false RX_CC_VAL_0_1 00000000 RX_CC_K_0_1 false RX_CC_DISP_0_1 false RX_CC_MASK_0_2 false RX_CC_VAL_0_2 00000000 RX_CC_K_0_2 false RX_CC_DISP_0_2 false RX_CC_MASK_0_3 false RX_CC_VAL_0_3 00000000 RX_CC_K_0_3 false RX_CC_DISP_0_3 false RX_CC_MASK_1_0 false RX_CC_VAL_1_0 00000000 RX_CC_K_1_0 false RX_CC_DISP_1_0 false RX_CC_MASK_1_1 false RX_CC_VAL_1_1 00000000 RX_CC_K_1_1 false RX_CC_DISP_1_1 false RX_CC_MASK_1_2 false RX_CC_VAL_1_2 00000000 RX_CC_K_1_2 false RX_CC_DISP_1_2 false RX_CC_MASK_1_3 false RX_CC_VAL_1_3 00000000 RX_CC_K_1_3 false RX_CC_DISP_1_3 false PCIE_USERCLK2_FREQ 250 PCIE_USERCLK_FREQ 250 RX_JTOL_FC 5.9988002 RX_JTOL_LF_SLOPE -20 RX_BUFFER_BYPASS_MODE Fast_Sync RX_BUFFER_BYPASS_MODE_LANE MULTI RX_BUFFER_RESET_ON_CB_CHANGE ENABLE RX_BUFFER_RESET_ON_COMMAALIGN DISABLE RX_BUFFER_RESET_ON_RATE_CHANGE ENABLE TX_BUFFER_RESET_ON_RATE_CHANGE ENABLE RESET_SEQUENCE_INTERVAL 0 RX_COMMA_PRESET NONE RX_COMMA_VALID_ONLY 0"
    set_property -dict [list CONFIG.BYPASS_MODE {true} CONFIG.IP_NO_OF_LANES {2} CONFIG.IP_LR0_SETTINGS $lr0] $br
    set quad [create_bd_cell -type ip -vlnv xilinx.com:ip:gt_quad_base:1.1 gt_quad_base]
    set_property CONFIG.REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1 HSCLK1_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1} $quad
    create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_tx
    create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_rx
    set dsbuf [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 gt_refclk_buf]
    set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $dsbuf

    foreach n {0 1} {
        connect_bd_intf_net [get_bd_intf_pins gt_bridge_ip/GT_TX$n] [get_bd_intf_pins gt_quad_base/TX${n}_GT_IP_Interface]
        connect_bd_intf_net [get_bd_intf_pins gt_bridge_ip/GT_RX$n] [get_bd_intf_pins gt_quad_base/RX${n}_GT_IP_Interface]
    }
    # reference clock: board pins (xdc) -> IBUFDS_GTE -> quad refclk0
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 esi_refclk
    set_property CONFIG.FREQ_HZ 156250000 [get_bd_intf_ports esi_refclk]
    connect_bd_intf_net [get_bd_intf_ports esi_refclk] [get_bd_intf_pins gt_refclk_buf/CLK_IN_D]
    connect_bd_net [get_bd_pins gt_refclk_buf/IBUF_OUT] [get_bd_pins gt_quad_base/GT_REFCLK0]
    # serial lanes to the FMC1 DP0/DP1 pins (xdc)
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 esi_gt
    connect_bd_intf_net [get_bd_intf_ports esi_gt] [get_bd_intf_pins gt_quad_base/GT_Serial]
    # user clocks: ch0 outclks -> BUFG_GT -> bridge, all four channels, and the link
    connect_bd_net [get_bd_pins gt_quad_base/ch0_txoutclk] [get_bd_pins bufg_gt_tx/outclk]
    connect_bd_net [get_bd_pins gt_quad_base/ch0_rxoutclk] [get_bd_pins bufg_gt_rx/outclk]
    connect_bd_net [get_bd_pins bufg_gt_tx/usrclk] [get_bd_pins gt_bridge_ip/gt_txusrclk] [get_bd_pins esi/tx_clk] \
        [get_bd_pins gt_quad_base/ch0_txusrclk] [get_bd_pins gt_quad_base/ch1_txusrclk] \
        [get_bd_pins gt_quad_base/ch2_txusrclk] [get_bd_pins gt_quad_base/ch3_txusrclk]
    connect_bd_net [get_bd_pins bufg_gt_rx/usrclk] [get_bd_pins gt_bridge_ip/gt_rxusrclk] [get_bd_pins esi/rx_clk] \
        [get_bd_pins gt_quad_base/ch0_rxusrclk] [get_bd_pins gt_quad_base/ch1_rxusrclk] \
        [get_bd_pins gt_quad_base/ch2_rxusrclk] [get_bd_pins gt_quad_base/ch3_rxusrclk]
    # APB3 clock (configuration interface) = the PL clock
    connect_bd_net $pl_clk [get_bd_pins gt_bridge_ip/apb3clk] [get_bd_pins gt_quad_base/apb3clk]
    # power good, straight across
    connect_bd_net [get_bd_pins gt_quad_base/gtpowergood] [get_bd_pins gt_bridge_ip/gtpowergood] [get_bd_pins esi/gt_powergood]
    # the two lanes' data, 128-bit bridge ports, 63:0 used
    connect_bd_net [get_bd_pins esi/gt_tx_data_ch0] [get_bd_pins gt_bridge_ip/ch0_txdata_ext]
    connect_bd_net [get_bd_pins esi/gt_tx_data_ch1] [get_bd_pins gt_bridge_ip/ch1_txdata_ext]
    connect_bd_net [get_bd_pins gt_bridge_ip/ch0_rxdata_ext] [get_bd_pins esi/gt_rx_data_ch0]
    connect_bd_net [get_bd_pins gt_bridge_ip/ch1_rxdata_ext] [get_bd_pins esi/gt_rx_data_ch1]
    # status to the registers, reset and loopback mode from them
    # PLL lock comes from the QUAD's HSCLK0 LCPLL (the one our two lanes use),
    # as in Teledyne's wrapper (hsclk*_lcplllock) -- NOT the bridge's
    # lcpll_lock_out, which never asserted in bypass mode on the board
    # (2026-11-10: resetdone high, user clocks at 156.25 MHz, lock_out low).
    # HSCLK1 is not in the two-lane reference-clock string; leave it out.
    connect_bd_net [get_bd_pins gt_quad_base/hsclk0_lcplllock] [get_bd_pins esi/gt_lcpll_lock]
    connect_bd_net [get_bd_pins gt_bridge_ip/tx_resetdone_out] [get_bd_pins esi/gt_tx_resetdone]
    connect_bd_net [get_bd_pins gt_bridge_ip/rx_resetdone_out] [get_bd_pins esi/gt_rx_resetdone]
    connect_bd_net [get_bd_pins gt_bridge_ip/link_status_out]  [get_bd_pins esi/gt_link_status]
    connect_bd_net [get_bd_pins esi/gt_reset]    [get_bd_pins gt_bridge_ip/gtreset_in]
    connect_bd_net [get_bd_pins esi/gt_loopback] [get_bd_pins gt_quad_base/ch0_loopback] [get_bd_pins gt_quad_base/ch1_loopback]
    # bridge inputs we do not use: rate select 0 (the one line rate), datapath resets 0
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 gt_zero4
    set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells gt_zero4]
    connect_bd_net [get_bd_pins gt_zero4/dout] [get_bd_pins gt_bridge_ip/rate_sel]
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 gt_zero1
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells gt_zero1]
    connect_bd_net [get_bd_pins gt_zero1/dout] [get_bd_pins gt_bridge_ip/reset_rx_datapath_in] \
        [get_bd_pins gt_bridge_ip/reset_rx_pll_and_datapath_in] [get_bd_pins gt_bridge_ip/reset_tx_datapath_in] \
        [get_bd_pins gt_bridge_ip/reset_tx_pll_and_datapath_in]
    puts "INFO: tier 2 -- ESIstream link and GTY quad inserted between pacer and rx"
}

# -----------------------------------------------------------------------------
# 4a. (debug build only) System ILA on the soft-bit path.
#     First hardware run, 2026-10-24: receiver locked, FRAMES_RECEIVED 24,
#     SOFT_DROPPED 0, yet the DMA S2MM channel sat running/not-idle with zero
#     bytes counted -- the FIFO->widen->DMA handshake never moved and nothing
#     software-visible says which side.  This probes the handshake into the
#     DMA (tvalid, tready, tlast, tdata) plus the receiver's frame-sync lock
#     and frame counter for context, so the first tvalid and what tready does
#     can be seen.
#     Enabled by VCK190_ILA=1 in the environment (make vck190-xsa-ila).
#
#     Native probes, not interface probes: Vivado 2022.2's AXIS ILA interface
#     monitor fails to elaborate on these interfaces ("can't read
#     net_name_int_TD_" -- no TKEEP/TDEST present).  Native probes need plain
#     nets, so the debug build inserts axis_softbit_tap (a wire with probe_*
#     copies) between the widener and the DMA.  Production build: no tap.
# -----------------------------------------------------------------------------
if {[info exists ::env(VCK190_ILA)] && $::env(VCK190_ILA) ne "0"} {
    # tap in: widen -> tap -> DMA
    delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins widen/m_axis]]
    create_bd_cell -type module -reference axis_softbit_tap tap
    set_property -dict [list CONFIG.DATA_WIDTH {8}] [get_bd_cells tap]
    connect_bd_net $pl_clk  [get_bd_pins tap/aclk]
    connect_bd_net $pl_rstn [get_bd_pins tap/aresetn]
    connect_bd_intf_net [get_bd_intf_pins widen/m_axis] [get_bd_intf_pins tap/s_axis]
    connect_bd_intf_net [get_bd_intf_pins tap/m_axis]   [get_bd_intf_pins axi_dma/S_AXIS_S2MM]

    # nets to probe: the four handshake copies + receiver context (native pins
    # on rx that are otherwise unconnected)
    set dbg_pins [list tap/probe_valid tap/probe_ready tap/probe_last tap/probe_data \
                       rx/frame_sync_locked rx/frames_received]
    set dbg_nets {}
    foreach p $dbg_pins {
        set pin [get_bd_pins $p]
        if {$pin eq ""} {
            error "ILA: no pin '$p'; pins on [file dirname $p]: [get_bd_pins [file dirname $p]/*]"
        }
        set nn  "dbg_[string map {/ _} $p]"
        set net [create_bd_net $nn]
        if {$net eq ""} { error "ILA: create_bd_net $nn returned nothing" }
        connect_bd_net -net $net $pin
        set_property HDL_ATTRIBUTE.DEBUG true $net
        lappend dbg_nets $net
    }
    # One AXIS ILA (Versal's system ILA) for all of them, PL clock.  On Versal
    # this automation also inserts the AXI debug hub the ILA needs.
    set dict {}
    foreach n $dbg_nets {
        lappend dict $n {PROBE_TYPE "Data and Trigger" CLK_SRC "/cips/pl0_ref_clk" AXIS_ILA "Auto"}
    }
    apply_bd_automation -rule xilinx.com:bd_rule:debug -dict $dict

    # 2026-10-25, second round.  The stream side measured clean (ILA: the FIFO
    # offers, the DMA accepted frame 1 and wrote it to DDR).  Count-terminated
    # receive descriptors complete (status written, channel idle); descriptors
    # ended by TLAST/end-of-packet wedge BEFORE the status write-back.  So:
    # interface probes on the DMA's two memory-side masters -- does the SG
    # port ever issue the status write for an EOF descriptor, and does the
    # S2MM data port get all its write responses?  Full AXI4 interface
    # monitors (the elaboration bug above was the AXI-Stream flavour).
    set axi_dict {}
    foreach ifp [list axi_dma/M_AXI_SG axi_dma/M_AXI_S2MM] {
        set n [get_bd_intf_nets -of_objects [get_bd_intf_pins $ifp]]
        set_property HDL_ATTRIBUTE.DEBUG true $n
        lappend axi_dict $n {AXI_R_ADDRESS "Data and Trigger" AXI_R_DATA "Data and Trigger" AXI_W_ADDRESS "Data and Trigger" AXI_W_DATA "Data and Trigger" AXI_W_RESPONSE "Data and Trigger" CLK_SRC "/cips/pl0_ref_clk" AXIS_ILA "Auto" APC_EN "0"}
    }
    apply_bd_automation -rule xilinx.com:bd_rule:debug -dict $axi_dict

    foreach ila [get_bd_cells -filter {VLNV =~ "xilinx.com:ip:axis_ila:*"}] {
        # 4096 samples at 100 MHz = 41 us: the AXI monitors are wide, keep the
        # BRAM bill modest; a descriptor's whole data+status phase fits.
        set_property CONFIG.C_DATA_DEPTH {4096} $ila
        puts "INFO: AXIS ILA $ila (native probes: $dbg_pins; AXI: M_AXI_SG, M_AXI_S2MM), depth 4096"
    }
}

# -----------------------------------------------------------------------------
# 5. Control plane: CIPS M_AXI_FPD -> smartconnect -> three AXI-Lite slaves
# -----------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI [expr {$tier == 2 ? 4 : 3}]] [get_bd_cells ctrl_sc]
connect_bd_net $pl_clk  [get_bd_pins ctrl_sc/aclk]
connect_bd_net $pl_rstn [get_bd_pins ctrl_sc/aresetn]
connect_bd_net $pl_clk  [get_bd_pins cips/m_axi_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins cips/M_AXI_FPD]  [get_bd_intf_pins ctrl_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M00_AXI] [get_bd_intf_pins axi_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M01_AXI] [get_bd_intf_pins rx/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] [get_bd_intf_pins rx/s_axi_demod]
if {$tier == 2} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M03_AXI] [get_bd_intf_pins esi/s_axi]
    # one box in the diagram for everything tier 2 added (after the last
    # connection to it, so the hierarchy pins are made for us)
    group_bd_cells esi_link [get_bd_cells {esi gt_bridge_ip gt_quad_base bufg_gt_tx bufg_gt_rx gt_refclk_buf gt_zero4 gt_zero1}]
}

# -----------------------------------------------------------------------------
# 6. Addresses.  PL peripherals in the FPD PL window (0xA400_0000 up on
#    Versal, 64 KB each); DMA masters see the whole DDR range.
#    These three offsets are the public addresses the software uses:
#      axi_dma   0xA400_0000
#      rx ctrl   0xA401_0000   (channelizer registers, 4 KB used)
#      rx demod  0xA402_0000   (demod registers, 4 KB used)
#      esi link  0xA403_0000   (tier 2 only: ESIstream link registers, 64 B used)
# -----------------------------------------------------------------------------
set fpd [get_bd_addr_spaces cips/M_AXI_FPD]
# control plane: fixed offsets, slave segments named by their own paths, so
# Vivado's mapped-segment names don't matter; the foreach prints the final
# map into the log (what the device tree and opv_play use)
assign_bd_address -target_address_space $fpd -offset 0xA4000000 -range 64K [get_bd_addr_segs axi_dma/S_AXI_LITE/Reg]
assign_bd_address -target_address_space $fpd -offset 0xA4010000 -range 64K [get_bd_addr_segs rx/s_axi_ctrl/*]
assign_bd_address -target_address_space $fpd -offset 0xA4020000 -range 64K [get_bd_addr_segs rx/s_axi_demod/*]
if {$tier == 2} {
    assign_bd_address -target_address_space $fpd -offset 0xA4030000 -range 64K [get_bd_addr_segs esi_link/esi/s_axi/*]
}
# everything else (the DMA's three masters onto the DDR) as Vivado sees fit
assign_bd_address
foreach s [get_bd_addr_segs -of_objects $fpd] {
    puts "INFO: M_AXI_FPD  $s  offset [get_property OFFSET $s]  range [get_property RANGE $s]"
}

regenerate_bd_layout
validate_bd_design
save_bd_design
puts "INFO: vck190 playback BD built: DMA 0xA4000000, rx ctrl 0xA4010000, rx demod 0xA4020000[expr {$tier == 2 ? ", esi link 0xA4030000" : ""}]"
