-- tb_cfo_sync_da.vhd -- self-checking unit bench for the sync-anchored
-- data-aided carrier measurement (cfo_sync_da.vhd).
--
-- Drives synthetic per-symbol tone correlations.  The matched correlator
-- phases across the sync word are EXACT quadrants (numerically derived
-- 2026-10-18 from the modulator's own diff encoding; invariant over all
-- data histories):
--   PHI  = 0 0 0 0 0 0 2 2 0 0 2 2 2 2 2 2 0 0 2 2 2 2 0 0  (x pi/2)
--   TONE = A A A A A A B A B A B B B A A A B B A B B A B B
-- A matched y rotates additionally at the residual CFO; the unmatched
-- tone's y is low-level junk.  Payload symbols are random-phase junk in
-- both tones (worst case for false structure).  The bench emulates the
-- frame sync detector's sync_verified strobe LAT symbols after each sync
-- word's last symbol.
--
-- T1  noiseless exactness: CFO in {-2000,-500,0,+500,+2000}, one frame
--     each: every strobe yields |da_ferr - CFO| <= 8 Hz (CORDIC + Hz
--     quantization), one strobe per frame, sign convention asserted.
-- T2  no strobe, no output: a frame's sync passes WITHOUT sync_seen ->
--     no da_valid (detector gates measurement).
-- T3  noise, Eb/N0 ~ 10 dB equivalent on the correlations, CFO +500:
--     12 syncs; every |error| < 350 Hz and the mean within +/-120 Hz
--     (sigma_model = 84 Hz; loose gates catch gross breaks, the
--     statistics live in the design note).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_cfo_sync_da is end entity;

architecture sim of tb_cfo_sync_da is
    constant CLK_P  : time := 10 ns;
    constant R      : real := 54200.0;
    constant AMP    : real := 300000.0;
    constant LAT    : natural := 40;    -- emulated detector latency (symbols)
    constant PAYSYM : natural := 300;   -- payload symbols between syncs

    type int_v24 is array (0 to 23) of integer;
    constant PHI  : int_v24 := (0,0,0,0,0,0,2,2,0,0,2,2,
                                2,2,2,2,0,0,2,2,2,2,0,0);
    constant TONE : int_v24 := (1,1,1,1,1,1,2,1,2,1,2,2,
                                2,1,1,1,2,2,1,2,2,1,2,2);

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal yv  : std_logic := '0';
    signal y1r, y1i, y2r, y2i : signed(23 downto 0) := (others => '0');
    signal ss  : std_logic := '0';
    signal ferr : signed(15 downto 0);
    signal fv   : std_logic;
    signal fmag : unsigned(15 downto 0);
    signal running : std_logic := '1';
    signal fails   : natural := 0;
    -- strobe bookkeeping (captured by a monitor process)
    signal n_meas  : natural := 0;
    signal last_f  : integer := 0;
begin
    clkgen : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_P/2; clk <= '1'; wait for CLK_P/2;
        end loop; wait;
    end process;

    dut : entity work.cfo_sync_da
        generic map ( G_FLOOR_SH => 36,   -- AMP 3e5: peak |Z| ~ 2^39.2
                      G_LAT_SYM  => LAT,
                      G_LAT_WIN  => 12 )
        port map ( clk => clk, rst => rst, y_valid => yv,
                   y1_re => y1r, y1_im => y1i, y2_re => y2r, y2_im => y2i,
                   sync_seen => ss,
                   da_ferr_hz => ferr, da_valid => fv, da_mag => fmag );

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
        variable seed1 : positive := 11;
        variable seed2 : positive := 97;
        variable ph_cfo : real := 0.0;
        variable symn   : natural := 0;
        variable lat_q  : integer := -1;  -- symbols until emulated strobe

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
            if lat_q > 0 then
                lat_q := lat_q - 1;
                if lat_q = 0 then
                    ss <= '1'; wait until rising_edge(clk); ss <= '0';
                    lat_q := -1;
                end if;
            end if;
            for c in 1 to 59 loop wait until rising_edge(clk); end loop;
        end procedure;

        -- one payload symbol: random-phase junk in both tones
        procedure pay(constant sig : in real) is
            variable a1, a2 : real;
        begin
            a1 := MATH_2_PI * urand; a2 := MATH_2_PI * urand;
            sym(AMP*cos(a1) + sig*grand, AMP*sin(a1) + sig*grand,
                AMP*cos(a2) + sig*grand, AMP*sin(a2) + sig*grand);
        end procedure;

        -- the 24-symbol sync word at residual f, then arm the strobe
        procedure sync_word(constant f : in real; constant sig : in real;
                            constant strobe : in boolean) is
            variable phm, aj : real;
            variable m_re, m_im, j_re, j_im : real;
        begin
            for i in 0 to 23 loop
                phm := ph_cfo + real(PHI(i)) * MATH_PI_OVER_2;
                aj  := MATH_2_PI * urand;
                m_re := AMP*cos(phm) + sig*grand;
                m_im := AMP*sin(phm) + sig*grand;
                j_re := 0.1*AMP*cos(aj) + sig*grand;
                j_im := 0.1*AMP*sin(aj) + sig*grand;
                if TONE(i) = 1 then
                    sym(m_re, m_im, j_re, j_im);
                else
                    sym(j_re, j_im, m_re, m_im);
                end if;
                ph_cfo := ph_cfo - MATH_2_PI * f / R;
            end loop;
            if strobe then
                lat_q := LAT - 1;  -- strobe LAT symbols after sync end
            end if;
        end procedure;

        procedure chk(constant cond : boolean; constant msg : string) is
        begin
            if cond then report "PASS: " & msg severity note;
            else report "FAIL: " & msg severity error; fails <= fails + 1;
            end if;
            wait for 0 ns;
        end procedure;

        type rlist is array (0 to 4) of real;
        constant CFOS : rlist := (-2000.0, -500.0, 0.0, 500.0, 2000.0);
        variable n0, errv : integer;
        variable sumer : integer;
        variable maxer : integer;
    begin
        wait until rising_edge(clk); wait until rising_edge(clk);
        rst <= '0';

        -- T1: noiseless exactness at five CFOs
        for t in 0 to 4 loop
            n0 := n_meas;
            for k in 1 to PAYSYM loop pay(0.0); end loop;
            for k in 1 to PAYSYM loop
                ph_cfo := ph_cfo + MATH_2_PI * CFOS(t) / R;
            end loop;  -- (phase bookkeeping only; payload phases random)
            sync_word(CFOS(t), 0.0, true);
            for k in 1 to LAT + 20 loop pay(0.0); end loop;
            chk(n_meas = n0 + 1,
                "T1 one measurement for CFO " & integer'image(integer(CFOS(t))));
            errv := last_f - integer(CFOS(t));
            report "T1 cfo=" & integer'image(integer(CFOS(t))) &
                   " meas=" & integer'image(last_f) severity note;
            chk(abs(errv) <= 8,
                "T1 |error| <= 8 Hz at CFO " & integer'image(integer(CFOS(t))));
        end loop;

        -- T2: sync present but NO strobe -> no measurement
        n0 := n_meas;
        for k in 1 to 60 loop pay(0.0); end loop;
        sync_word(500.0, 0.0, false);
        for k in 1 to LAT + 20 loop pay(0.0); end loop;
        chk(n_meas = n0, "T2 no strobe, no measurement");

        -- T3: noisy measurements at Eb/N0 ~ 10 dB equivalent
        -- (correlator-output SNR 10 dB: sigma per rail = AMP/sqrt(2*10))
        n0 := n_meas; sumer := 0; maxer := 0;
        for s in 1 to 12 loop
            for k in 1 to 40 loop pay(AMP/sqrt(20.0)); end loop;
            sync_word(500.0, AMP/sqrt(20.0), true);
            for k in 1 to LAT + 10 loop pay(AMP/sqrt(20.0)); end loop;
            errv := last_f - 500;
            sumer := sumer + errv;
            if abs(errv) > maxer then maxer := abs(errv); end if;
            report "T3 sync " & integer'image(s) & " meas=" &
                   integer'image(last_f) severity note;
        end loop;
        chk(n_meas = n0 + 12, "T3 twelve measurements accepted");
        chk(maxer < 350, "T3 max |error| < 350 Hz (got " &
            integer'image(maxer) & ")");
        chk(abs(sumer / 12) <= 120, "T3 mean error within +/-120 Hz (got " &
            integer'image(sumer / 12) & ")");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0'; wait;
    end process;
end architecture;
