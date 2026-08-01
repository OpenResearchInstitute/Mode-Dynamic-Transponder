----------------------------------------------------------------------------
-- cfo_fine.vhd -- per-symbol fine frequency tracking. A TRANSCRIPTION of
-- the C++ reference (opv_demod.hpp, MSKDemodulatorAFC, lines 388-402),
-- not a design. The reference law, verbatim:
--
--     dom  = (e1 > e2) ? corr_f1 : corr_f2;
--     pd   = arg(dom * conj(prev_dom));
--     ferr = pd * SYMBOL_RATE / TWO_PI;
--     freq_offset_ += 0.001 * ferr;              // per symbol
--     freq_offset_  = clamp(freq_offset_, -2000, +2000);
--
-- Fixed-point mapping (each choice traceable to the reference):
--   * corr_f1/f2       -> engine's per-symbol y1/y2 exports (16-bit I/Q)
--   * arg(dom*conj(p)) -> atan approximated as cross/dot (angles here are
--                         tiny: 100 Hz residual = 0.012 rad/symbol; the
--                         approximation error is < 0.5% below 0.4 rad,
--                         and the C++ clamp bounds us to +/-2 kHz =
--                         0.23 rad where error < 2%)
--   * SYMBOL_RATE/2pi  -> 54200/(2*pi) = 8626.9 ~= 8627
--   * alpha = 0.001    -> >> 10  (1/1024 = 0.000977)
--   * clamp +/-2000 Hz -> applied about the acquisition seed: the coarse
--                         AFC (windowed, wide-range) gets us inside
--                         +/-2 kHz and seeds this integrator at HELD
--                         entry, exactly as the C++'s init_offset seeds
--                         freq_offset_ in streaming mode.
--
-- The output drives the SAME rotator the coarse AFC used (derotating the
-- input and adjusting the tone increments are the same operation --
-- e^{-j phi} on the signal = e^{+j phi} on both references). What changes
-- vs. the windowed AFC is the UPDATE LAW: per-symbol micro-corrections
-- (<= ~2 Hz/symbol at the clamp edge, milli-Hz in steady state) instead
-- of tens-of-Hz window steps. The gentleness the timing loop needs falls
-- out of the reference's own arithmetic.
----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cfo_fine is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- per-symbol tone correlations from the engine (via wrapper)
    y_valid    : in  std_logic;
    y1_re      : in  signed(15 downto 0);
    y1_im      : in  signed(15 downto 0);
    y2_re      : in  signed(15 downto 0);
    y2_im      : in  signed(15 downto 0);
    -- seed: coarse AFC's word, latched on the rising edge of seed_load
    -- (HELD entry). Tracking is active only while enabled.
    seed_hz    : in  signed(15 downto 0);
    seed_load  : in  std_logic;
    enable     : in  std_logic;
    -- to the rotator (replaces the coarse word after HELD entry)
    fine_hz    : out signed(15 downto 0)
  );
end entity;

architecture rtl of cfo_fine is
  -- freq_offset_ in Q8 Hz (sub-Hz trickle must be representable)
  signal acc_q8   : signed(31 downto 0) := (others => '0');
  signal seed_q8  : signed(31 downto 0) := (others => '0');
  -- BOTH tones' previous correlations, like the reference's
  -- prev_corr_f1_/prev_corr_f2_ -- the discriminator compares
  -- like-to-like even when data flips the dominant tone. (First
  -- transcription kept one 'previous dominant' and compared f1-now
  -- to f2-prev across flips; its tb missed it because the plant
  -- never alternated dominance. 2026-07-29.)
  signal p1_re, p1_im : signed(15 downto 0) := (others => '0');
  signal p2_re, p2_im : signed(15 downto 0) := (others => '0');
  signal have_prev : std_logic := '0';

  -- discriminator pipeline: MULT products -> serial divide -> update.
  -- Widths: cross/dot are 34-bit (16x16 sums); both pre-scaled >>10 to
  -- 24-bit before the divide; quotient is the Q14 ratio cross/dot,
  -- bounded ~2^12 inside the +/-2 kHz clamp (0.23 rad), 16-bit loop.
  type st_t is (IDLE, DIVSTART, DIVLOOP, UPDATE);
  signal st : st_t := IDLE;
  signal cross_r  : signed(33 downto 0);
  signal dot_r    : signed(33 downto 0);
  signal rem_r    : unsigned(37 downto 0);
  signal den_r    : unsigned(23 downto 0);
  signal quo      : unsigned(15 downto 0);
  signal neg_q    : std_logic;
  signal bitn     : integer range 0 to 16;
  constant C_CLAMP_Q8 : signed(31 downto 0) := to_signed(2000*256, 32);
begin
  fine_hz <= resize(shift_right(seed_q8 + acc_q8, 8), 16);

  process(clk)
    variable dre, dim, pre, pim : signed(15 downto 0);
    variable e1, e2   : signed(33 downto 0);
    variable cr, dt   : signed(33 downto 0);
    variable ferr_q8  : signed(31 downto 0);
    variable step     : signed(31 downto 0);
    variable nacc     : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        acc_q8 <= (others => '0'); seed_q8 <= (others => '0');
        have_prev <= '0'; st <= IDLE;
      else
        if seed_load = '1' then
          seed_q8 <= shift_left(resize(seed_hz, 32), 8);
          acc_q8  <= (others => '0');
          have_prev <= '0';
        end if;

        case st is
          when IDLE =>
            if y_valid = '1' and enable = '1' then
              -- dominant-tone select: e1 > e2 (reference line 390)
              e1 := resize(y1_re*y1_re, 34) + resize(y1_im*y1_im, 34);
              e2 := resize(y2_re*y2_re, 34) + resize(y2_im*y2_im, 34);
              -- like-to-like: current dominant vs THE SAME tone's
              -- previous correlation (ref lines 390-396)
              if e1 > e2 then
                dre := y1_re; dim := y1_im; pre := p1_re; pim := p1_im;
              else
                dre := y2_re; dim := y2_im; pre := p2_re; pim := p2_im;
              end if;
              p1_re <= y1_re; p1_im <= y1_im;
              p2_re <= y2_re; p2_im <= y2_im;
              if have_prev = '1' then
                -- dom * conj(prev): cross = Im, dot = Re (ref line 398)
                cr := resize(dim*pre, 34) - resize(dre*pim, 34);
                dt := resize(dre*pre, 34) + resize(dim*pim, 34);
                if dt > 0 then          -- reject junk symbols: a tone
                  cross_r <= cr;        -- flip (dot<=0) means the small-
                  dot_r   <= dt;        -- angle premise broke; skip, as
                  st      <= DIVSTART;  -- one lost update is harmless at
                end if;                 -- alpha=1/1024
              end if;
              have_prev <= '1';
            end if;

          when DIVSTART =>
            -- pre-scale to 24-bit, form |cross|<<14 in 38 bits
            if cross_r < 0 then
              rem_r <= shift_left(resize(unsigned(-cross_r(33 downto 10)), 38), 14);
              neg_q <= '1';
            else
              rem_r <= shift_left(resize(unsigned(cross_r(33 downto 10)), 38), 14);
              neg_q <= '0';
            end if;
            den_r <= unsigned(dot_r(33 downto 10));
            quo   <= (others => '0');
            bitn  <= 16;
            st    <= DIVLOOP;

          when DIVLOOP =>
            if bitn = 0 or den_r = 0 then
              st <= UPDATE;
            else
              if rem_r >= shift_left(resize(den_r, 38), bitn-1) then
                rem_r <= rem_r - shift_left(resize(den_r, 38), bitn-1);
                quo   <= quo or to_unsigned(2**(bitn-1), 16);
              end if;
              bitn <= bitn - 1;
            end if;

          when UPDATE =>
            -- ferr_q8 = q(Q14 ratio) * 8627 -> Hz in Q8: (q*8627) >> 6
            ferr_q8 := resize(shift_right(signed(resize(quo, 17)) * to_signed(8627, 15), 6), 32);
            if neg_q = '1' then ferr_q8 := -ferr_q8; end if;
            -- DOMAIN SIGN (cfo_afc.vhd header, lines 26-30, verbatim rule):
            -- the y's live in the demod's SWAPPED domain (z' = j*conj(z));
            -- conjugation negates frequency, so measured rotation is MINUS
            -- the antenna-frame residual. Negated once, here, where the
            -- domain boundary is crossed -- same toll the coarse AFC pays.
            -- (First transcription omitted this: positive feedback, ran to
            -- the clamp, rail-confident garbage, zero sync. 2026-07-30.)
            ferr_q8 := -ferr_q8;
            -- freq_offset_ += 0.001 * ferr  (alpha = 1/1024, ref 401)
            step := resize(shift_right(ferr_q8 + to_signed(512, 32), 10), 32);
            nacc := acc_q8 + step;
            -- clamp +/-2000 Hz about the seed (ref 402)
            if nacc >  C_CLAMP_Q8 then nacc :=  C_CLAMP_Q8; end if;
            if nacc < -C_CLAMP_Q8 then nacc := -C_CLAMP_Q8; end if;
            acc_q8 <= nacc;
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
