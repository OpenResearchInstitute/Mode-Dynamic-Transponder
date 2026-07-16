# haifuraiya_rx_top: swapping in msk_demodulator_mlse

1. FEED 16-BIT: replace the 12-bit slices with full-width normalized
   samples (keep the deliberate I/Q swap that made the old chain lock):
       rx_i_to_demod16 <= std_logic_vector(gq);
       rx_q_to_demod16 <= std_logic_vector(gi);
   and program the normalizer for the LEVEL_PLAN operating point
   (gain_target for rms 9000). DEMOD_SAMPLE_W and the Kd-slice comment
   retire with the old demod.

2. REPLACE u_demod with:
       u_demod : entity work.msk_demodulator_mlse
         port map (
           clk => aclk, init => demod_init_h,
           rx_enable => rx_enable, rx_svalid => rx_svalid,
           rx_i_samples => rx_i_to_demod16,
           rx_q_samples => rx_q_to_demod16,
           rx_data => rx_data, rx_data_soft => rx_data_soft,
           rx_dvalid => rx_dvalid,
           demod_lock => demod_lock,
           ovfl_mlse => open, ring_lag => open,   -- or to status regs
           dbg_pos => open, dbg_sym => open, dbg_th0 => open );
   demod_lock now comes from the wrapper directly; delete
   "demod_lock <= lock_f1 and lock_f2" and the Costas signal forest
   (freq words, lpf_*, cst_*, dbg_cst_*) or park them for the regs map.
   RX_INVERT semantics: unchanged, still applies to rx_data downstream.
   SOFT POLARITY: the wrapper already emits fsync's convention
   (positive = confident '0'); no change at u_fsync.

3. FSYNC TUNING (registers, not RTL): our soft distribution differs
   from the old demod's calibration (clean margins saturate at 32767).
   Bench item: measure the 6 dB soft distribution in the model, then
   program quant_thr_1/2/3_i accordingly. Defaults will likely hunt
   fine (CFAR correlation is scale-free); the quantizer bins are the
   part worth tuning for the last fraction of a dB.

4. TIMING NOTE: engine OOC margin is +0.587 ns; after in-context P&R
   re-check WNS. Next cut (S_WIN_SETUP) is scoped if needed.

## SEAM DECISIONS RATIFIED (W5NYV, 2026-07-16)
1. Sample width 16 CONFIRMED: 12 was the 9361/Pluto heritage; the 9002
   path takes full width. Closed by configuration, not logic.
2. demod_lock proposal ACCEPTED: lock = acquisition complete
   (sym_index > G_LOCK_SYM); symbols good -> frame sync proceeds.
3. Timing constant: ours stands (755720).
4. 2^24 sample wrap (~26.8 s): WILL be exceeded per transmission in the
   field. SCOPED ITEM, documented, proceed for bring-up; incremental
   phase tracking before field deployment.
Normalizer behavior confirmed by designer: SQUELCHING (not freeze/hunt).
Scale-up note: channel 5 first; all 64 channels after it works.
