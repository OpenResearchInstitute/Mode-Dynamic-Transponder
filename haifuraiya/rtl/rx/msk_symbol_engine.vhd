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
    G_LUT_FILE : string  := "lut16q_hex.txt";
    G_INC32    : integer := 93114891;    -- NCO increment: 13550/625000 * 2^32
    G_SPS_Q16  : integer := 755720;      -- symbol period in Q16 samples
    G_EL       : integer := 2;           -- early/late offset, whole samples
    G_ACQ_SYMS : integer := 1000;        -- acquisition gear duration
    G_NSAMP    : integer := 60000        -- stimulus length (bench)
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- stall: freeze the FSM (ring buffer paces the engine against
    -- sample arrival in the streaming system; benches leave it '0')
    hold       : in  std_logic := '0';
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


  -- quarter-wave sin/cos ROM, hex-packed (UG901 synthesizable idiom):
  -- one 32-bit word per line, cos(31:16) & sin(15:0), two's complement.
  -- Reconstruction proven bit-exact over all 65536 phases (session 8).
  type qlut_t is array (0 to 16384) of std_logic_vector(31 downto 0);

  impure function load_qlut(fname : string) return qlut_t is
    file f     : text open read_mode is fname;
    variable l : line;
    variable v : std_logic_vector(31 downto 0);
    variable r : qlut_t;
  begin
    for i in 0 to 16384 loop
      readline(f, l);
      hread(l, v);
      r(i) := v;
    end loop;
    return r;
  end function;

  -- QROM as a SIGNAL (never written): rom_style attributes on constants
  -- are ignored by synthesis (warning 8-5733); on signals they are honored
  -- and BRAM mapping becomes deterministic instead of lucky.
  signal QROM : qlut_t := load_qlut(G_LUT_FILE);
  attribute rom_style : string;
  attribute rom_style of QROM : signal is "block";

  -- synchronous ROM access: fold the 16-bit phase into quarter-table
  -- address + output signs (slices only -- no divide, no mod)
  signal rom_q    : std_logic_vector(31 downto 0) := (others => '0');
  signal cneg_d, sneg_d : std_logic := '0';   -- sign flags, ROM-aligned
  signal xr_d, xi_d     : signed(15 downto 0) := (others => '0');

  procedure fold_phase(ph            : in  unsigned(15 downto 0);
                       variable addr : out unsigned(14 downto 0);
                       variable cneg : out std_logic;
                       variable sneg : out std_logic) is
    variable q : unsigned(13 downto 0);
  begin
    q := ph(13 downto 0);
    case to_integer(ph(15 downto 14)) is
      when 0 =>
        addr := resize(q, 15);                     cneg := '0'; sneg := '0';
      when 1 =>
        addr := to_unsigned(16384, 15) - resize(q, 15);
        cneg := '1'; sneg := '0';
      when 2 =>
        addr := resize(q, 15);                     cneg := '1'; sneg := '1';
      when others =>
        addr := to_unsigned(16384, 15) - resize(q, 15);
        cneg := '0'; sneg := '1';
    end case;
  end procedure;

  type state_t is (S_WIN_SETUP, S_MAC_A, S_MAC_B, S_WIN_DONE,
                   S_TED_A, S_TED_B, S_ADVANCE, S_DONE);
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

  -- TED pipeline: bank magnitudes registered between compute and decide
  type mag4_r is array (0 to 3) of signed(27 downto 0);
  signal ae_r, ac_r, al_r : mag4_r := (others => (others => '0'));
  signal have_bank : std_logic := '0';

  signal y_valid_i : std_logic := '0';
  signal done_i    : std_logic := '0';
  signal sym_out   : unsigned(23 downto 0) := (others => '0');

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
  dbg_mac   <= '1' when state = S_MAC_B else '0';
  dbg_a1r   <= a1r;
  y_valid   <= y_valid_i;
  done      <= done_i;
  sym_index <= sym_out;
  -- LIVE position, not a snapshot: the wrapper's ring-buffer stall
  -- logic gates on this, and a stale value releases the engine into
  -- unwritten memory (the symbol-1 zeros bug, session 8). At the
  -- y_valid sampling instant, live pos equals the old snapshot exactly
  -- (pos updates at the END of S_TED_B), so bench dumps are unchanged.
  pos_q16   <= pos;

  process(clk)
    -- combinational helpers used sequentially inside the process
    variable p_int   : unsigned(23 downto 0);
    variable ph32    : unsigned(63 downto 0);
    variable vaddr   : unsigned(14 downto 0);
    variable vcneg, vsneg : std_logic;
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
        -- (reset body continues below)
        freq  <= (others => '0');
        k     <= (others => '0');
        widx  <= 0;
        prev_valid <= '0';
        done_i     <= '0';
      elsif hold = '0' then
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
              state <= S_MAC_A;
            end if;

          when S_MAC_A =>
            -- address phase: fold NCO phase, register ROM output next
            -- edge; capture the sample pair aligned with the ROM data
            ph32 := resize(to_unsigned(G_INC32, 32) * resize(n_cur, 32), 64);
            fold_phase(unsigned(ph32(31 downto 16)), vaddr, vcneg, vsneg);
            -- synchronous ROM read in the address phase: data registered
            -- on THIS edge, valid when S_MAC_B executes next edge
            rom_q  <= QROM(to_integer(vaddr));
            cneg_d <= vcneg;
            sneg_d   <= vsneg;
            xr_d     <= mem_i;
            xi_d     <= mem_q;
            state    <= S_MAC_B;

          when S_MAC_B =>
            -- accumulate phase: ROM data (registered) + aligned sample
            if cneg_d = '0' then c :=  signed(rom_q(31 downto 16));
            else                 c := -signed(rom_q(31 downto 16));
            end if;
            if sneg_d = '0' then s :=  signed(rom_q(15 downto 0));
            else                 s := -signed(rom_q(15 downto 0));
            end if;
            xr := xr_d;        xi := xi_d;
            m1 := xr * c;  m2 := xi * s;
            m3 := xi * c;  m4 := xr * s;
            a1r <= a1r + resize(m1,40) + resize(m2,40);
            a1i <= a1i + resize(m3,40) - resize(m4,40);
            a2r <= a2r + resize(m1,40) - resize(m2,40);
            a2i <= a2i + resize(m3,40) + resize(m4,40);
            if n_cur + 1 = n_end then
              state <= S_WIN_DONE;
            else
              n_cur <= n_cur + 1;
              state <= S_MAC_A;
            end if;

          when S_WIN_DONE =>
            ycur(widx)(0) <= resize(shift_right(a1r, 15), 24);
            ycur(widx)(1) <= resize(shift_right(a1i, 15), 24);
            ycur(widx)(2) <= resize(shift_right(a2r, 15), 24);
            ycur(widx)(3) <= resize(shift_right(a2i, 15), 24);
            if widx = 2 then
              widx  <= 0;
              state <= S_TED_A;
            else
              widx  <= widx + 1;
              state <= S_WIN_SETUP;
            end if;

          when S_TED_A =>
            -- COMPUTE phase: emit Y, build the three banks, register
            -- the twelve magnitudes; symbol bookkeeping that the banks
            -- consumed (yprev, kprev_odd) also rotates here
            y1_re <= ycur(1)(0);  y1_im <= ycur(1)(1);
            y2_re <= ycur(1)(2);  y2_im <= ycur(1)(3);
            sym_out <= k;          -- snapshot BEFORE increment
            y_valid_i <= '1';
            if prev_valid = '1' then
              if kprev_odd = '0' then sgp := -1; else sgp := 1; end if;
              if k(0) = '0'      then sgc := -1; else sgc := 1; end if;
              bank(yprev(0), ycur(0), sgp, sgc, Ae);
              bank(yprev(1), ycur(1), sgp, sgc, Ac);
              bank(yprev(2), ycur(2), sgp, sgc, Al);
              for i in 0 to 3 loop
                ae_r(i) <= Ae(i);  ac_r(i) <= Ac(i);  al_r(i) <= Al(i);
              end loop;
            end if;
            have_bank  <= prev_valid;
            yprev      <= ycur;
            prev_valid <= '1';
            kprev_odd  <= k(0);
            state <= S_TED_B;

          when S_TED_B =>
            -- DECIDE phase: winner, error, PI, position advance
            adj := (others => '0');
            if have_bank = '1' then
              wbest := 0; mbest := ac_r(0);
              for i in 1 to 3 loop
                if ac_r(i) > mbest then mbest := ac_r(i); wbest := i; end if;
              end loop;
              err := resize(al_r(wbest), 32) - resize(ae_r(wbest), 32);
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
