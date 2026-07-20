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
use work.lut16q_pkg.all;

entity msk_symbol_engine is
  generic (
    G_INC32    : integer := 93114891;    -- NCO increment: 13550/625000 * 2^32
    G_SPS_Q16  : integer := 755720;      -- symbol period in Q16 samples
    G_EL       : integer := 2;           -- early/late offset, whole samples
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
    -- per-symbol EARLY/LATE magnitude export for the symbol lock
    -- detector (normalized early-late gate; Mengali & D'Andrea 1997,
    -- and bit-for-concept identical to the C++ reference TED
    -- (el-ee)/(el+ee), opv_demod.hpp line ~365).  Both values carry the
    -- SAME >> C_ERR_EXPORT_SHR scaling, which CANCELS in the detector's
    -- ratio -- the lock decision is amplitude- and scaling-invariant.
    e_early    : out unsigned(15 downto 0);
    e_late     : out unsigned(15 downto 0);
    e_err_valid: out std_logic;
    -- timing-loop coefficients (register-backed, map v6 0x0C4/0x0C8) and
    -- integrator status (0x0CC).  Loop law = C++ reference verbatim
    -- (opv_demod.hpp:197-199,377-380):
    --   ted            = (L-E)/(L+E)          normalized, Q15 here
    --   adj [Q16 smp]  = ted*ALPHA + clk_off  ALPHA default 0.005 -> Q16 328
    --   clk_off [Q24]  += ted*BETA            BETA  default 1e-5  -> Q24 168
    --   clk_off clamp  = +/-0.1 sample        -> +/-1677722 Q24
    -- SYM_CLK_OFFSET is the integrator: the estimated symbol-clock rate
    -- error between transmitter baud and this receiver's sample clock,
    -- Q24 fractional samples per symbol (ppm = val * 2^-24 / SPS * 1e6).
    cfg_tim_alpha : in  unsigned(15 downto 0);
    cfg_tim_beta  : in  unsigned(15 downto 0);
    sym_clk_offset: out signed(31 downto 0);
    done       : out std_logic
  );
end entity;

architecture rtl of msk_symbol_engine is

  -- export scaling for e_err (see port comment); mirrors the adj arm
  constant C_ERR_EXPORT_SHR : natural := 4;


  -- quarter-wave sin/cos ROM from lut16q_pkg (constants; see pkg header)
  signal QROM : qlut_t := LUT16Q_ROM;
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
                   S_TED_A, S_TED_B, S_TED_DIV, S_TED_C, S_ADVANCE, S_DONE);
  signal state : state_t := S_WIN_SETUP;

  -- position and loop state
  signal pos    : unsigned(47 downto 0) := to_unsigned(2, 32) & x"0000";
  signal freq   : signed(31 downto 0) := (others => '0');  -- Q24 clk offset
  -- serial divider for ted = (|L-E|<<15)/(L+E), exact Q15 (|num|<den always)
  signal div_acc  : unsigned(46 downto 0) := (others => '0');
  signal div_den  : unsigned(31 downto 0) := (others => '0');
  signal div_q    : unsigned(15 downto 0) := (others => '0');
  signal div_cnt  : unsigned(3 downto 0)  := (others => '0');
  signal ted_neg  : std_logic := '0';
  signal e_early_r : unsigned(15 downto 0) := (others => '0');
  signal e_late_r  : unsigned(15 downto 0) := (others => '0');
  signal e_err_v   : std_logic := '0';
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

  sym_clk_offset <= freq;
  e_early     <= e_early_r;
  e_late      <= e_late_r;
  e_err_valid <= e_err_v;


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
  -- (pos updates at the end of the TED sequence, S_TED_C).
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
    variable ted        : signed(16 downto 0);
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
        div_acc <= (others => '0'); div_den <= (others => '0');
        div_q <= (others => '0'); div_cnt <= (others => '0');
        ted_neg <= '0';
        e_early_r <= (others => '0');
        e_late_r  <= (others => '0');
        e_err_v   <= '0';
        k     <= (others => '0');
        widx  <= 0;
        prev_valid <= '0';
        done_i     <= '0';
      elsif hold = '0' then
        e_err_v <= '0';                      -- one-cycle strobe default
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
            -- DECIDE phase part 1: winner + E/L export + divider launch.
            -- Old raw-error PI (gains ~67x/~1000x the C++ reference in
            -- normalized terms; measured 2026-07-20) and the x4
            -- acquisition gear are REMOVED: reference has neither.
            if have_bank = '1' then
              wbest := 0; mbest := ac_r(0);
              for i in 1 to 3 loop
                if ac_r(i) > mbest then mbest := ac_r(i); wbest := i; end if;
              end loop;
              err := resize(al_r(wbest), 32) - resize(ae_r(wbest), 32);
              -- registered early/late export (same shift both: cancels in ratio)
              if shift_right(ae_r(wbest), C_ERR_EXPORT_SHR) > 65535 then
                e_early_r <= (others => '1');
              else
                e_early_r <= resize(unsigned(
                    shift_right(ae_r(wbest), C_ERR_EXPORT_SHR)), 16);
              end if;
              if shift_right(al_r(wbest), C_ERR_EXPORT_SHR) > 65535 then
                e_late_r <= (others => '1');
              else
                e_late_r <= resize(unsigned(
                    shift_right(al_r(wbest), C_ERR_EXPORT_SHR)), 16);
              end if;
              e_err_v <= '1';
              -- divider setup: ted_q15 = (|L-E|<<15)/(L+E), sign separate
              if err < 0 then
                ted_neg <= '1';
                div_acc <= resize(shift_left(resize(unsigned(-err), 47), 15), 47);
              else
                ted_neg <= '0';
                div_acc <= resize(shift_left(resize(unsigned(err), 47), 15), 47);
              end if;
              div_den <= resize(unsigned(resize(al_r(wbest), 32))
                       + unsigned(resize(ae_r(wbest), 32)), 32);
              div_q   <= (others => '0');
              div_cnt <= to_unsigned(15, 4);
              state   <= S_TED_DIV;
            else
              -- no bank yet: advance position at nominal rate, no update
              pos <= pos + to_unsigned(G_SPS_Q16, 48);
              k   <= k + 1;
              state <= S_WIN_SETUP;
            end if;

          when S_TED_DIV =>
            -- restoring divide, one quotient bit per clock, 16 clocks.
            -- Exact: |L-E| <= (L+E) guarantees the Q15 quotient fits.
            if shift_right(div_acc, to_integer(div_cnt))
               >= resize(div_den, 47) then
              div_acc <= div_acc - shift_left(resize(div_den, 47),
                                              to_integer(div_cnt));
              div_q(to_integer(div_cnt)) <= '1';
            end if;
            if div_cnt = 0 then
              state <= S_TED_C;
            else
              div_cnt <= div_cnt - 1;
            end if;

          when S_TED_C =>
            -- DECIDE phase part 2: apply the C++ loop law and advance.
            -- saturate the E=0 corner (quotient 32768) into Q15
            if div_q > 32767 then div_q <= to_unsigned(32767, 16); end if;
            if ted_neg = '1' then
              ted := -signed(resize(div_q, 17));
              if div_q > 32767 then ted := to_signed(-32767, 17); end if;
            else
              ted :=  signed(resize(div_q, 17));
              if div_q > 32767 then ted := to_signed( 32767, 17); end if;
            end if;
            -- integrator: clk_off_q24 += (ted*BETA_Q24)>>15, clamp +/-0.1 smp
            fnew := resize(freq, 34)
                  + resize(shift_right(ted * signed(resize(cfg_tim_beta, 17)), 15), 34);
            if fnew >  1677722 then fnew := to_signed( 1677722, 34); end if;
            if fnew < -1677722 then fnew := to_signed(-1677722, 34); end if;
            freq <= resize(fnew, 32);
            -- proportional + integrator, Q16 samples; RTL guard clamp kept
            adj := resize(shift_right(ted * signed(resize(cfg_tim_alpha, 17)), 15), 32)
                 + resize(shift_right(fnew, 8), 32);
            if adj >  131072 then adj := to_signed( 131072, 32); end if;
            if adj < -131072 then adj := to_signed(-131072, 32); end if;
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
