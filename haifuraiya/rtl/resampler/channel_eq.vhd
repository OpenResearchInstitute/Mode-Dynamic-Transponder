-- channel_eq.vhd
-- Haifuraiya per-channel EQ: corrects the halfband edge-droop on the channelizer
-- output. One multiplier + a 64-entry gain ROM addressed by the channel index
-- (TDEST). Place this on the channelizer output stream BEFORE the power-detector
-- tap so telemetry and demod both see flat channels from the same hardware.
--
--   corrected = saturate16( (sample * CH_EQ_GAIN[ch] + 2^15) >> 16 )
--   gains are Q2.16; unity on all but the 8 edge channels; ch32 (Nyquist) is unity.
--
-- Bit-exact to channel_eq.py apply_eq_fixed(). 3-stage pipeline.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.channel_gain_pkg.all;            -- EQ_SHIFT, CH_EQ_GAIN, eq_gain_t

entity channel_eq is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    in_valid  : in  std_logic;
    in_chan   : in  unsigned(5 downto 0);   -- channelizer TDEST, 0..63
    in_i      : in  signed(15 downto 0);
    in_q      : in  signed(15 downto 0);
    out_valid : out std_logic;
    out_chan  : out unsigned(5 downto 0);
    out_i     : out signed(15 downto 0);
    out_q     : out signed(15 downto 0)
  );
end entity channel_eq;

architecture rtl of channel_eq is
  constant SH : integer := EQ_SHIFT;        -- 16
  -- stage 1 registers
  signal g1        : signed(17 downto 0);
  signal i1, q1    : signed(15 downto 0);
  signal ch1       : unsigned(5 downto 0);
  signal v1        : std_logic := '0';
  -- stage 2 registers
  signal pi2, pq2  : signed(33 downto 0);   -- 16*18 -> 34-bit
  signal ch2       : unsigned(5 downto 0);
  signal v2        : std_logic := '0';

  function sat16(x : signed) return signed is
  begin
    if    x > to_signed(32767,  x'length) then return to_signed(32767,  16);
    elsif x < to_signed(-32768, x'length) then return to_signed(-32768, 16);
    else  return resize(x, 16);
    end if;
  end function;

begin
  process(clk)
    variable ri, rq : signed(33 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        v1 <= '0'; v2 <= '0'; out_valid <= '0';
      else
        -- stage 1: fetch the per-channel gain, hold the sample
        v1  <= in_valid;
        g1  <= CH_EQ_GAIN(to_integer(in_chan));
        i1  <= in_i;  q1 <= in_q;  ch1 <= in_chan;

        -- stage 2: multiply
        v2  <= v1;
        pi2 <= i1 * g1;
        pq2 <= q1 * g1;
        ch2 <= ch1;

        -- stage 3: round-half-up, >>16, saturate
        out_valid <= v2;
        ri := pi2 + to_signed(2**(SH-1), 34);
        rq := pq2 + to_signed(2**(SH-1), 34);
        out_i    <= sat16(shift_right(ri, SH));
        out_q    <= sat16(shift_right(rq, SH));
        out_chan <= ch2;
      end if;
    end if;
  end process;
end architecture rtl;
