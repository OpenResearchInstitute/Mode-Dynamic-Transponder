----------------------------------------------------------------------------
-- cfo_slew.vhd -- rate limiter between the CFO correction word and the
-- rotator. THE POCKET CURE (measured 2026-07-29: AFC stepping costs ~20%
-- of frames; frozen-AFC trial ran ~96% with CLK gliding smoothly).
--
-- Mechanism being cured: cfo_afc updates its correction in steps of
-- ferr >> shift -- tens of Hz, instantaneously, every estimation window.
-- Each step is a phase-slope discontinuity the timing TED must chase;
-- the chase is the +/-9000-count CLK sawtooth and the ~24% frame-loss
-- pockets. The correction itself is NECESSARY (the LO wanders Hz/s;
-- a frozen word goes stale in minutes) -- it just must arrive gently.
--
-- Behavior: applied_hz glides toward target_hz at a bounded rate.
--   * fast gear (acquisition, state /= HELD): large rate so the +/-5 kHz
--     capture still completes in a few ms.
--   * gentle gear (HELD): ~1 Hz/symbol -- a 78 Hz correction spreads
--     over ~80 symbols, far below the timing loop's tracking bandwidth.
-- Internal accumulator is Q8 (Hz * 256) so sub-Hz-per-sample rates are
-- expressible; the rotator sees the integer Hz view.
--
-- Rates default from generics; a nonzero cfg overrides (wired from the
-- CFO_CTRL spare byte so the bench can experiment without a respin).
----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cfo_slew is
  generic (
    -- Q8 Hz per sample-tick. 625 ksps, 11.53 samples/symbol:
    -- gentle: 1 Hz/symbol ~= 0.0867 Hz/sample ~= 22 Q8 units
    -- fast  : 16 Hz/symbol ~= 1.39 Hz/sample  ~= 355 Q8 units
    G_RATE_GENTLE_Q8 : positive := 22;
    G_RATE_FAST_Q8   : positive := 355
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    en         : in  std_logic;                      -- per-sample tick
    target_hz  : in  signed(15 downto 0);            -- from AFC/manual mux
    afc_held   : in  std_logic;                      -- '1' = HELD: gentle gear
    cfg_rate   : in  unsigned(7 downto 0);           -- 0 = defaults; else
                                                     -- gentle rate = cfg << 2
    applied_hz : out signed(15 downto 0)             -- to cfo_rotator
  );
end entity;

architecture rtl of cfo_slew is
  signal acc : signed(23 downto 0) := (others => '0');  -- Q8 Hz
begin
  applied_hz <= resize(shift_right(acc, 8), 16);

  process(clk)
    variable tgt_q8 : signed(23 downto 0);
    variable diff   : signed(24 downto 0);
    variable rate   : signed(23 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        acc <= (others => '0');
      elsif en = '1' then
        tgt_q8 := shift_left(resize(target_hz, 24), 8);
        diff   := resize(tgt_q8, 25) - resize(acc, 25);
        -- SNAP TO ACQUIRE, GLIDE TO HOLD (2026-07-29 windup fix):
        -- a ramped actuator inside the AFC's acquisition loop makes two
        -- cascaded integrators -- the servo winds up against the lag
        -- (observed: est overshooting -5 kHz to -12.4 kHz, no frame
        -- lock at 12 ms). Acquisition happens pre-lock when no frames
        -- flow, so it gets the proven instant-apply dynamics; only the
        -- small HELD-mode kicks (the measured pocket cause) are slewed.
        if afc_held = '0' then
          acc <= shift_left(resize(target_hz, 24), 8);   -- bypass: snap
        else
          if cfg_rate = 0 then
            rate := to_signed(G_RATE_GENTLE_Q8, 24);
          else
            rate := to_signed(to_integer(cfg_rate) * 4, 24);  -- cfg << 2
          end if;
          if diff > resize(rate, 25) then
            acc <= acc + rate;
          elsif diff < -resize(rate, 25) then
            acc <= acc - rate;
          else
            acc <= acc + resize(diff, 24);   -- land exactly, no dither
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
