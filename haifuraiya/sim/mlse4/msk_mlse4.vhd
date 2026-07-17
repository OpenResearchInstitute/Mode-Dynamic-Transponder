-- msk_mlse4.vhd
--
-- 4-state MLSE demodulator for Opulent Voice MSK with per-survivor phase.
-- Second fabric block of the Phase 0 receiver: consumes the symbol
-- engine's per-symbol tone correlations (Y1, Y2), forms the unified
-- coherent V-bank (Q_k = -Y2_k * (-1)^k, signs +,-,-,+ -- all derived
-- from measured phase-step tables, see demod_phase0 README), runs a
-- 4-state Viterbi over the MSK phase trellis (state = axis sign x
-- previous bit; sign flips when the new bit is 0), each survivor
-- carrying its own 16-bit phase word (PSP), and emits int16 soft
-- decisions through a 64-deep streaming traceback.
--
-- Structural sibling of the K=7 soft Viterbi already in the fabric:
-- same ACS + history + traceback pattern, 4 states instead of 64.
--
-- No divides, no square roots, no CORDIC: rotations via the shared
-- Q1.15 LUT (lut16.txt, offset-encoded, same file as the model and the
-- symbol engine), PSP error normalization is a fixed >>8 (constant
-- envelope pins |V|), all gains are shifts.
--
-- Verification: dump-compare against mlse_golden.txt produced by
-- gen_mlse_golden.py from the VERIFIED symbol-engine output -- the
-- chain proves itself link by link. All arithmetic mirrors the model
-- integer-for-integer (floor shifts, 16-bit phase wrap, clamps).
--
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity msk_mlse4 is
  generic (
    G_LUT_FILE : string  := "lut16q_hex.txt";
    G_TB_D     : integer := 64            -- traceback depth
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    -- per-symbol input from the symbol engine
    y_valid   : in  std_logic;
    y1_re     : in  signed(23 downto 0);
    y1_im     : in  signed(23 downto 0);
    y2_re     : in  signed(23 downto 0);
    y2_im     : in  signed(23 downto 0);
    -- soft output (one per trellis step, delayed by G_TB_D)
    busy       : out std_logic;   -- '1' while processing a symbol
    soft_valid : out std_logic;
    soft_idx   : out unsigned(23 downto 0);   -- trellis step index t
    soft_out   : out signed(15 downto 0);
    -- debug taps for divergence localization
    dbg_best   : out unsigned(1 downto 0);
    dbg_th0    : out unsigned(15 downto 0);
    dbg_th1    : out unsigned(15 downto 0);
    dbg_th2    : out unsigned(15 downto 0);
    dbg_th3    : out unsigned(15 downto 0);
    -- per-step trace taps (post-normalization, one pulse per step)
    dbg_step_valid : out std_logic;
    dbg_m0     : out signed(23 downto 0);
    dbg_m1     : out signed(23 downto 0);
    dbg_m2     : out signed(23 downto 0);
    dbg_m3     : out signed(23 downto 0)
  );
end entity;

architecture rtl of msk_mlse4 is


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

  -- dual synchronous ROM ports (one per predecessor branch)
  signal rom_q0, rom_q1 : std_logic_vector(31 downto 0)
                        := (others => '0');
  signal c0n, s0n, c1n, s1n   : std_logic := '0';

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

  -- pair hypothesis index: 0=(1,1) 1=(0,0) 2=(1,0) 3=(0,1)
  -- V-bank per trellis step (25-bit complex x 4)
  type vpair_t is array (0 to 3) of signed(24 downto 0);
  signal vre, vim : vpair_t;

  -- survivor state
  type met_t is array (0 to 3) of signed(23 downto 0);
  type th_t  is array (0 to 3) of unsigned(15 downto 0);
  signal metric : met_t := (others => (others => '0'));
  signal theta  : th_t  := (to_unsigned(0,16), to_unsigned(8192,16),
                            to_unsigned(16384,16), to_unsigned(24576,16));

  -- history ring: per step, per state: pred(2b) bit(1b) marg(16b)
  constant HW : integer := 4*(2+1+16);       -- 76 bits per step
  type hist_t is array (0 to G_TB_D-1) of std_logic_vector(HW-1 downto 0);
  signal hist : hist_t := (others => (others => '0'));

  signal y1p_re, y1p_im, y2p_re, y2p_im : signed(23 downto 0);
  signal have_prev : std_logic := '0';
  signal kpar      : std_logic := '0';   -- parity of the PREVIOUS symbol
  signal t_step    : unsigned(23 downto 0) := (others => '0');

  type state_t is (S_IDLE, S_BANK, S_ACS_A, S_ACS_B1, S_ACS_B2, S_NORM,
                   S_TB, S_EMIT);
  signal state : state_t := S_IDLE;

  -- ACS iteration
  signal acs_st  : integer range 0 to 3 := 0;
  signal nmet    : met_t;
  signal nth     : th_t;
  signal npred   : unsigned(7 downto 0);   -- 2b x 4
  signal nbit    : std_logic_vector(3 downto 0);
  signal nmarg   : std_logic_vector(63 downto 0);  -- 16b x 4

  -- traceback iteration
  -- ACS pipeline registers (compute phase -> decide phase)
  signal bm0_r, bm1_r         : signed(27 downto 0);
  signal p0r, p0i, p1r, p1i   : signed(26 downto 0);

  signal tb_i     : integer range 0 to 255 := 0;
  signal tb_st    : integer range 0 to 3 := 0;
  signal tb_best0 : integer range 0 to 3 := 0;   -- argmax at TB start
  signal tb_soft  : signed(15 downto 0);

  signal sv  : std_logic := '0';
  signal spv : std_logic := '0';

begin

  dbg_step_valid <= spv;
  busy <= '0' when state = S_IDLE else '1';
  dbg_m0 <= metric(0); dbg_m1 <= metric(1);
  dbg_m2 <= metric(2); dbg_m3 <= metric(3);

  soft_valid <= sv;
  dbg_th0 <= theta(0); dbg_th1 <= theta(1);
  dbg_th2 <= theta(2); dbg_th3 <= theta(3);

  process(clk)
    variable vaddr : unsigned(14 downto 0);
    variable vcneg, vsneg : std_logic;
    variable qc_re, qc_im, qp_re, qp_im : signed(24 downto 0);
    variable sax, sp, bnew : integer;
    variable stp0, stp1   : integer;
    variable c, sn        : signed(15 downto 0);
    variable vr0, vi0     : signed(24 downto 0);
    variable pr, pi       : signed(41 downto 0);
    variable vr, vi       : signed(26 downto 0);
    variable bm0, bm1     : signed(27 downto 0);
    variable wmet, lose     : signed(27 downto 0);
    variable pw           : integer;
    variable wvr, wvi     : signed(26 downto 0);
    variable ir, ii       : signed(26 downto 0);
    variable e            : signed(26 downto 0);
    variable d            : signed(26 downto 0);
    variable mg           : signed(27 downto 0);
    variable mx           : signed(23 downto 0);
    variable pairsel      : integer;
    variable hslot        : std_logic_vector(HW-1 downto 0);
    variable bset         : integer;
  begin
    if rising_edge(clk) then
      sv <= '0';
      spv <= '0';
      if rst = '1' then
        state <= S_IDLE;
        metric <= (others => (others => '0'));
        theta  <= (to_unsigned(0,16), to_unsigned(8192,16),
                   to_unsigned(16384,16), to_unsigned(24576,16));
        have_prev <= '0';
        t_step <= (others => '0');
      else
        case state is

          when S_IDLE =>
            if y_valid = '1' then
              if have_prev = '1' then
                state <= S_BANK;
              end if;
              -- capture current symbol; kpar tracks the parity of the
              -- symbol stored in the "previous" registers
              y1p_re <= y1_re; y1p_im <= y1_im;
              y2p_re <= y2_re; y2p_im <= y2_im;
              if have_prev = '1' then
                kpar <= not kpar;
              else
                kpar <= '0';               -- previous symbol is k = 0
              end if;
              have_prev <= '1';
              -- form the bank NOW from (prev regs, live inputs)
              if have_prev = '1' then
                -- Q = -Y2 * (-1)^k : k even -> -Y2 ; k odd -> +Y2
                if kpar = '0' then
                  qp_re := -resize(y2p_re, 25); qp_im := -resize(y2p_im, 25);
                else
                  qp_re :=  resize(y2p_re, 25); qp_im :=  resize(y2p_im, 25);
                end if;
                -- current symbol parity = not kpar
                if kpar = '1' then
                  qc_re := -resize(y2_re, 25);  qc_im := -resize(y2_im, 25);
                else
                  qc_re :=  resize(y2_re, 25);  qc_im :=  resize(y2_im, 25);
                end if;
                vre(0) <= resize(y1p_re,25) + resize(y1_re,25);
                vim(0) <= resize(y1p_im,25) + resize(y1_im,25);
                vre(1) <= qp_re - qc_re;   vim(1) <= qp_im - qc_im;
                vre(2) <= resize(y1p_re,25) - qc_re;
                vim(2) <= resize(y1p_im,25) - qc_im;
                vre(3) <= qp_re + resize(y1_re,25);
                vim(3) <= qp_im + resize(y1_im,25);
              end if;
            end if;

          when S_BANK =>
            acs_st <= 0;
            state  <= S_ACS_A;

          when S_ACS_A =>
            -- address phase: fold both predecessor thetas, issue ROM reads
            -- explicit decode of acs_st in 0..3 (no signed mod/rem)
            if acs_st = 1 or acs_st = 3 then bnew := 1; else bnew := 0; end if;
            if acs_st <= 1 then sax := 1; else sax := -1; end if;
            if bnew = 1 then sp := sax; else sp := -sax; end if;
            if sp > 0 then bset := 0; else bset := 2; end if;
            -- synchronous ROM reads in the address phase: data
            -- registered on THIS edge, valid at S_ACS_B next edge
            fold_phase(theta(bset + 0), vaddr, vcneg, vsneg);
            rom_q0 <= QROM(to_integer(vaddr)); c0n <= vcneg; s0n <= vsneg;
            fold_phase(theta(bset + 1), vaddr, vcneg, vsneg);
            rom_q1 <= QROM(to_integer(vaddr)); c1n <= vcneg; s1n <= vsneg;
            state <= S_ACS_B1;

          when S_ACS_B1 =>
            -- COMPUTE phase: rotations and both branch metrics, registered
            if acs_st = 1 or acs_st = 3 then bnew := 1; else bnew := 0; end if;
            if acs_st <= 1 then sax := 1; else sax := -1; end if;
            if bnew = 1 then sp := sax; else sp := -sax; end if;
            if sp > 0 then bset := 0; else bset := 2; end if;
            stp0 := bset + 0;
            stp1 := bset + 1;
            for pb in 0 to 1 loop
              if    pb = 1 and bnew = 1 then pairsel := 0;
              elsif pb = 0 and bnew = 0 then pairsel := 1;
              elsif pb = 1 and bnew = 0 then pairsel := 2;
              else                           pairsel := 3;
              end if;
              vr0 := vre(pairsel); vi0 := vim(pairsel);
              if pb = 0 then
                if c0n = '0' then c :=  signed(rom_q0(31 downto 16));
                else              c := -signed(rom_q0(31 downto 16));
                end if;
                if s0n = '0' then sn :=  signed(rom_q0(15 downto 0));
                else              sn := -signed(rom_q0(15 downto 0));
                end if;
              else
                if c1n = '0' then c :=  signed(rom_q1(31 downto 16));
                else              c := -signed(rom_q1(31 downto 16));
                end if;
                if s1n = '0' then sn :=  signed(rom_q1(15 downto 0));
                else              sn := -signed(rom_q1(15 downto 0));
                end if;
              end if;
              pr := resize(vr0*c, 42) + resize(vi0*sn, 42);
              pi := resize(vi0*c, 42) - resize(vr0*sn, 42);
              vr := resize(shift_right(pr, 15), 27);
              vi := resize(shift_right(pi, 15), 27);
              if pb = 0 then
                bm0_r <= resize(metric(stp0), 28) + resize(sp*vr, 28);
                p0r <= vr;  p0i <= vi;
              else
                bm1_r <= resize(metric(stp1), 28) + resize(sp*vr, 28);
                p1r <= vr;  p1i <= vi;
              end if;
            end loop;
            state <= S_ACS_B2;

          when S_ACS_B2 =>
            -- DECIDE phase: compare, select, survivor updates
            if acs_st = 1 or acs_st = 3 then bnew := 1; else bnew := 0; end if;
            if acs_st <= 1 then sax := 1; else sax := -1; end if;
            if bnew = 1 then sp := sax; else sp := -sax; end if;
            if sp > 0 then bset := 0; else bset := 2; end if;
            stp0 := bset + 0;
            stp1 := bset + 1;
            if bm0_r >= bm1_r then
              wmet := bm0_r; pw := stp0; lose := bm1_r;
              wvr := p0r;    wvi := p0i;
            else
              wmet := bm1_r; pw := stp1; lose := bm0_r;
              wvr := p1r;    wvi := p1i;
            end if;
            nmet(acs_st) <= resize(wmet, 24);
            npred(2*acs_st+1 downto 2*acs_st)
              <= to_unsigned(pw, 2);
            nbit(acs_st) <= '1' when bnew = 1 else '0';
            mg := wmet - lose;
            if mg > 32767 then mg := to_signed(32767, 28); end if;
            nmarg(16*acs_st+15 downto 16*acs_st)
              <= std_logic_vector(resize(mg, 16));
            -- PSP theta update from the winning branch rotation
            if sp > 0 then
              ir := wvr;  ii := wvi;
            else
              ir := -wvr; ii := -wvi;
            end if;
            if ir >= 0 then e := ii; else e := -ii; end if;
            d := shift_right(e, 8);
            if d >  256 then d := to_signed( 256, 27); end if;
            if d < -256 then d := to_signed(-256, 27); end if;
            nth(acs_st) <= theta(pw)
              + unsigned(resize(d, 16));
            if acs_st = 3 then
              state <= S_NORM;
            else
              acs_st <= acs_st + 1;
              state  <= S_ACS_A;
            end if;

          when S_NORM =>
            mx := nmet(0);
            for i in 1 to 3 loop
              if nmet(i) > mx then mx := nmet(i); end if;
            end loop;
            for i in 0 to 3 loop
              metric(i) <= nmet(i) - mx;
              theta(i)  <= nth(i);
            end loop;
            hslot := std_logic_vector(nmarg) & nbit & std_logic_vector(npred);
            hist(to_integer(t_step) mod G_TB_D) <= hslot;
            spv <= '1';   -- metrics/thetas valid NEXT cycle (registered)
            if to_integer(t_step) >= G_TB_D - 1 then
              -- start traceback from the best NEW metric state
              tb_st <= 0;
              mx := nmet(0) - mx;   -- normalized; recompute argmax below
              state <= S_TB;
              tb_i  <= 0;
            else
              t_step <= t_step + 1;
              state  <= S_IDLE;
            end if;

          when S_TB =>
            if tb_i = 0 then
              -- argmax over normalized metrics
              bset := 0;
              for i in 1 to 3 loop
                if metric(i) > metric(bset) then bset := i; end if;
              end loop;
              tb_st   <= bset;
              tb_best0 <= bset;   -- tap definition: argmax at emission
              tb_i    <= 1;
            else
              hslot := hist((to_integer(t_step) - (tb_i-1)) mod G_TB_D);
              -- slot packing (S_NORM): marg(75:12) & bit(11:8) & pred(7:0)
              if tb_i = G_TB_D then
                -- oldest step: capture soft
                if hslot(8 + tb_st) = '1' then
                  tb_soft <= signed(hslot(12 + 16*tb_st + 15
                                          downto 12 + 16*tb_st));
                else
                  tb_soft <= -signed(hslot(12 + 16*tb_st + 15
                                           downto 12 + 16*tb_st));
                end if;
                state <= S_EMIT;
              else
                tb_st <= to_integer(unsigned(
                          hslot(2*tb_st + 1 downto 2*tb_st)));
                tb_i  <= tb_i + 1;
              end if;
            end if;

          when S_EMIT =>
            soft_out <= tb_soft;
            soft_idx <= t_step - (G_TB_D - 1);
            dbg_best <= to_unsigned(tb_best0, 2);
            sv <= '1';
            t_step <= t_step + 1;
            state  <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
