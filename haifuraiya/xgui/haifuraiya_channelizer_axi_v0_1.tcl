# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  set C_S_AXI_CTRL_ADDR_WIDTH [ipgui::add_param $IPINST -name "C_S_AXI_CTRL_ADDR_WIDTH" -parent ${Page_0}]
  set_property tooltip {AXI-Lite slave address width in bits. Default 12 bits = 4 KB address space, sufficient for all control and CHANNEL_POWER registers.} ${C_S_AXI_CTRL_ADDR_WIDTH}
  set POWER_ALPHA_W [ipgui::add_param $IPINST -name "POWER_ALPHA_W" -parent ${Page_0}]
  set_property tooltip {Bit width of the EMA alpha values (defaults to 18 bits, providing ~2^-17 resolution on the alpha coefficient).} ${POWER_ALPHA_W}


}

proc update_PARAM_VALUE.ACCUM_WIDTH { PARAM_VALUE.ACCUM_WIDTH } {
	# Procedure called to update ACCUM_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ACCUM_WIDTH { PARAM_VALUE.ACCUM_WIDTH } {
	# Procedure called to validate ACCUM_WIDTH
	return true
}

proc update_PARAM_VALUE.COEFF_WIDTH { PARAM_VALUE.COEFF_WIDTH } {
	# Procedure called to update COEFF_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.COEFF_WIDTH { PARAM_VALUE.COEFF_WIDTH } {
	# Procedure called to validate COEFF_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_CTRL_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_CTRL_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to update DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to validate DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.M_DECIMATION { PARAM_VALUE.M_DECIMATION } {
	# Procedure called to update M_DECIMATION when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.M_DECIMATION { PARAM_VALUE.M_DECIMATION } {
	# Procedure called to validate M_DECIMATION
	return true
}

proc update_PARAM_VALUE.N_CHANNELS { PARAM_VALUE.N_CHANNELS } {
	# Procedure called to update N_CHANNELS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.N_CHANNELS { PARAM_VALUE.N_CHANNELS } {
	# Procedure called to validate N_CHANNELS
	return true
}

proc update_PARAM_VALUE.POWER_ALPHA_W { PARAM_VALUE.POWER_ALPHA_W } {
	# Procedure called to update POWER_ALPHA_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.POWER_ALPHA_W { PARAM_VALUE.POWER_ALPHA_W } {
	# Procedure called to validate POWER_ALPHA_W
	return true
}

proc update_PARAM_VALUE.TAPS_PER_BRANCH { PARAM_VALUE.TAPS_PER_BRANCH } {
	# Procedure called to update TAPS_PER_BRANCH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TAPS_PER_BRANCH { PARAM_VALUE.TAPS_PER_BRANCH } {
	# Procedure called to validate TAPS_PER_BRANCH
	return true
}


proc update_MODELPARAM_VALUE.N_CHANNELS { MODELPARAM_VALUE.N_CHANNELS PARAM_VALUE.N_CHANNELS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.N_CHANNELS}] ${MODELPARAM_VALUE.N_CHANNELS}
}

proc update_MODELPARAM_VALUE.M_DECIMATION { MODELPARAM_VALUE.M_DECIMATION PARAM_VALUE.M_DECIMATION } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.M_DECIMATION}] ${MODELPARAM_VALUE.M_DECIMATION}
}

proc update_MODELPARAM_VALUE.TAPS_PER_BRANCH { MODELPARAM_VALUE.TAPS_PER_BRANCH PARAM_VALUE.TAPS_PER_BRANCH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TAPS_PER_BRANCH}] ${MODELPARAM_VALUE.TAPS_PER_BRANCH}
}

proc update_MODELPARAM_VALUE.DATA_WIDTH { MODELPARAM_VALUE.DATA_WIDTH PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DATA_WIDTH}] ${MODELPARAM_VALUE.DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.COEFF_WIDTH { MODELPARAM_VALUE.COEFF_WIDTH PARAM_VALUE.COEFF_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.COEFF_WIDTH}] ${MODELPARAM_VALUE.COEFF_WIDTH}
}

proc update_MODELPARAM_VALUE.ACCUM_WIDTH { MODELPARAM_VALUE.ACCUM_WIDTH PARAM_VALUE.ACCUM_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ACCUM_WIDTH}] ${MODELPARAM_VALUE.ACCUM_WIDTH}
}

proc update_MODELPARAM_VALUE.POWER_ALPHA_W { MODELPARAM_VALUE.POWER_ALPHA_W PARAM_VALUE.POWER_ALPHA_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.POWER_ALPHA_W}] ${MODELPARAM_VALUE.POWER_ALPHA_W}
}

proc update_MODELPARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_CTRL_ADDR_WIDTH}
}

