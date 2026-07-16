# run_demod.tcl -- wrapper bench (Vivado 2022.2). ~20-40 min (stream-paced).
# expects ../engine/msk_symbol_engine.vhd ../mlse4/msk_mlse4.vhd,
# stim_chain.txt + lut16q_hex.txt here, model + cxx_frames.bin in ../
exec xvhdl --2008 ../engine/msk_symbol_engine.vhd
exec xvhdl --2008 ../mlse4/msk_mlse4.vhd
exec xvhdl --2008 msk_demodulator_mlse.vhd
exec xvhdl --2008 tb_msk_demodulator.vhd
exec xelab --debug typical tb_msk_demodulator -s demod_sim
exec xsim demod_sim -runall
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_demod.py]
