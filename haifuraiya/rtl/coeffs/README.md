# Haifuraiya Filter Coefficients

`haifuraiya_coeffs.hex` holds the 1,536 prototype-filter coefficients
(64 channels x 24 taps per branch) for the Haifuraiya polyphase channelizer.

Each `fir_branch_parallel` instance reads its own 24-coefficient slice at
elaboration time via textio -- there is no shared `coeff_rom` and no
runtime load handshake.

The MDT-SIC coefficients live separately at
[`../../../mdt_sic/rtl/coeffs/mdt_coeffs.hex`](../../../mdt_sic/rtl/coeffs/).
