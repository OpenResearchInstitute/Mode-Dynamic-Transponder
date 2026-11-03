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
