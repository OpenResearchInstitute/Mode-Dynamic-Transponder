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
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] [get_bd_cells ctrl_sc]
connect_bd_net $pl_clk  [get_bd_pins ctrl_sc/aclk]
connect_bd_net $pl_rstn [get_bd_pins ctrl_sc/aresetn]
connect_bd_net $pl_clk  [get_bd_pins cips/m_axi_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins cips/M_AXI_FPD]  [get_bd_intf_pins ctrl_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M00_AXI] [get_bd_intf_pins axi_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M01_AXI] [get_bd_intf_pins rx/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] [get_bd_intf_pins rx/s_axi_demod]

# -----------------------------------------------------------------------------
# 6. Addresses.  PL peripherals in the FPD PL window (0xA400_0000 up on
#    Versal, 64 KB each); DMA masters see the whole DDR range.
#    These three offsets are the public addresses the software uses:
#      axi_dma   0xA400_0000
#      rx ctrl   0xA401_0000   (channelizer registers, 4 KB used)
#      rx demod  0xA402_0000   (demod registers, 4 KB used)
# -----------------------------------------------------------------------------
set fpd [get_bd_addr_spaces cips/M_AXI_FPD]
# control plane: fixed offsets, slave segments named by their own paths, so
# Vivado's mapped-segment names don't matter; the foreach prints the final
# map into the log (what the device tree and opv_play use)
assign_bd_address -target_address_space $fpd -offset 0xA4000000 -range 64K [get_bd_addr_segs axi_dma/S_AXI_LITE/Reg]
assign_bd_address -target_address_space $fpd -offset 0xA4010000 -range 64K [get_bd_addr_segs rx/s_axi_ctrl/*]
assign_bd_address -target_address_space $fpd -offset 0xA4020000 -range 64K [get_bd_addr_segs rx/s_axi_demod/*]
# everything else (the DMA's three masters onto the DDR) as Vivado sees fit
assign_bd_address
foreach s [get_bd_addr_segs -of_objects $fpd] {
    puts "INFO: M_AXI_FPD  $s  offset [get_property OFFSET $s]  range [get_property RANGE $s]"
}

regenerate_bd_layout
validate_bd_design
save_bd_design
puts "INFO: vck190 playback BD built: DMA 0xA4000000, rx ctrl 0xA4010000, rx demod 0xA4020000"
