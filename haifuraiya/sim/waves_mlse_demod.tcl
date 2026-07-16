################################################################################
# waves_mlse_demod.tcl -- wave groups for msk_demodulator_mlse
# Source after:  set FS $RX/u_fsync
# Signal flow: ring write -> engine (timing loop) -> mlse4 (trellis) -> shim
################################################################################

# --- sample ring / pacing ----------------------------------------------------
#   hold high most of the time is CORRECT: the engine is sample-rate-bound
#   and waits for writes. ring_lag or ovfl_mlse going high is a bug.
add_wave_group {MLSE_Ring}
add_wave -into {MLSE_Ring}                 $DEM/rx_svalid
add_wave -into {MLSE_Ring} -radix unsigned $DEM/wr_n
add_wave -into {MLSE_Ring}                 $DEM/hold
add_wave -into {MLSE_Ring}                 $DEM/ring_lag
add_wave -into {MLSE_Ring}                 $DEM/ovfl_mlse

# --- symbol engine: the timing loop ------------------------------------------
#   pos advances ~755720 (Q16) per symbol; sym_index counts symbols;
#   e_valid pulses once per symbol.
add_wave_group {MLSE_Engine}
add_wave -into {MLSE_Engine} -radix unsigned $DEM/engine/pos
add_wave -into {MLSE_Engine} -radix unsigned $DEM/engine/k
add_wave -into {MLSE_Engine} -radix dec      $DEM/engine/freq
add_wave -into {MLSE_Engine}                 $DEM/e_valid
add_wave -into {MLSE_Engine} -radix dec      $DEM/e_y1r
add_wave -into {MLSE_Engine} -radix dec      $DEM/e_y2r

# --- MLSE: per-survivor phase (the four thetas should cluster at lock) -------
add_wave_group {MLSE_Trellis}
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th0
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th1
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th2
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/th3
add_wave -into {MLSE_Trellis} -radix unsigned $DEM/dbg_best
add_wave -into {MLSE_Trellis}                 $DEM/m_busy

# --- bit decisions (same group name/role as before) --------------------------
add_wave_group {Bit_Decisions}
add_wave -into {Bit_Decisions}            $DEM/rx_data
add_wave -into {Bit_Decisions} -radix dec $DEM/rx_data_soft
add_wave -into {Bit_Decisions}            $DEM/rx_dvalid
add_wave -into {Bit_Decisions}            $DEM/demod_lock
