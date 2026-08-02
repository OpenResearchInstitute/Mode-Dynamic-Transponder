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
  -- CORDIC atan2 (2026-08-01): the reference computes std::arg() -- a
  -- TRUE 4-quadrant angle. The first transcription's cross/dot small-
  -- angle ratio RECTIFIED large-angle junk-history updates (deterministic
  -- ISI correlations of the non-dominant tone, half of all updates on
  -- patterned data) into a constant bias: cfo_applied climbed smoothly
  -- away from truth at the trickle rate, bits died ~9.5 ms (waveform
  -- conviction 2026-08-01). atan2 averages those angles to zero, as the
  -- reference does. Same machinery the coarse AFC already carries.
  type atan_t is array (0 to 13) of signed(17 downto 0);
  constant C_ATAN : atan_t := (
      to_signed(8192,18), to_signed(4836,18), to_signed(2555,18),
      to_signed(1297,18), to_signed(651,18),  to_signed(326,18),
      to_signed(163,18),  to_signed(81,18),   to_signed(41,18),
      to_signed(20,18),   to_signed(10,18),   to_signed(5,18),
      to_signed(3,18),    to_signed(1,18));
  signal cx, cy   : signed(19 downto 0);
  signal cz       : signed(17 downto 0);
  signal ci       : unsigned(3 downto 0);
  constant C_CLAMP_Q8 : signed(31 downto 0) := to_signed(2000*256, 32);
begin
  fine_hz <= resize(shift_right(seed_q8 + acc_q8, 8), 16);

  process(clk)
    variable dre, dim, pre, pim : signed(15 downto 0);
    variable e1, e2   : signed(33 downto 0);
    variable cr, dt   : signed(33 downto 0);
    variable ferr_q8  : signed(31 downto 0);
    variable nx, ny   : signed(19 downto 0);
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
            -- quadrant fold + dead-air guard (coarse lessons, verbatim)
            if (abs(dot_r) + abs(cross_r)) < 16384 then
              cz <= (others => '0');
              ci <= to_unsigned(13, 4);
              cx <= (others => '0'); cy <= (others => '0');
              st <= DIVLOOP;
            elsif dot_r < 0 then
              cx <= resize(-dot_r(33 downto 14), 20);
              cy <= resize(-cross_r(33 downto 14), 20);
              if cross_r >= 0 then
                cz <= to_signed(-32768, 18);
              else
                cz <= to_signed( 32768, 18);
              end if;
              ci <= (others => '0');
              st <= DIVLOOP;
            else
              cx <= resize(dot_r(33 downto 14), 20);
              cy <= resize(cross_r(33 downto 14), 20);
              cz <= (others => '0');
              ci <= (others => '0');
              st <= DIVLOOP;
            end if;

          when DIVLOOP =>
            -- CORDIC vectoring: cy -> 0, angle accumulates in cz (Q16 turns)
            nx := cx; ny := cy;
            if cy >= 0 then
              cx <= nx + shift_right(ny, to_integer(ci));
              cy <= ny - shift_right(nx, to_integer(ci));
              cz <= cz - C_ATAN(to_integer(ci));
            else
              cx <= nx - shift_right(ny, to_integer(ci));
              cy <= ny + shift_right(nx, to_integer(ci));
              cz <= cz + C_ATAN(to_integer(ci));
            end if;
            if ci = 13 then st <= UPDATE; else ci <= ci + 1; end if;

          when UPDATE =>
            -- cz = -arg(dom*conj(prev)) in Q16 turns (CORDIC gives minus
            -- the input angle, coarse convention). ferr_hz = (-cz/65536)*R
            -- -> Q8: -cz * 54200 * 256 / 65536 = -cz * 211.72 ~= -cz*212.
            -- RESIDUAL-RANGE GATE (2026-08-01, measured): the loop's own
            -- clamp is +/-2000 Hz, so a legitimate residual can never
            -- exceed ~13 deg/symbol (2000/54200 turns). Junk-history
            -- updates (non-dominant tone's deterministic ISI correlation
            -- during patterned data) measure at 85-100 deg -- 13-15 kHz
            -- equivalent, 30x the legit signal, same-sign (FDBG capture:
            -- cz {+495,-797} legit vs {+15587,+18181} junk). arg() made
            -- them measurable; this gate, implied by the clamp itself,
            -- makes them ignorable. Threshold 3022 turns = 2.5 kHz.
            if abs(cz) > to_signed(3022, 18) then
              ferr_q8 := (others => '0');   -- junk by construction: skip
            else
              ferr_q8 := resize(-cz * to_signed(212, 12), 32);
            end if;
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
