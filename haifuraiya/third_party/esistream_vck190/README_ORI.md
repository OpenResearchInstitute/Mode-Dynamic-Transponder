# Teledyne e2v ESIstream package for the VCK190 (from the vendor)

Source: esistream.com, "esistream-14b16b-packages", VCK190
(xcvc1902-vsva2197-2MP-e-S), zip `Package_ESIstream_Xilinx_xcvc1902-vsva2197-2mp-e-s-main.zip`,
md5 `021ae2e7cb6601fd64edc04c4329166b`, downloaded 2026-10-28 by Abraxas3d.

License: every source file carries Teledyne's public-domain dedicatio
("free and unencumbered software released into the public domain ... THIS
DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES").  Headers are
kept verbatim.  This directory is the zip contents so we can diff against this
to find any changes over time.

What we use:

`src_pkg/esistream_pkg_64b.vhd`
`src_tx/` (encoder)
`src_rx/` (decoder)
`src_common/ff_synchronizer_array.vhd`

`xm107/` transceiver block design and constraints for the hardware loopback 
`aq600/` for the ADC later.
`src_tx_emulator/`, the UART/register map and the Python GUI are not used.

Not a git submodule. It is distributed as a zip file. That means documentation
burden is on us to keep it organized and correctly licensed, etc.
