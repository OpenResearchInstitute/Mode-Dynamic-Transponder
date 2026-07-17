# Haifuraiya channelizer verification architecture

Goal: prove the whole receive front end, halfband decimator through the AXI
wrapper, with TWO independent oracles at every level:

  ORACLE 1 (analytic)  : human-readable properties (DC gain, energy-in-bin,
                         adjacent rejection, register readback). Catches gross
                         wiring/scaling errors and is interpretable on failure.
  ORACLE 2 (bit-exact) : sample-for-sample equality against a fixed-point
                         Python model that is itself analytically self-checked
                         before it is allowed to mint any golden vectors.

Neither oracle alone is sufficient. The halfband bring-up proved why: a
bit-exact test with a mis-specified emit convention threw 2000 false failures
while the filter was in fact correct; the analytic layer would have passed and
pointed straight at the convention, not the RTL.

## Signal chain and proof levels (bottom up)

  20 Msps cplx
    -> [L1] halfband_decimator      (/2 -> 10 Msps)
    -> [L3] polyphase_filterbank    (2x, N=64, M=16)
    -> P2S adapter
    -> [L2] r2sdf_fft               (64-pt)
    -> [L5] requantize + channel_eq (40 -> 16, OUTPUT_SHIFT)
    -> [L4] power_detector x64      (EMA)
    -> m_axis_chans + AXI-Lite regs
       [I1] channelizer_top   = L3+FFT+L5 integrated (core, 40-bit)
       [I2] halfband + core   = L1+I1 at true 20 Msps
       [I3] channelizer_axi   = I2 + L4 + AXI-Lite (the tap the demod eats)

## Oracle per level

  L1 halfband_decimator   bit-exact vs halfband_model ; DC unity gain
                          [DONE, GHDL PASS: 3000 be + 140 dc]
  L2 r2sdf_fft            bit-exact vs fft_model (+ out_idx natural-order check) ;
                          DC->bin0, CHANNEL ORDERING +k->bin k / -k->bin (N-k)
                          as a first-class reversal detector, Parseval energy
                          [DONE, GHDL PASS: 576 be samples, 7 ordering frames,
                          0 reversals. Frame contract: discard leading partial to
                          first out_idx=0, skip FILL=1 aligned frame, then aligned
                          frame FILL+k == fft(input k). fft_64pt/fft_n_pt and their
                          TBs are LEGACY, not in the datapath.]
  L3 polyphase_filterbank bit-exact vs polyphase_model (all 64 branches/frame)
                          + channel-0 unity DC gain in hardware + channel-0
                          lowpass tone-sweep (COMMUTATOR DIRECTION / reversal
                          check: flat in band, -41 dB ch1, -52 dB ch2)
                          [DONE, GHDL PASS: 40 frames, 0 branch mismatches, DC
                          unity 0 errors. Frame contract: frame f newest sample
                          = M*(f+1)-1, NO fill frame. Commutator direction proven
                          CORRECT (backward): channel 0 is a proper lowpass.]

    *** COEFFICIENT PROVENANCE DEFECT (found by the bit-exact oracle) ***
      The coeff .hex (rtl/coeffs/haifuraiya_coeffs.hex, design intent) and the
      compiled-in .vhd package (rtl/channelizer/haifuraiya_coeffs_pkg.vhd, what
      SYNTHESIZES) disagree at 2 taps, both off by 1 LSB:
        index 681 (branch 28, tap 9):  .hex 20  vs  .vhd(ships) 19
        index 854 (branch 35, tap 14): .hex 20  vs  .vhd(ships) 19
      Symptoms it caused: 3 branch-28 mismatches (frames 37-39, when tap 9
      activates) and a DC-gain deficit of 2 (16432 shipped vs 16434 hex).
      The hardware uses the .vhd values; the model/vectors track .vhd so the
      LOGIC proof is valid. ACTION: regenerate BOTH .hex and .vhd from
      docs/polyphase_channelizer.ipynb to reconcile, then re-run; the generator's
      provenance check will go clean. Which value is intended cannot be
      determined from the RTL alone.
  L5a channel_eq          bit-exact vs channel_eq_model (== docs/channel_eq.py)
                          + out_chan/TDEST gain-routing integrity + saturation
                          clamp exercised + provenance (pkg == channel_eq.py)
                          [DONE, GHDL PASS: 1600 samples, 0 value/chan mismatches,
                          226 saturation events. Per-channel droop EQ: unity except
                          8 edge channels (28-31, 33-36), ch31/33 max +2.67 dB.
                          This datapath (mult+round+sat+gain ROM) is the one the
                          per-channel normalizer reuses.]
  L5b requantize          OUTPUT_SHIFT 40->16 is INLINE in haifuraiya_channelizer_
                          axi.vhd (not a standalone entity) -> proven at the I3
                          wrapper level. NOTE: slated for replacement by the
                          per-channel normalizer (see docs normalizer spec); the
                          bimodal HW bug lived here.
  L4 power_detector       DONE (xsim-ready; GHDL-green, best latency 2, 0
                          mismatches, 0 hold errors). DUT = third_party submodules
                          lowpass_ema @280fe847 + power_detector @86bae9a0 (CONFIRM
                          these match your pinned SHAs). Model power_detector_model.py
                          proven BIT-EXACT to RTL by dump-compare over 306 cycles on
                          all 5 signals (power_squared, dsum, dsum_e2, ema_1,
                          ema_1_ena). Config DATA_W=16, IQ_MOD, EMA_CASCADE, each
                          lowpass_ema PROD_W=51 (shifts 3/1/18/20, sat +/-2^50).
                          Oracle 2 = bit-exact power_squared AND dbg_ema_1 vs golden
                          (602-cycle stream: DC ramp, step, data_ena gap, random).
                          Oracle 1 = dbg_ema_1 holds while dbg_ema_1_ena=0 (gating).
                          Findings: (a) 51-bit mult_sum feedback trap CONFIRMED --
                          a 31-bit-feedback model diverges up to 16 LSB, so full
                          width is mandatory (matches WP2 doc); (b) EMA has ~1.6%
                          fixed-point DC droop -- settles NEAR I^2+Q^2, not exactly
                          (do not claim unity DC gain). GHDL gate uses a 2-line
                          patched lowpass_ema (SAT consts) for mcode; xsim uses the
                          original. Files: tb_power_detector.vhd, run_power_detector.
                          tcl, golden/{power_detector_model.py, gen_power_detector_
                          vectors.py, vectors/pd_{input,expected}.txt}.
  I1 channelizer_top      DONE (GHDL-green; bit-exact + empirical map). Composed
                          model channelizer_top_model = PROVEN polyphase leaf (I
                          and Q) + P2S complex assembly (bi + j*bq) + PROVEN FFT
                          leaf + (-j)^((k*m) mod 4) rotation, first emitted frame
                          at block m=2 (M=16, 4x oversampled). Proven bit-exact to
                          the RTL by dump-compare (tone AND random complex, 43/43
                          frames each). Dual-oracle bench tb_channelizer_top: (2)
                          settled frame bit-exact channel_re/im 40-bit; (1) in-
                          hardware frequency->channel MAP via a tone sweep, energy
                          summed over settled frames.
                          *** FINDING (reversal seam RESOLVED): the map is a PURE
                          reversal, input channel k -> OUTPUT channel (N-k) mod 64,
                          with DC (0->0) and Nyquist (32->32) as fixed points.
                          Demonstrated on real RTL for k=0,1,2,5,10,16,31,32,33,48,
                          63 (all match). The rotation is diagonal so it cannot
                          mirror; the reversal is set by the complex assembly
                          (bi + j*bq) convention. CONFIRM this matches how bring-up
                          and TARGET_CHANNEL treat frequency: empirical channel
                          selection is transparent to it; arithmetic freq->channel
                          mapping would be off by the reversal (lands N-k). ***
                          Files: tb_channelizer_top.vhd, run_channelizer_top.tcl,
                          golden/{channelizer_top_model.py, gen_channelizer_top_
                          vectors.py, vectors/ct_sweep_{input,expected}.txt}.
                          Sample spacing note: drive 1 sample / 10 clocks (10 MSps
                          @ 100 MHz) or the filterbank outruns the P2S -> drops.
  I2 halfband + core      end-to-end bit-exact at 20 Msps ; tone at LO+/-k*156.25
                          kHz lands on channel k
  I3 channelizer_axi      bit-exact m_axis_chans ; AXI-Lite readback of power /
                          frame count / sticky status ; TDEST/TLAST framing

## Long pole

L1, L2 have committed fixed-point models. The single biggest task is a
FULL-channelizer fixed-point model declared bit-exact to channelizer_top
(polyphase + P2S + FFT + requantize + eq). polyphase_channelizer.ipynb is the
candidate source but has NOT yet been confirmed bit-exact to the RTL. I1/I2/I3
bit-exact oracles depend on it.

## Naming and layout (proposed; redline before mass-generation)

  sim/tb_<block>.vhd                 one dual-oracle TB per block
  sim/run_<block>.tcl                one Vivado xsim script per block
  sim/run_all.tcl                    runs every level, aggregates PASS/FAIL
  sim/golden/<block>_model.py        fixed-point reference (moved out of docs/)
  sim/golden/gen_<block>_vectors.py  analytic gate + vector emit
  sim/golden/vectors/<block>_input.txt, <block>_expected.txt   committed

Every gen_*.py runs its analytic oracle on the model and exits nonzero WITHOUT
writing vectors if the model fails. Vectors are regenerable and committed so an
xsim-only user needs no Python to run a TB.

## Emit conventions (pinned, the source of silent mismatches)

  halfband: RTL streams full[1::2] from convolution index 1, INCLUDING startup
            transient. This is NOT decimate_fixed()'s [CENTER::2] (=[37::2]),
            which drops the first 18 outputs. Golden vectors follow the RTL.
            An 18-sample lead offset here reads as "every sample wrong."

## Toolchain

Primary: Vivado 2022.2 xsim (production flow).
Pre-commit gate: GHDL --std=08 runs the same TBs headless (no Vivado, no
license) so the suite is CI-runnable and each block can be proven before
hardware. RTL confirmed GHDL-clean at L1.
