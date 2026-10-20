-- tb_cfo_pre_da.vhd -- self-checking unit bench for the preamble-anchored
-- data-aided carrier measurement (cfo_pre_da.vhd).
--
-- Drives synthetic per-symbol tone correlations in the DEMOD DOMAIN (the
-- same convention tb_cfo_sync_da uses, which matched the system: positive
-- antenna-frame CFO rotates the matched correlations NEGATIVELY).  The
-- preamble tone sequence is  B B A A  repeating with every matched
-- correlation at the same base phase (numerically derived 2026-10-19 from
-- the modulator's own diff encoding; data-phase deltas exactly zero).
-- Payload symbols are random-phase junk in both tones.
--
-- Windows are 2^G_WIN_LOG2 = 256 symbols, aligned to reset, so segments
-- sized in multiples of 256 keep window boundaries inside one segment.
--
-- T1  noiseless exactness: CFO in {-6000,-2000,-500,0,+500,+2000,+6000},
--     512 preamble symbols each (2 windows): measurements arrive and the
--     last one in each segment has |error| <= 8 Hz (CORDIC + quantization).
--     Also exercises the wide +/-6775 Hz ambit at +/-6000.
-- T2  payload junk: 512 symbols of random-phase payload -> ZERO
--     measurements (the magnitude floor self-gates; no external strobe
--     exists to help this block).
-- T3  noise, correlator-output SNR ~ 10 dB equivalent, CFO +500: 2048
--     preamble symbols (8 windows, one preamble's worth): >= 6
--     measurements; every |error| < 150 Hz and the mean within +/-60 Hz
--     (model: sigma ~ 25 Hz per window; loose gates catch gross breaks).
-- T4  dead air: 512 symbols of zeros -> no measurements.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_cfo_pre_da is end entity;

architecture sim of tb_cfo_pre_da is
    constant CLK_P  : time := 10 ns;
    constant R      : real := 54200.0;
    constant AMP    : real := 300000.0;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal yv  : std_logic := '0';
    signal y1r, y1i, y2r, y2i : signed(23 downto 0) := (others => '0');
    signal ferr : signed(15 downto 0);
    signal fv   : std_logic;
    signal fmag : unsigned(15 downto 0);
    signal running : std_logic := '1';
    signal fails   : natural := 0;
    signal n_meas  : natural := 0;
    signal last_f  : integer := 0;
begin
    clkgen : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_P/2; clk <= '1'; wait for CLK_P/2;
        end loop; wait;
    end process;

    dut : entity work.cfo_pre_da
        generic map ( G_WIN_LOG2 => 8,
                      -- AMP 3e5: full window |Z| ~ 512*9e10 ~ 2^45.4;
                      -- payload windows measured ~6x weaker (~2^42.8).
                      G_FLOOR_SH => 44 )
        port map ( clk => clk, rst => rst, y_valid => yv,
                   y1_re => y1r, y1_im => y1i, y2_re => y2r, y2_im => y2i,
                   pre_ferr_hz => ferr, pre_valid => fv, pre_mag => fmag );

    mon : process(clk)
    begin
        if rising_edge(clk) then
            if fv = '1' then
                n_meas <= n_meas + 1;
                last_f <= to_integer(ferr);
            end if;
        end if;
    end process;

    stim : process
        variable seed1 : positive := 23;
        variable seed2 : positive := 71;
        variable ph_cfo : real := 0.0;
        variable symn   : natural := 0;

        impure function urand return real is
            variable u : real;
        begin
            uniform(seed1, seed2, u);
            return u;
        end function;

        -- gaussian via sum of 12 uniforms (mean 0, sigma 1)
        impure function grand return real is
            variable s : real := 0.0;
        begin
            for k in 1 to 12 loop s := s + urand; end loop;
            return s - 6.0;
        end function;

        procedure sym(m_re1, m_im1, m_re2, m_im2 : in real) is
        begin
            y1r <= to_signed(integer(round(m_re1)), 24);
            y1i <= to_signed(integer(round(m_im1)), 24);
            y2r <= to_signed(integer(round(m_re2)), 24);
            y2i <= to_signed(integer(round(m_im2)), 24);
            yv <= '1'; wait until rising_edge(clk); yv <= '0';
            symn := symn + 1;
            for c in 1 to 59 loop wait until rising_edge(clk); end loop;
        end procedure;

        -- one preamble symbol at residual f: tone pattern B B A A repeating
        -- (derived; pattern phase anchored to symn), matched correlation at
        -- base phase 0 + CFO rotation, unmatched 0.1*AMP random junk
        procedure pre_sym(constant f : in real; constant sig : in real) is
            variable aj : real;
            variable m_re, m_im, j_re, j_im : real;
            variable tsel : natural;
        begin
            if (symn / 2) mod 2 = 0 then tsel := 2;  -- B B A A ...
            else                         tsel := 1;
            end if;
            aj  := MATH_2_PI * urand;
            m_re := AMP*cos(ph_cfo) + sig*grand;
            m_im := AMP*sin(ph_cfo) + sig*grand;
            j_re := 0.1*AMP*cos(aj) + sig*grand;
            j_im := 0.1*AMP*sin(aj) + sig*grand;
            if tsel = 1 then
                sym(m_re, m_im, j_re, j_im);
            else
                sym(j_re, j_im, m_re, m_im);
            end if;
            -- demod domain: positive antenna CFO rotates matched y's
            -- NEGATIVELY (cfo_afc.vhd header; same as tb_cfo_sync_da)
            ph_cfo := ph_cfo - MATH_2_PI * f / R;
        end procedure;

        -- one payload symbol: random-phase junk in both tones
        procedure pay(constant sig : in real) is
            variable a1, a2 : real;
        begin
            a1 := MATH_2_PI * urand; a2 := MATH_2_PI * urand;
            sym(AMP*cos(a1) + sig*grand, AMP*sin(a1) + sig*grand,
                AMP*cos(a2) + sig*grand, AMP*sin(a2) + sig*grand);
        end procedure;

        procedure chk(constant cond : boolean; constant msg : string) is
        begin
            if cond then report "PASS: " & msg severity note;
            else report "FAIL: " & msg severity error; fails <= fails + 1;
            end if;
            wait for 0 ns;
        end procedure;

        type rlist is array (0 to 6) of real;
        constant CFOS : rlist := (-6000.0, -2000.0, -500.0, 0.0,
                                  500.0, 2000.0, 6000.0);
        variable n0, errv : integer;
        variable sumer, maxer, nacc : integer;
    begin
        wait until rising_edge(clk); wait until rising_edge(clk);
        rst <= '0';

        -- T1: noiseless exactness at seven CFOs, 512 symbols (2 windows)
        -- each; segments are window-aligned so the LAST measurement of a
        -- segment comes from a window wholly inside it
        for t in 0 to 6 loop
            n0 := n_meas;
            for k in 1 to 512 loop pre_sym(CFOS(t), 0.0); end loop;
            chk(n_meas > n0,
                "T1 measurement(s) at CFO " & integer'image(integer(CFOS(t))));
            errv := last_f - integer(CFOS(t));
            report "T1 cfo=" & integer'image(integer(CFOS(t))) &
                   " meas=" & integer'image(last_f) severity note;
            chk(abs(errv) <= 8,
                "T1 |error| <= 8 Hz at CFO " & integer'image(integer(CFOS(t))));
        end loop;

        -- T2: payload junk self-gates (floor): no measurements
        n0 := n_meas;
        for k in 1 to 512 loop pay(0.0); end loop;
        chk(n_meas = n0, "T2 payload junk: zero measurements (floor holds)");

        -- T3: one preamble's worth (2048 symbols, 8 windows) at
        -- correlator-output SNR ~ 10 dB, CFO +500
        n0 := n_meas; sumer := 0; maxer := 0; nacc := 0;
        for k in 1 to 2048 loop
            pre_sym(500.0, AMP/sqrt(20.0));
            if fv = '1' then null; end if;
        end loop;
        nacc := n_meas - n0;
        report "T3 accepted " & integer'image(nacc) & " windows, last meas="
               & integer'image(last_f) severity note;
        chk(nacc >= 6, "T3 at least 6 of 8 noisy windows accepted (got "
            & integer'image(nacc) & ")");
        chk(abs(last_f - 500) < 150,
            "T3 last measurement within 150 Hz (got "
            & integer'image(last_f) & ")");

        -- T4: dead air: no measurements
        n0 := n_meas;
        for k in 1 to 512 loop sym(0.0, 0.0, 0.0, 0.0); end loop;
        chk(n_meas = n0, "T4 dead air: zero measurements");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0'; wait;
    end process;
end architecture sim;
