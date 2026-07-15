# golden_decode: bit-exact channelizer model + C++ decode oracle

## What was proven (2026-07-14)

1. golden_channelizer.py reproduces the RTL INTEGER-FOR-INTEGER:
   validated beat-by-beat against five GHDL dumps of the actual VHDL
   (haifuraiya_channelizer_top alone at 10 Msps, and
   halfband_decimator + core at 20 Msps), 32,640 beats each, zero
   mismatches. This is the dump-compare golden model the WP docs call for.

2. Real Opulent Voice decodes through it end to end:

       opv-mod -S W5NYV -P -B 10          (2.168 Msps complex baseband)
    -> opv-resample 2168000 20000000
    -> mix to +781.25 kHz (channel 5), int16, rms 9000
    -> halfband_model (bit-exact 20 -> 10 Msps)
    -> core_model     (bit-exact 64-channel channelizer)
    -> extract raw FFT bin 59 = relabeled channel 5, 625 ksps
    -> scale to int16 -> opv-demod -c -R 625000

   Result:   10 frames decoded, 5 perfect, LOCKED, AFC 0.0 Hz
   Control (no channelizer, opv-resample 2168000 625000 direct):
              9 frames decoded, 5 perfect
   The channelizer path decodes AT PARITY with the direct path. The
   channel-5 stream needed NO conjugation, NO inversion, NO tone-swap:
   the channelizer output convention is compatible with the C++
   coherent demod exactly as produced.

## Files

  golden_channelizer.py   bit-exact model: halfband + filterbank + R2SDF
                          (Q1.14 tw, TW_SCALE=16383, ties-away ROM, 40-bit
                          wrap, truncating >>14) + reorder (FRAME_PHASE=1)
                          + priming (FILL_FRAMES=2) + rotation j^(k*m)
  convert_chan_iq.py      "I Q" text dump -> interleaved int16 for opv-demod;
                          use this on chan_iq.txt from the xsim testbench to
                          run the identical decode against RTL output
  run_decode_pipeline.sh  the full model-path pipeline, one command

## The RTL-side twin of this test

Dump channel-5 IQ from the real RTL (xsim overnight run or tb_chain_tone
extended to an OPV stimulus), then:

    python3 convert_chan_iq.py chan_iq.txt chan_iq.cs16
    opv-demod -c -R 625000 < chan_iq.cs16

Model and RTL are bit-exact, so the RTL run must produce the same decode.
Any divergence is a dump-format or stimulus-placement issue, not DSP.

## RTL decode run (the twin, on your xsim)

Files: tb_chain_opv.vhd, run_chain_opv.tcl, gen_opv20_stim.py,
check_opv_bitexact.py. Sequence, all from sim/:

    python3 gen_opv20_stim.py --bin <opv-cxx-demod>/bin --frames 10
    (Vivado TCL console)  source run_chain_opv.tcl        # hours; walk away
    python3 convert_chan_iq.py chan5_iq.txt chan5_iq.cs16
    <opv-cxx-demod>/bin/opv-demod -c -R 625000 < chan5_iq.cs16
    python3 check_opv_bitexact.py opv20_stim.txt chan5_iq.txt   # optional

The prediction is deterministic, not statistical: the golden model is
bit-exact to this RTL, so chan5_iq.txt must equal the model's channel-5
stream integer-for-integer (check_opv_bitexact.py verifies this), and the
decode must read 10 frames, 5 perfect, LOCKED, AFC 0.0 Hz. Any deviation
is a finding, not noise.
