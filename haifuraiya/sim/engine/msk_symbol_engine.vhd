-- msk_symbol_engine.vhd
--
-- Correlator + V-bank TED + PI timing loop for the Opulent Voice MSK
-- demodulator (Haifuraiya channel rate: 625 ksps, 54.2 kbaud, sps =
-- 11.5314 fractional). First fabric block of the Phase 0 receiver.
--
-- Architecture proven in the fixed-point model (opv_demod_model.py,
-- track_engine): raw integer sample windows (no interpolator), one NCO
-- shared by both tone arms (tone 2 is the conjugate twiddle), integer
-- amax + (3/8)min magnitudes, shift-only PI gains with acquisition gear,
-- position as integer sample + Q16 fraction. Arm unification downstream
-- is a sign flip (gamma = pi): Q_k = -Y2_k * (-1)^k.
--
-- Interface model: the engine addresses a sample memory (ring buffer in
-- the full design; the testbench serves a file). One correlation MAC
-- runs sequentially: 3 windows x wlen samples per symbol (~36 clocks),
-- ample at any fabric clock vs the 625 kHz sample rate.
--
-- Verification: dump-compare against golden_engine.txt produced by the
-- bit-identical Python model. All arithmetic below mirrors the model
-- integer-for-integer (arithmetic right shifts, floor semantics; the
-- sin/cos table is LOADED FROM THE SAME FILE the model used, so no
-- rounding-convention risk exists between the two worlds).
--
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity msk_symbol_engine is
  generic (
    G_LUT_FILE : string  := "lut16.txt";
    G_INC32    : integer := 93114891;    -- NCO increment: 13550/625000 * 2^32
    G_SPS_Q16  : integer := 755720;      -- symbol period in Q16 samples
    G_EL       : integer := 2;           -- early/late offset, whole samples
    G_ACQ_SYMS : integer := 1000;        -- acquisition gear duration
    G_NSAMP    : integer := 60000        -- stimulus length (bench)
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- sample memory interface (int16 I/Q served by ring buffer / bench)
    mem_addr   : out unsigned(23 downto 0);
    mem_i      : in  signed(15 downto 0);
    mem_q      : in  signed(15 downto 0);
    -- per-symbol outputs
    y_valid    : out std_logic;
    y1_re      : out signed(23 downto 0);
    y1_im      : out signed(23 downto 0);
    y2_re      : out signed(23 downto 0);
    y2_im      : out signed(23 downto 0);
    sym_index  : out unsigned(23 downto 0);
    pos_q16    : out unsigned(47 downto 0);   -- debug tap: position word
    dbg_mac    : out std_logic;                -- high during S_MAC
    dbg_a1r    : out signed(39 downto 0);      -- live accumulator
    done       : out std_logic
  );
end entity;

architecture rtl of msk_symbol_engine is

  type lut_t is array (0 to 65535) of signed(15 downto 0);

  impure function load_lut(fname : string; col : integer) return lut_t is
    file f       : text open read_mode is fname;
    variable l   : line;
    variable c,s : integer;
    variable r   : lut_t;
  begin
    for i in 0 to 65535 loop
      readline(f, l);
      read(l, c);
      read(l, s);
      -- files are offset-encoded (value + 32768): no negative literals,
      -- immune to textio negative-integer read quirks
      if col = 0 then r(i) := to_signed(c - 32768, 16);
      else            r(i) := to_signed(s - 32768, 16);
      end if;
    end loop;
    return r;
  end function;

  constant LUT_C : lut_t := load_lut(G_LUT_FILE, 0);
  constant LUT_S : lut_t := load_lut(G_LUT_FILE, 1);

  type state_t is (S_WIN_SETUP, S_MAC, S_WIN_DONE, S_TED, S_ADVANCE, S_DONE);
  signal state : state_t := S_WIN_SETUP;

  -- position and loop state
  signal pos    : unsigned(47 downto 0) := to_unsigned(2, 32) & x"0000";
  signal freq   : signed(31 downto 0) := (others => '0');
  signal k      : unsigned(23 downto 0) := (others => '0');

  -- window sequencing: 0 = early, 1 = on-time, 2 = late
  signal widx   : integer range 0 to 2 := 0;
  signal n_cur  : unsigned(23 downto 0);
  signal n_end  : unsigned(23 downto 0);
  signal wlen   : integer range 0 to 15;

  -- MAC accumulators (16x16 products over <=12 samples: 36 bits is ample)
  signal a1r, a1i, a2r, a2i : signed(39 downto 0);

  -- per-window results: (y1r,y1i,y2r,y2i) x {early,center,late},
  -- plus the previous symbol's triple for the 2T bank
  type yset_t is array (0 to 3) of signed(23 downto 0);
  type wset_t is array (0 to 2) of yset_t;
  signal ycur, yprev : wset_t;
  signal prev_valid  : std_logic := '0';
  signal kprev_odd   : std_logic := '0';

  signal y_valid_i : std_logic := '0';
  signal done_i    : std_logic := '0';
  signal sym_out   : unsigned(23 downto 0) := (others => '0');
  signal pos_out   : unsigned(47 downto 0) := (others => '0');

  -- amax + (3/8)min on 25-bit sums
  function abmag(r, i : signed(24 downto 0)) return signed is
    variable ar, ai, hi, lo : signed(24 downto 0);
    variable res            : signed(27 downto 0);
  begin
    ar := abs(r); ai := abs(i);
    if ar >= ai then hi := ar; lo := ai; else hi := ai; lo := ar; end if;
    res := resize(hi, 28) + shift_right(resize(lo,28) + resize(lo,28)
                                        + resize(lo,28), 3);
    return res;
  end function;

begin

  mem_addr  <= n_cur;
  dbg_mac   <= '1' when state = S_MAC else '0';
  dbg_a1r   <= a1r;
  y_valid   <= y_valid_i;
  done      <= done_i;
  sym_index <= sym_out;
  pos_q16   <= pos_out;

  process(clk)
    -- combinational helpers used sequentially inside the process
    variable p_int   : unsigned(23 downto 0);
    variable ph32    : unsigned(63 downto 0);
    variable ph16    : integer;
    variable c, s    : signed(15 downto 0);
    variable xr, xi  : signed(15 downto 0);
    variable m1, m2, m3, m4 : signed(31 downto 0);
    -- TED variables
    type mag4_t is array (0 to 3) of signed(27 downto 0);
    variable Ae, Ac, Al : mag4_t;
    variable sgp, sgc   : integer;
    variable vr, vi     : signed(24 downto 0);
    variable wbest      : integer;
    variable mbest      : signed(27 downto 0);
    variable err        : signed(31 downto 0);
    variable errg       : signed(33 downto 0);
    variable adj        : signed(31 downto 0);
    variable fnew       : signed(33 downto 0);

    procedure bank(ya, yb : in yset_t; sa, sb : in integer;
                   variable m : out mag4_t) is
      variable q_ar, q_ai, q_br, q_bi : signed(24 downto 0);
      variable a_r, a_i               : signed(24 downto 0);
    begin
      -- sign application by conditional negation: signed*integer in
      -- numeric_std yields a double-width product (25*25 -> 50 bits),
      -- which killed the first bank() call at runtime. Negation is what
      -- the fabric builds anyway.
      if sa = 1 then
        q_ar := resize(ya(2), 25);   q_ai := resize(ya(3), 25);
      else
        q_ar := -resize(ya(2), 25);  q_ai := -resize(ya(3), 25);
      end if;
      if sb = 1 then
        q_br := resize(yb(2), 25);   q_bi := resize(yb(3), 25);
      else
        q_br := -resize(yb(2), 25);  q_bi := -resize(yb(3), 25);
      end if;
      -- V11 = Y1a + Y1b
      a_r := resize(ya(0),25) + resize(yb(0),25);
      a_i := resize(ya(1),25) + resize(yb(1),25);
      m(0) := abmag(a_r, a_i);
      -- V00 = Qa - Qb
      m(1) := abmag(q_ar - q_br, q_ai - q_bi);
      -- V10 = Y1a - Qb
      m(2) := abmag(resize(ya(0),25) - q_br, resize(ya(1),25) - q_bi);
      -- V01 = Qa + Y1b
      m(3) := abmag(q_ar + resize(yb(0),25), q_ai + resize(yb(1),25));
    end procedure;
  begin
    if rising_edge(clk) then
      y_valid_i <= '0';
      if rst = '1' then
        state <= S_WIN_SETUP;
        pos   <= to_unsigned(2, 32) & x"0000";
        freq  <= (others => '0');
        k     <= (others => '0');
        widx  <= 0;
        prev_valid <= '0';
        done_i     <= '0';
      else
        case state is

          when S_WIN_SETUP =>
            p_int := resize(pos(47 downto 16), 24);
            wlen  <= to_integer(resize(
                       resize(pos + to_unsigned(G_SPS_Q16, 48), 48)
                         (47 downto 16), 24) - p_int);
            case widx is
              when 0 => n_cur <= p_int - G_EL;
              when 1 => n_cur <= p_int;
              when 2 => n_cur <= p_int + G_EL;
            end case;
            case widx is
              when 0 => n_end <= p_int - G_EL
                        + to_unsigned(to_integer(resize(
                            resize(pos + to_unsigned(G_SPS_Q16,48),48)
                              (47 downto 16),24) - p_int), 24);
              when 1 => n_end <= p_int
                        + to_unsigned(to_integer(resize(
                            resize(pos + to_unsigned(G_SPS_Q16,48),48)
                              (47 downto 16),24) - p_int), 24);
              when 2 => n_end <= p_int + G_EL
                        + to_unsigned(to_integer(resize(
                            resize(pos + to_unsigned(G_SPS_Q16,48),48)
                              (47 downto 16),24) - p_int), 24);
            end case;
            a1r <= (others=>'0'); a1i <= (others=>'0');
            a2r <= (others=>'0'); a2i <= (others=>'0');
            -- stop condition mirrors the model loop guard
            if to_integer(resize(pos(47 downto 16),32)) + G_EL + 14
               >= G_NSAMP then
              state  <= S_DONE;
            else
              state <= S_MAC;
            end if;

          when S_MAC =>
            -- one sample per clock: phase = (INC32 * n) mod 2^32, top 16
            ph32 := resize(to_unsigned(G_INC32, 32) * resize(n_cur, 32), 64);
            ph16 := to_integer(ph32(31 downto 16));
            c := LUT_C(ph16);  s := LUT_S(ph16);
            xr := mem_i;       xi := mem_q;
            m1 := xr * c;  m2 := xi * s;   -- tone1: e^{-jwn} = (c,-s)
            m3 := xi * c;  m4 := xr * s;
            a1r <= a1r + resize(m1,40) + resize(m2,40);
            a1i <= a1i + resize(m3,40) - resize(m4,40);
            a2r <= a2r + resize(m1,40) - resize(m2,40);
            a2i <= a2i + resize(m3,40) + resize(m4,40);
            if n_cur + 1 = n_end then
              state <= S_WIN_DONE;
            else
              n_cur <= n_cur + 1;
            end if;

          when S_WIN_DONE =>
            ycur(widx)(0) <= resize(shift_right(a1r, 15), 24);
            ycur(widx)(1) <= resize(shift_right(a1i, 15), 24);
            ycur(widx)(2) <= resize(shift_right(a2r, 15), 24);
            ycur(widx)(3) <= resize(shift_right(a2i, 15), 24);
            if widx = 2 then
              widx  <= 0;
              state <= S_TED;
            else
              widx  <= widx + 1;
              state <= S_WIN_SETUP;
            end if;

          when S_TED =>
            -- emit on-time Y for this symbol
            y1_re <= ycur(1)(0);  y1_im <= ycur(1)(1);
            y2_re <= ycur(1)(2);  y2_im <= ycur(1)(3);
            sym_out <= k;          -- snapshot BEFORE increment
            pos_out <= pos;        -- snapshot BEFORE advance
            y_valid_i <= '1';
            adj := (others => '0');
            if prev_valid = '1' then
              if kprev_odd = '0' then sgp := -1; else sgp := 1; end if;
              if k(0) = '0'      then sgc := -1; else sgc := 1; end if;
              bank(yprev(0), ycur(0), sgp, sgc, Ae);
              bank(yprev(1), ycur(1), sgp, sgc, Ac);
              bank(yprev(2), ycur(2), sgp, sgc, Al);
              wbest := 0; mbest := Ac(0);
              for i in 1 to 3 loop
                if Ac(i) > mbest then mbest := Ac(i); wbest := i; end if;
              end loop;
              err := resize(Al(wbest), 32) - resize(Ae(wbest), 32);
              if to_integer(k) < G_ACQ_SYMS then
                errg := resize(shift_left(resize(err, 34), 2), 34);
              else
                errg := resize(err, 34);
              end if;
              fnew := resize(freq, 34) + shift_right(errg, 9);
              if fnew >  3277 then fnew := to_signed( 3277, 34); end if;
              if fnew < -3277 then fnew := to_signed(-3277, 34); end if;
              freq <= resize(fnew, 32);
              adj  := resize(shift_right(errg, 4), 32)
                      + resize(fnew, 32);
              if adj >  131072 then adj := to_signed( 131072, 32); end if;
              if adj < -131072 then adj := to_signed(-131072, 32); end if;
            end if;
            yprev      <= ycur;
            prev_valid <= '1';
            kprev_odd  <= k(0);
            pos <= unsigned(signed(pos)
                   + to_signed(G_SPS_Q16, 48) + resize(adj, 48));
            k   <= k + 1;
            state <= S_WIN_SETUP;

          when S_ADVANCE =>
            state <= S_WIN_SETUP;

          when S_DONE =>
            done_i <= '1';

        end case;
      end if;
    end if;
  end process;

end architecture;
