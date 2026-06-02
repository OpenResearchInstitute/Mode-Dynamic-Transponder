-- Haifuraiya channelizer per-channel EQ gain LUT
-- Corrects the 2:1 halfband (20->10 Msps) passband droop on the edge channels.
-- Indexed by channelizer TDEST (0..63). Q2.16 unsigned-magnitude in 18 bits:
--   corrected = (channel_sample * GAIN) >> 16, then saturate to sample width.
-- One multiplier + this 64-entry ROM addressed by TDEST does the whole bank.
-- ch32 = Nyquist wrap bin, left at unity (1.0 = 65536); do not use that channel.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package channel_gain_pkg is
  constant EQ_SHIFT : integer := 16;   -- gains are Q2.16
  type eq_gain_t is array(0 to 63) of signed(17 downto 0);
  constant CH_EQ_GAIN : eq_gain_t := (
     0 => to_signed( 65536, 18),
     1 => to_signed( 65537, 18),
     2 => to_signed( 65537, 18),
     3 => to_signed( 65535, 18),
     4 => to_signed( 65535, 18),
     5 => to_signed( 65537, 18),
     6 => to_signed( 65535, 18),
     7 => to_signed( 65534, 18),
     8 => to_signed( 65537, 18),
     9 => to_signed( 65538, 18),
    10 => to_signed( 65535, 18),
    11 => to_signed( 65537, 18),
    12 => to_signed( 65538, 18),
    13 => to_signed( 65535, 18),
    14 => to_signed( 65535, 18),
    15 => to_signed( 65538, 18),
    16 => to_signed( 65537, 18),
    17 => to_signed( 65537, 18),
    18 => to_signed( 65538, 18),
    19 => to_signed( 65535, 18),
    20 => to_signed( 65534, 18),
    21 => to_signed( 65538, 18),
    22 => to_signed( 65538, 18),
    23 => to_signed( 65535, 18),
    24 => to_signed( 65536, 18),
    25 => to_signed( 65536, 18),
    26 => to_signed( 65538, 18),
    27 => to_signed( 65534, 18),
    28 => to_signed( 65679, 18),  -- -0.02 dB
    29 => to_signed( 67085, 18),  -- -0.20 dB
    30 => to_signed( 72793, 18),  -- -0.91 dB
    31 => to_signed( 89074, 18),  -- -2.67 dB
    32 => to_signed( 65536, 18),  -- Nyquist wrap (unity)
    33 => to_signed( 89074, 18),  -- -2.67 dB
    34 => to_signed( 72793, 18),  -- -0.91 dB
    35 => to_signed( 67085, 18),  -- -0.20 dB
    36 => to_signed( 65679, 18),  -- -0.02 dB
    37 => to_signed( 65534, 18),
    38 => to_signed( 65538, 18),
    39 => to_signed( 65536, 18),
    40 => to_signed( 65536, 18),
    41 => to_signed( 65535, 18),
    42 => to_signed( 65538, 18),
    43 => to_signed( 65538, 18),
    44 => to_signed( 65534, 18),
    45 => to_signed( 65535, 18),
    46 => to_signed( 65538, 18),
    47 => to_signed( 65537, 18),
    48 => to_signed( 65537, 18),
    49 => to_signed( 65538, 18),
    50 => to_signed( 65535, 18),
    51 => to_signed( 65535, 18),
    52 => to_signed( 65538, 18),
    53 => to_signed( 65537, 18),
    54 => to_signed( 65535, 18),
    55 => to_signed( 65538, 18),
    56 => to_signed( 65537, 18),
    57 => to_signed( 65534, 18),
    58 => to_signed( 65535, 18),
    59 => to_signed( 65537, 18),
    60 => to_signed( 65535, 18),
    61 => to_signed( 65535, 18),
    62 => to_signed( 65537, 18),
    63 => to_signed( 65537, 18) 
  );
end package channel_gain_pkg;
