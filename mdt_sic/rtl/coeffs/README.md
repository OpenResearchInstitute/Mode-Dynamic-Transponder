# MDT-SIC Filter Coefficients

`mdt_coeffs.hex` holds the prototype filter coefficients for the MDT-SIC
spectrum-analysis filter (FunCube+ design, lead by @martinling).

The hex file is read by `coeff_rom.vhd` at elaboration time -- both during
simulation (textio `file_open`) and during synthesis (Yosys/GHDL or Radiant
evaluate the initialization function and embed the values into the iCE40
EBR/Block-RAM contents of the bitstream).

The Haifuraiya prototype filter coefficients live separately at
[`../../../haifuraiya/rtl/coeffs/haifuraiya_coeffs.hex`](../../../haifuraiya/rtl/coeffs/).
