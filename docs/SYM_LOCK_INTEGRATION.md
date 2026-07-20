# Symbol Lock Detector -- Main-Bench Integration Spec (SL into the system TB)

Goal per directive: prove the detector ON THE EXACT SIGNALS of
tb_haifuraiya_channelizer_axi -- the real engine's error stream through the
real chain -- at multiple settings, with grouped waves in the standard
runner. Unit bench (tb_sym_lock_detector + run_sym_lock_detector_test.tcl)
proves the block in isolation at three configurations; THIS spec puts it in
the system. Every edit below is location-cited; nothing is invented.

## 1. Engine: export the error term (one output, registered)
File: msk_symbol_engine.vhd
The per-symbol timing error (errg, computed in the S_UPDATE arm -- see
"fnew := resize(freq,34) + shift_right(errg,9)" near line 348) is internal.
Add:
  - port:  e_err : out signed(15 downto 0);  -- per-symbol timing error, LSBs
  - in S_UPDATE, alongside the freq update:
        e_err <= resize(shift_right(errg, C_ERR_EXPORT_SHR), 16);
    with  constant C_ERR_EXPORT_SHR : natural := <choose so full-scale TED
    maps near +/-2**14; document the derivation in-code as TED_FS_LSB> --
    this named constant IS the SL-3 calibration point.
  - reset branch: e_err <= (others => '0');  (mirror the declaration init)
The strobe pairing is the existing e_valid (already exported to the glue).

## 2. Glue: stopwatch out, detector in
File: msk_demodulator_mlse.vhd
DELETE:
  - generic G_LOCK_SYM (line 49) and its default;
  - in the status process (lines ~193-201): the
        if to_integer(e_sym) > G_LOCK_SYM then lock_r <= '1';
    arm. lock_r itself is deleted; ovfl_r / lag_r stay.
ADD:
  - ports threaded from the register block:
        sl_thresh_lock, sl_thresh_unlock : in unsigned(15 downto 0);
        sl_window_log2                   : in unsigned(3 downto 0);
        sl_avg_err                       : out unsigned(15 downto 0);
        sl_window_full                   : out std_logic;
  - instance:
        u_symlock : entity work.sym_lock_detector
          port map (clk => clk, init => init,
                    e_valid => <engine e_valid>, e_in => <engine e_err>,
                    thresh_lock => sl_thresh_lock,
                    thresh_unlock => sl_thresh_unlock,
                    window_log2 => sl_window_log2,
                    locked => demod_lock_i, avg_err => sl_avg_err,
                    window_full => sl_window_full);
        demod_lock <= demod_lock_i;
  demod_lock's consumer (fsync demod_sync_lock gate) is UNCHANGED -- the
  gate stays exactly where the architecture put it; only its truth source
  changes. Header comment updated to cite sym_lock_detector.vhd.

## 3. Registers: three RW + one RO, per map v6
File: haifuraiya_demod_regs.vhd (Path B hand-rolled extension)
  - constants: ADDR_SYM_LOCK_STATUS x"0A0", ADDR_SYM_LOCK_THRESH x"0A4",
    ADDR_SYM_UNLOCK_THRESH x"0A8", ADDR_SYM_LOCK_WINDOW x"0AC".
  - RW regs with reset defaults 0x0800 / 0x1000 / 6 (provisional until
    SL-3; mirrored declaration/reset per doctrine); readback arms.
  - STATUS(1) <= sym_locked from the glue (replaces the old latch source);
    SYM_LOCK_STATUS readback = (avg_err & window_full & locked) packed per
    the map. VERSION bumps to 0x00060000 WITH this change -- consumers
    gate on it.
  - Retired addresses 0x008-0x03C / 0x060-0x09C: decode arms return
    x"0000_0000"; writes ignored (map v6 reserved policy).

## 4. Main testbench: assertions on the exact signals
File: tb_haifuraiya_channelizer_axi.vhd
  - SL-A (replaces nothing; new): after DEMOD_INIT release with the
    standard opv20 stimulus, assert sym_locked (read STATUS bit1 via
    axi_read_demod) rises BEFORE the first fsync hunt candidate and
    within 40 ms of stimulus start (the preamble bound; Paul's spec).
  - SL-B (noise): during the existing pre-stimulus/noise phase, assert
    STATUS bit1 stays 0 for the entire phase (the anti-insta-lock check
    the design has owed since 2026-07-17: FS-1 in the map's plan).
  - SL-C (settings): re-run the frame-decode section at window_log2=4 and
    =8 (two extra axi_write_demod pairs + re-init) asserting lock still
    achieved and 6/6 decode unchanged -- different settings, exact
    signals, per directive.
  - SL-D (registers): fold the four new addresses into the existing
    register write/read walk (the bench's test-2 pattern).

## 5. Runner: wave group in the standard style
File: run_haifuraiya_channelizer_axi_test.tcl (after "set DEM ..."):
    set SL $DEM/u_symlock
    add_wave -into {Symbol_Lock}                     $DEM/demod_lock_i
    add_wave -into {Symbol_Lock} -radix unsigned     $SL/avg_err
    add_wave -into {Symbol_Lock}                     $SL/window_full
    add_wave -into {Symbol_Lock} -radix unsigned     $SL/sum
    add_wave -into {Symbol_Lock} -radix unsigned     $SL/fill
    add_wave -into {Symbol_Lock} -radix dec          <engine e_err path>
    add_wave -into {Symbol_Lock}                     <engine e_valid path>
  (While editing: fix line ~430's stale m_axis_soft_bit_* -> sb_* names --
  the pending correction from 2026-07-20.)

## 6. Definition of done for this block (per directive, in order)
  1. Unit bench green under the tcl runner (waves reviewed).      [runner delivered]
  2. Edits 1-3 applied; system bench SL-A..SL-D green; waveforms
     show lock rising from the real error stream at 3 settings.
  3. Map v6 docs regenerated-with / verified-against the code.
  4. Bitstream rebuild; devmem walk of 0x0A0-0x0AC; Bouro displays
     sym_locked + live avg_err.
Nothing else proceeds past this block until 1-4 hold. -- per W5NYV
