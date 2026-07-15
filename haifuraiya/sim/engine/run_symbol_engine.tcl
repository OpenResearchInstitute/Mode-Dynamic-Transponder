# run_symbol_engine.tcl -- xsim runner, house style (Vivado 2022.2)
# usage: vivado -mode batch -source run_symbol_engine.tcl
# expects: msk_symbol_engine.vhd tb_msk_symbol_engine.vhd
#          lut16.txt stim_engine.txt golden_engine.txt  in cwd
exec xvhdl --2008 msk_symbol_engine.vhd
exec xvhdl --2008 tb_msk_symbol_engine.vhd
exec xelab --debug typical tb_msk_symbol_engine -s engine_sim
exec xsim engine_sim -runall
# compare with the sandbox-broken-python workaround
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_trace.py]
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_engine.py]
