# run_chain.tcl -- Phase 0 final gate (Vivado 2022.2 xsim)
# expects: ../engine/msk_symbol_engine.vhd  ../mlse4/msk_mlse4.vhd
#          stim_chain.txt lut16.txt here; opv_demod_model.py and
#          cxx_frames.bin in the parent sim/ directory.
# NOTE: full-length run (~3.2M clocks). Expect 10-30 minutes of xsim.
exec xvhdl --2008 ../../rtl/rx/lut16q_pkg.vhd
exec xvhdl --2008 ../engine/msk_symbol_engine.vhd
exec xvhdl --2008 ../mlse4/msk_mlse4.vhd
exec xvhdl --2008 tb_chain.vhd
exec xelab --debug typical tb_chain -s chain_sim
exec xsim chain_sim -runall
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_chain.py]
