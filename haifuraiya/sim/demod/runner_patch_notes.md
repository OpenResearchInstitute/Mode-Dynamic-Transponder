# run_haifuraiya_channelizer_axi_test.tcl -- MLSE demod migration notes

## 1. Source list (safe_add_files sources_1): REMOVE
    ../third_party/pluto_msk/nco/src/sin_cos_lut.vhd        (unless used elsewhere)
    ../third_party/pluto_msk/nco/src/nco.vhd
    ../third_party/pluto_msk/pi_controller/src/pi_controller.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_lock_detect.vhd
    ../third_party/pluto_msk/msk_demodulator/src/costas_loop.vhd
    ../third_party/pluto_msk/msk_demodulator/src/msk_demodulator.vhd
## ADD (dependency order):
    ../rtl/rx/msk_symbol_engine.vhd
    ../rtl/rx/msk_mlse4.vhd
    ../rtl/rx/msk_demodulator_mlse.vhd
   (or wherever the three files land in the tree)

## 2. Stage the ROM alongside the stimulus (same pattern, one line pair):
    set lut_file [file join [file dirname [info script]] "lut16q_hex.txt"]
    file copy -force $lut_file $xsim_dir

## 3. Prerequisite: haifuraiya_rx_top edited per rx_top_patch_notes.md
   (16-bit feed, u_demod swapped to msk_demodulator_mlse). The demod
   AXI register bracket in the TB still works: init passes through;
   the Costas tuning registers become writes nobody reads until
   haifuraiya_demod_regs is trimmed (harmless in the interim).

## 4. Wave groups: DELETE Demod_Carrier, Demod_Timing, Demod_SymbolLock,
   Timing_Search (probe removed Costas internals; xsim errors on missing
   paths). REPLACE with waves_mlse_demod.tcl (sourced after `set FS ...`).

## 5. Verdict path unchanged: soft capture -> opv-decode -3 offline, or
   run check_demod.py against soft_raw.txt for the python-side verdict.
