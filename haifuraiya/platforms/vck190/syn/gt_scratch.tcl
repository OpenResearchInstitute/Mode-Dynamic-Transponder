################################################################################
# gt_scratch.tcl -- a 2-lane GTY transceiver pair for the VC1902, built BY HAND
# from Teledyne's block design (esistream_vck190/xm107/src_bd/
# gty_txrx_8lanes_64b.bd), reduced to one quad and channels 0-1.  Batch mode,
# nothing synthesized.  No block automation: the 2022.2 rule names for the GT
# bridge are not known to us, so every cell and wire below is Teledyne's,
# transcribed.  Outputs, next to this script:
#   gt_2lanes_bd.tcl    write_bd_tcl of the validated design
#   gt_2lanes_pins.txt  every pin of every cell (direction, width): the place
#                       to look for ch0_loopback / ch1_loopback on the quad
#
# Usage (Vivado 2022.2 on PATH; ~2-5 minutes):
#   vivado -mode batch -nojournal -log gt_scratch.log -source gt_scratch.tcl
################################################################################
set part "xcvc1902-vsva2197-2MP-e-S"
set outdir [file dirname [file normalize [info script]]]

create_project -in_memory -part $part
set_property board_part xilinx.com:vck190:part0:2.2 [current_project]
create_bd_design gt_scratch

# --- bridge: Teledyne's line-rate string verbatim, pass-through, 2 lanes -------
set br [create_bd_cell -type ip -vlnv xilinx.com:ip:gt_bridge_ip:1.1 gt_bridge_ip_0]
set lr0 "PRESET None RX_PAM_SEL NRZ TX_PAM_SEL NRZ RX_GRAY_BYP true TX_GRAY_BYP true RX_GRAY_LITTLEENDIAN true TX_GRAY_LITTLEENDIAN true RX_PRECODE_BYP true TX_PRECODE_BYP true RX_PRECODE_LITTLEENDIAN false TX_PRECODE_LITTLEENDIAN false INTERNAL_PRESET None GT_TYPE GTY GT_DIRECTION DUPLEX TX_LINE_RATE 10.0 TX_PLL_TYPE LCPLL TX_REFCLK_FREQUENCY 156.25 TX_ACTUAL_REFCLK_FREQUENCY 156.250000000000 TX_FRACN_ENABLED false TX_FRACN_NUMERATOR 0 TX_REFCLK_SOURCE R0 TX_DATA_ENCODING RAW TX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 64 TX_BUFFER_MODE 1 TX_BUFFER_BYPASS_MODE Fast_Sync TX_PIPM_ENABLE false TX_OUTCLK_SOURCE TXPLLREFCLK TXPROGDIV_FREQ_ENABLE false TXPROGDIV_FREQ_SOURCE LCPLL TXPROGDIV_FREQ_VAL 322.265625 TX_DIFF_SWING_EMPH_MODE CUSTOM TX_64B66B_SCRAMBLER false TX_64B66B_ENCODER false TX_64B66B_CRC false TX_RATE_GROUP A RX_LINE_RATE 10.0 RX_PLL_TYPE LCPLL RX_REFCLK_FREQUENCY 156.25 RX_ACTUAL_REFCLK_FREQUENCY 156.250000000000 RX_FRACN_ENABLED false RX_FRACN_NUMERATOR 0 RX_REFCLK_SOURCE R0 RX_DATA_DECODING RAW RX_USER_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64 RX_BUFFER_MODE 1 RX_OUTCLK_SOURCE RXPLLREFCLK RXPROGDIV_FREQ_ENABLE false RXPROGDIV_FREQ_SOURCE LCPLL RXPROGDIV_FREQ_VAL 322.265625 INS_LOSS_NYQ 20 RX_EQ_MODE AUTO RX_COUPLING AC RX_TERMINATION PROGRAMMABLE RX_RATE_GROUP A RX_TERMINATION_PROG_VALUE 800 RX_PPM_OFFSET 0 RX_64B66B_DESCRAMBLER false RX_64B66B_DECODER false RX_64B66B_CRC false OOB_ENABLE false RX_COMMA_ALIGN_WORD 1 RX_COMMA_SHOW_REALIGN_ENABLE true PCIE_ENABLE false TX_LANE_DESKEW_HDMI_ENABLE false RX_COMMA_P_ENABLE false RX_COMMA_M_ENABLE false RX_COMMA_DOUBLE_ENABLE false RX_COMMA_P_VAL 0101111100 RX_COMMA_M_VAL 1010000011 RX_COMMA_MASK 0000000000 RX_SLIDE_MODE OFF RX_SSC_PPM 0 RX_CB_NUM_SEQ 0 RX_CB_LEN_SEQ 1 RX_CB_MAX_SKEW 1 RX_CB_MAX_LEVEL 1 RX_CB_MASK_0_0 false RX_CB_VAL_0_0 00000000 RX_CB_K_0_0 false RX_CB_DISP_0_0 false RX_CB_MASK_0_1 false RX_CB_VAL_0_1 00000000 RX_CB_K_0_1 false RX_CB_DISP_0_1 false RX_CB_MASK_0_2 false RX_CB_VAL_0_2 00000000 RX_CB_K_0_2 false RX_CB_DISP_0_2 false RX_CB_MASK_0_3 false RX_CB_VAL_0_3 00000000 RX_CB_K_0_3 false RX_CB_DISP_0_3 false RX_CB_MASK_1_0 false RX_CB_VAL_1_0 00000000 RX_CB_K_1_0 false RX_CB_DISP_1_0 false RX_CB_MASK_1_1 false RX_CB_VAL_1_1 00000000 RX_CB_K_1_1 false RX_CB_DISP_1_1 false RX_CB_MASK_1_2 false RX_CB_VAL_1_2 00000000 RX_CB_K_1_2 false RX_CB_DISP_1_2 false RX_CB_MASK_1_3 false RX_CB_VAL_1_3 00000000 RX_CB_K_1_3 false RX_CB_DISP_1_3 false RX_CC_NUM_SEQ 0 RX_CC_LEN_SEQ 1 RX_CC_PERIODICITY 5000 RX_CC_KEEP_IDLE DISABLE RX_CC_PRECEDENCE ENABLE RX_CC_REPEAT_WAIT 0 RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000 RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00000000 RX_CC_K_0_0 false RX_CC_DISP_0_0 false RX_CC_MASK_0_1 false RX_CC_VAL_0_1 00000000 RX_CC_K_0_1 false RX_CC_DISP_0_1 false RX_CC_MASK_0_2 false RX_CC_VAL_0_2 00000000 RX_CC_K_0_2 false RX_CC_DISP_0_2 false RX_CC_MASK_0_3 false RX_CC_VAL_0_3 00000000 RX_CC_K_0_3 false RX_CC_DISP_0_3 false RX_CC_MASK_1_0 false RX_CC_VAL_1_0 00000000 RX_CC_K_1_0 false RX_CC_DISP_1_0 false RX_CC_MASK_1_1 false RX_CC_VAL_1_1 00000000 RX_CC_K_1_1 false RX_CC_DISP_1_1 false RX_CC_MASK_1_2 false RX_CC_VAL_1_2 00000000 RX_CC_K_1_2 false RX_CC_DISP_1_2 false RX_CC_MASK_1_3 false RX_CC_VAL_1_3 00000000 RX_CC_K_1_3 false RX_CC_DISP_1_3 false PCIE_USERCLK2_FREQ 250 PCIE_USERCLK_FREQ 250 RX_JTOL_FC 5.9988002 RX_JTOL_LF_SLOPE -20 RX_BUFFER_BYPASS_MODE Fast_Sync RX_BUFFER_BYPASS_MODE_LANE MULTI RX_BUFFER_RESET_ON_CB_CHANGE ENABLE RX_BUFFER_RESET_ON_COMMAALIGN DISABLE RX_BUFFER_RESET_ON_RATE_CHANGE ENABLE TX_BUFFER_RESET_ON_RATE_CHANGE ENABLE RESET_SEQUENCE_INTERVAL 0 RX_COMMA_PRESET NONE RX_COMMA_VALID_ONLY 0"
set_property -dict [list CONFIG.BYPASS_MODE {true} CONFIG.IP_NO_OF_LANES {2} CONFIG.IP_LR0_SETTINGS $lr0] $br

# --- quad side, Teledyne's cells (one quad instead of two) -----------------------
set quad [create_bd_cell -type ip -vlnv xilinx.com:ip:gt_quad_base:1.1 gt_quad_base]
set_property CONFIG.REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1 HSCLK1_LCPLLGTREFCLK0 refclk_PROT0_R0_156.25_MHz_unique1} $quad
set bufg_rx [create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_rx]
set bufg_tx [create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_tx]
set dsbuf   [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf]
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $dsbuf

# bridge <-> quad lane interfaces (Teledyne: GT_TXn -> TXn_GT_IP_Interface)
foreach n {0 1} {
    connect_bd_intf_net [get_bd_intf_pins gt_bridge_ip_0/GT_TX$n] [get_bd_intf_pins gt_quad_base/TX${n}_GT_IP_Interface]
    connect_bd_intf_net [get_bd_intf_pins gt_bridge_ip_0/GT_RX$n] [get_bd_intf_pins gt_quad_base/RX${n}_GT_IP_Interface]
}

# reference clock: external diff pair -> IBUFDS_GTE -> quad GT_REFCLK0
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_refclk0
set_property CONFIG.FREQ_HZ 156250000 [get_bd_intf_ports gt_refclk0]
connect_bd_intf_net [get_bd_intf_ports gt_refclk0] [get_bd_intf_pins util_ds_buf/CLK_IN_D]
connect_bd_net [get_bd_pins util_ds_buf/IBUF_OUT] [get_bd_pins gt_quad_base/GT_REFCLK0]

# user clocks: ch0 outclks -> BUFG_GT -> bridge usrclk + every channel usrclk
connect_bd_net [get_bd_pins gt_quad_base/ch0_txoutclk] [get_bd_pins bufg_gt_tx/outclk]
connect_bd_net [get_bd_pins gt_quad_base/ch0_rxoutclk] [get_bd_pins bufg_gt_rx/outclk]
# (all four channels of the quad want a user clock even though only 0-1 carry
#  lanes -- validate_bd_design insists; the unused two just idle on the same clock)
connect_bd_net [get_bd_pins bufg_gt_tx/usrclk] [get_bd_pins gt_bridge_ip_0/gt_txusrclk] \
    [get_bd_pins gt_quad_base/ch0_txusrclk] [get_bd_pins gt_quad_base/ch1_txusrclk] \
    [get_bd_pins gt_quad_base/ch2_txusrclk] [get_bd_pins gt_quad_base/ch3_txusrclk]
connect_bd_net [get_bd_pins bufg_gt_rx/usrclk] [get_bd_pins gt_bridge_ip_0/gt_rxusrclk] \
    [get_bd_pins gt_quad_base/ch0_rxusrclk] [get_bd_pins gt_quad_base/ch1_rxusrclk] \
    [get_bd_pins gt_quad_base/ch2_rxusrclk] [get_bd_pins gt_quad_base/ch3_rxusrclk]

# power good: one quad, so straight across (Teledyne AND-ed two quads)
connect_bd_net [get_bd_pins gt_quad_base/gtpowergood] [get_bd_pins gt_bridge_ip_0/gtpowergood]

# serial pins and the APB3 clock out to the boundary
make_bd_intf_pins_external [get_bd_intf_pins gt_quad_base/GT_Serial]
create_bd_port -dir I -type clk -freq_hz 100000000 apb3clk
connect_bd_net [get_bd_ports apb3clk] [get_bd_pins gt_bridge_ip_0/apb3clk] [get_bd_pins gt_quad_base/apb3clk]

# the bridge's control/status, as Teledyne had them: external
foreach p {gt_reset_gt_bridge_ip_0:gtreset_in rate_sel:rate_sel reset_rx_datapath_in:reset_rx_datapath_in \
           reset_rx_pll_and_datapath_in:reset_rx_pll_and_datapath_in reset_tx_datapath_in:reset_tx_datapath_in \
           reset_tx_pll_and_datapath_in:reset_tx_pll_and_datapath_in} {
    lassign [split $p :] port pin
    make_bd_pins_external [get_bd_pins gt_bridge_ip_0/$pin]
}
foreach pin {link_status_out tx_resetdone_out rx_resetdone_out txusrclk_out rxusrclk_out lcpll_lock_out rpll_lock_out} {
    catch { make_bd_pins_external [get_bd_pins gt_bridge_ip_0/$pin] }
}
foreach pin {hsclk0_lcplllock hsclk1_lcplllock} {
    catch { make_bd_pins_external [get_bd_pins gt_quad_base/$pin] }
}

# --- the question: does the quad expose loopback control? ----------------------
set lb [get_bd_pins -quiet -of_objects $quad -filter {NAME =~ "*loopback*"}]
puts "LOOPBACK PINS ON QUAD: $lb"
# only the two lanes we use; "010" = near-end PMA loopback, driven by the register block later
foreach p {ch0_loopback ch1_loopback} { catch { make_bd_pins_external [get_bd_pins gt_quad_base/$p] } }

# --- validate, report, export -----------------------------------------------------
set vrc [catch { validate_bd_design } vmsg]
puts "validate_bd_design: [expr {$vrc ? "FAILED: $vmsg" : "OK"}]"

set fh [open "$outdir/gt_2lanes_pins.txt" w]
foreach c [get_bd_cells] {
    puts $fh "== cell $c  [get_property VLNV $c]"
    foreach p [lsort [get_bd_pins -of_objects $c]] {
        set w ""
        catch { set w "\[[get_property LEFT $p]:[get_property RIGHT $p]\]" }
        puts $fh [format "   %-50s %-4s %s" [get_property NAME $p] [get_property DIR $p] $w]
    }
    foreach ip [lsort [get_bd_intf_pins -of_objects $c]] {
        puts $fh [format "   %-50s %-6s %s" [get_property NAME $ip] [get_property MODE $ip] [get_property VLNV $ip]]
    }
}
puts $fh "== external ports"
foreach p [get_bd_ports] { puts $fh "   $p [get_property DIR $p]" }
foreach ip [get_bd_intf_ports -quiet] { puts $fh "   $ip [get_property MODE $ip] [get_property VLNV $ip]" }
close $fh

write_bd_tcl -force "$outdir/gt_2lanes_bd.tcl"
puts "wrote $outdir/gt_2lanes_bd.tcl and $outdir/gt_2lanes_pins.txt"
close_project
