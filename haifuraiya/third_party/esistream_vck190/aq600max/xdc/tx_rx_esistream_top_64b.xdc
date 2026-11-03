###############################################################################
# User Configuration
###############################################################################

###############################################################################
# IOs constraints
###############################################################################

# 156.25 MHz
create_clock -period 6.400 -name clk_mgtref -waveform {0.000 3.200} [get_ports sso_p]
set_property PACKAGE_PIN M15 [get_ports sso_p]
set_property PACKAGE_PIN M14 [get_ports sso_n]

## RX
## TX
set_property PACKAGE_PIN AB2 [get_ports {rxp[0]}]
set_property PACKAGE_PIN AB1 [get_ports {rxn[0]}]
set_property PACKAGE_PIN AB7 [get_ports {txp[0]}]
set_property PACKAGE_PIN AB6 [get_ports {txn[0]}]
set_property PACKAGE_PIN AA4 [get_ports {rxp[1]}]
set_property PACKAGE_PIN AA3 [get_ports {rxn[1]}]
set_property PACKAGE_PIN AA9 [get_ports {txp[1]}]
set_property PACKAGE_PIN AA8 [get_ports {txn[1]}]
set_property PACKAGE_PIN Y2 [get_ports {rxp[2]}]
set_property PACKAGE_PIN Y1 [get_ports {rxn[2]}]
set_property PACKAGE_PIN Y7 [get_ports {txp[2]}]
set_property PACKAGE_PIN Y6 [get_ports {txn[2]}]
set_property PACKAGE_PIN W4 [get_ports {rxp[3]}]
set_property PACKAGE_PIN W3 [get_ports {rxn[3]}]
set_property PACKAGE_PIN W9 [get_ports {txp[3]}]
set_property PACKAGE_PIN W8 [get_ports {txn[3]}]
set_property PACKAGE_PIN V2 [get_ports {rxp[4]}]
set_property PACKAGE_PIN V1 [get_ports {rxn[4]}]
set_property PACKAGE_PIN V7 [get_ports {txp[4]}]
set_property PACKAGE_PIN V6 [get_ports {txn[4]}]
set_property PACKAGE_PIN U4 [get_ports {rxp[5]}]
set_property PACKAGE_PIN U3 [get_ports {rxn[5]}]
set_property PACKAGE_PIN U9 [get_ports {txp[5]}]
set_property PACKAGE_PIN U8 [get_ports {txn[5]}]
set_property PACKAGE_PIN T2 [get_ports {rxp[6]}]
set_property PACKAGE_PIN T1 [get_ports {rxn[6]}]
set_property PACKAGE_PIN T7 [get_ports {txp[6]}]
set_property PACKAGE_PIN T6 [get_ports {txn[6]}]
set_property PACKAGE_PIN R4 [get_ports {rxp[7]}]
set_property PACKAGE_PIN R3 [get_ports {rxn[7]}]
set_property PACKAGE_PIN R9 [get_ports {txp[7]}]
set_property PACKAGE_PIN R8 [get_ports {txn[7]}]

# PL system clock:
create_clock -period 6.400 -name HSDP_SI570_CLK_C_P [get_ports HSDP_SI570_CLK_C_P]
set_property PACKAGE_PIN J39 [get_ports HSDP_SI570_CLK_C_P]
set_property PACKAGE_PIN J40 [get_ports HSDP_SI570_CLK_C_N]

# PL USER GPIO
set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_LED[*]}]
set_property PACKAGE_PIN H34 [get_ports {GPIO_LED[0]}]
set_property PACKAGE_PIN J33 [get_ports {GPIO_LED[1]}]
set_property PACKAGE_PIN K36 [get_ports {GPIO_LED[2]}]
set_property PACKAGE_PIN L35 [get_ports {GPIO_LED[3]}]

set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_SW[*]}]
set_property PACKAGE_PIN J35 [get_ports {GPIO_SW[0]}]
set_property PACKAGE_PIN J34 [get_ports {GPIO_SW[1]}]
set_property PACKAGE_PIN H37 [get_ports {GPIO_SW[2]}]
set_property PACKAGE_PIN H36 [get_ports {GPIO_SW[3]}]

set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_PB[*]}]
set_property PACKAGE_PIN G37 [get_ports {GPIO_PB[0]}]
set_property PACKAGE_PIN G36 [get_ports {GPIO_PB[1]}]

# PL UART
set_property IOSTANDARD LVCMOS18 [get_ports UART1_TXD_HDIO_UART_RX]
set_property PACKAGE_PIN K33 [get_ports UART1_TXD_HDIO_UART_RX]
set_property IOSTANDARD LVCMOS18 [get_ports UART1_RXD_HDIO_UART_TX]
set_property PACKAGE_PIN L33 [get_ports UART1_RXD_HDIO_UART_TX]

###############################################################################
# EV12AQ600 FMC
###############################################################################
set_property IOSTANDARD LVCMOS15 [get_ports {m2c_cfg[*]}]
set_property PACKAGE_PIN BF18 [get_ports {m2c_cfg[1]}]
set_property PACKAGE_PIN BG18 [get_ports {m2c_cfg[2]}]
set_property PACKAGE_PIN BF16 [get_ports {m2c_cfg[3]}]
set_property PACKAGE_PIN BG16 [get_ports {m2c_cfg[4]}]

set_property IOSTANDARD LVCMOS15 [get_ports {c2m_led[*]}]
set_property PACKAGE_PIN AY22 [get_ports {c2m_led[1]}]
set_property PACKAGE_PIN AY23 [get_ports {c2m_led[2]}]
set_property PACKAGE_PIN BA17 [get_ports {c2m_led[3]}]
set_property PACKAGE_PIN BA16 [get_ports {c2m_led[4]}]

set_property IOSTANDARD LVCMOS15 [get_ports spare_8_uart_tx]
set_property PACKAGE_PIN BG25 [get_ports spare_8_uart_tx]
set_property IOSTANDARD LVCMOS15 [get_ports spare_9_uart_rx]
set_property PACKAGE_PIN AU23 [get_ports spare_9_uart_rx]

set_property IOSTANDARD LVCMOS15 [get_ports {spare[*]}]
set_property PACKAGE_PIN BE22 [get_ports {spare[1]}]
set_property PACKAGE_PIN BF22 [get_ports {spare[2]}]
set_property PACKAGE_PIN BD25 [get_ports {spare[3]}]
set_property PACKAGE_PIN BC25 [get_ports {spare[4]}]
set_property PACKAGE_PIN BG20 [get_ports {spare[5]}]
set_property PACKAGE_PIN BE25 [get_ports {spare[6]}]
set_property PACKAGE_PIN BC20 [get_ports {spare[7]}]

set_property IOSTANDARD LVCMOS15 [get_ports fpga_ref_clk]
set_property PACKAGE_PIN BD23 [get_ports fpga_ref_clk]

set_property IOSTANDARD LVCMOS15 [get_ports ref_sel_ext]
set_property PACKAGE_PIN AV22 [get_ports ref_sel_ext]

set_property IOSTANDARD LVCMOS15 [get_ports ref_sel]
set_property PACKAGE_PIN AW21 [get_ports ref_sel]

set_property IOSTANDARD LVCMOS15 [get_ports clk_sel]
set_property PACKAGE_PIN BC22 [get_ports clk_sel]

set_property IOSTANDARD LVCMOS15 [get_ports synco_sel]
set_property PACKAGE_PIN BC21 [get_ports synco_sel]

set_property IOSTANDARD LVCMOS15 [get_ports sync_sel]
set_property PACKAGE_PIN BG21 [get_ports sync_sel]

set_property IOSTANDARD LVCMOS15 [get_ports hmc1031_d1]
set_property PACKAGE_PIN BF24 [get_ports hmc1031_d1]

set_property IOSTANDARD LVCMOS15 [get_ports hmc1031_d0]
set_property PACKAGE_PIN BG23 [get_ports hmc1031_d0]

set_property IOSTANDARD LVCMOS15 [get_ports pll_muxout]
set_property PACKAGE_PIN BF21 [get_ports pll_muxout]

set_property IOSTANDARD LVDS15 [get_ports clkoutB_p]
set_property PACKAGE_PIN BB16 [get_ports clkoutB_p]
set_property PACKAGE_PIN BC16 [get_ports clkoutB_n]

set_property IOSTANDARD LVCMOS15 [get_ports rstn]
set_property PACKAGE_PIN BG24 [get_ports rstn]

set_property IOSTANDARD LVCMOS15 [get_ports adc_sclk]
set_property PACKAGE_PIN BC23 [get_ports adc_sclk]

set_property IOSTANDARD LVCMOS15 [get_ports adc_cs_u]
set_property PACKAGE_PIN BE24 [get_ports adc_cs_u]

set_property IOSTANDARD LVCMOS15 [get_ports adc_mosi]
set_property PACKAGE_PIN BE20 [get_ports adc_mosi]

set_property IOSTANDARD LVCMOS15 [get_ports adc_miso]
set_property PACKAGE_PIN BE21 [get_ports adc_miso]

set_property IOSTANDARD LVCMOS15 [get_ports csn_pll]
set_property PACKAGE_PIN BF23 [get_ports csn_pll]

set_property IOSTANDARD LVCMOS15 [get_ports sclk]
set_property PACKAGE_PIN AU24 [get_ports sclk]

set_property IOSTANDARD LVCMOS15 [get_ports miso]
set_property PACKAGE_PIN BD20 [get_ports miso]

set_property IOSTANDARD LVCMOS15 [get_ports mosi]
set_property PACKAGE_PIN BF17 [get_ports mosi]

set_property IOSTANDARD LVCMOS15 [get_ports csn]
set_property PACKAGE_PIN BE16 [get_ports csn]

set_property IOSTANDARD LVDS15 [get_ports synctrig_p]
set_property PACKAGE_PIN AU21 [get_ports synctrig_p]
set_property PACKAGE_PIN AV21 [get_ports synctrig_n]

set_property IOSTANDARD LVDS15 [get_ports synco_p]
set_property PACKAGE_PIN BB18 [get_ports synco_p]
set_property PACKAGE_PIN BC17 [get_ports synco_n]

###############################################################################
# clocks interaction
###############################################################################

set_false_path -from [get_clocks ch0_rxoutclk] -to [get_clocks clkout1_primitive]
set_false_path -from [get_clocks clkout1_primitive] -to [get_clocks ch0_rxoutclk]
#
set_false_path -from [get_clocks ch0_txoutclk] -to [get_clocks clkout1_primitive]
set_false_path -from [get_clocks clkout1_primitive] -to [get_clocks ch0_txoutclk]
#
set_false_path -from [get_clocks clk_mgtref] -to [get_clocks clkout1_primitive]
set_false_path -from [get_clocks clkout1_primitive] -to [get_clocks clk_mgtref]
#


