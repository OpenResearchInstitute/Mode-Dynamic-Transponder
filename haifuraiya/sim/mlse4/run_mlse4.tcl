# run_mlse4.tcl -- xsim runner (Vivado 2022.2), house style
exec xvhdl --2008 msk_mlse4.vhd
exec xvhdl --2008 tb_msk_mlse4.vhd
exec xelab --debug typical tb_msk_mlse4 -s mlse_sim
exec xsim mlse_sim -runall
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_step.py]
puts [exec env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 check_mlse.py]
