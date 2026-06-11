# Confirming the 11: full-loopback soft-seam capture (run on a fast simulator)

The full msk_top loopback compiles and runs against the correctly-PINNED submodules
(don't use the GitHub "-main" tips -- they are ahead of what pluto_msk pins). Pinned commits:

  nco            615fe5aabd97b28909fdd22a7bcc1dddd72d6f4d
  pi_controller  d62c91e66769be378733eb9e6a68ab222f3f5179
  prbs           935c25ab545be9102a9b5ba55b14de7f7c3bfc7c
  msk_modulator  798305f0a5f57b26cd2e63eda64c2523a11f1f3f
  msk_demodulator 583faeda80dff58abf9085343aec2dbff06f1541
  lowpass_ema    f9f0d632ef752fea973c152b73985976c8e14571
  power_detector a118a96841a935ef20cf6a667d6aa37454c9f982

Get them with: git submodule update --init <each>   (a bare `git clone --recursive`
tries to pull the giant analogdevicesinc/linux + hdl submodules and stalls -- init the
seven ORI VHDL submodules explicitly, skip firmware/* and hdl).

## Run (nvc is MUCH faster than ghdl-mcode for this; ~hours on ghdl-mcode here)
  nvc --std=08 -a <all msk_top sources + submodules in Makefile order> tb_msk_modem_134byte_seamcap.vhd
  nvc --std=08 -e tb_msk_modem_134byte
  nvc --std=08 -r tb_msk_modem_134byte
(or via the existing sim/Makefile with SIM=nvc; the cocotb msk_test.py path also works.)

