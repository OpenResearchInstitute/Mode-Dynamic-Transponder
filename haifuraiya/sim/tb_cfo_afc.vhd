-- tb_cfo_afc.vhd -- self-checking unit bench for the AFC estimator
-- Drives synthetic per-symbol y's in the DEMOD DOMAIN: for antenna-frame
-- residual +f, the dominant correlation rotates at MINUS f (conjugated
-- domain). Closed loop simulated: y rotation rate = -(offset - est).
-- T1  +5 kHz offset: state walks SEARCH->CORRECTING->HELD; est -> +5000+/-60
-- T2  anti-wedge: offset steps to -3 kHz mid-run; relock; est -> -3000+/-60
-- T3  dead air (y=0): quality collapses -> LOST -> SEARCH; est RETAINED
-- T4  signal returns at +2 kHz: reacquire; est -> +2000+/-60  (the wedge
--     scenario that requires a C++ restart -- must self-heal here)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_cfo_afc is end entity;

architecture sim of tb_cfo_afc is
    constant CLK_P : time := 10 ns;
    constant R     : real := 54200.0;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal yv  : std_logic := '0';
    signal y1r, y1i, y2r, y2i : signed(23 downto 0) := (others => '0');
    signal a_trk : unsigned(7 downto 0) := to_unsigned(10, 8);
    signal a_acq : unsigned(7 downto 0) := to_unsigned(6, 8);
    signal est : signed(15 downto 0);
    signal st  : unsigned(2 downto 0);
    signal q   : unsigned(15 downto 0);
    signal lck : std_logic;
    signal running : std_logic := '1';
    signal fails : natural := 0;
begin
    clkgen : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_P/2; clk <= '1'; wait for CLK_P/2;
        end loop; wait;
    end process;

    dut : entity work.cfo_afc
        port map (clk => clk, rst => rst, y_valid => yv,
                  y1_re => y1r, y1_im => y1i, y2_re => y2r, y2_im => y2i,
                  alpha_trk => a_trk, alpha_acq => a_acq,
                  est_hz => est, state_o => st, quality => q, cfo_locked => lck);

    stim : process
        variable ph : real := 0.0;
        variable offset : real;
        variable resid : real;
        variable symn : natural := 0;
        procedure sym(constant amp : in real) is
            variable a1, a2 : real;
        begin
            -- HONEST TONE MODEL (2026-07-21 lesson): dominance alternates
            -- in the preamble's 1100 cadence -- two symbols tone 1, two
            -- symbols tone 2 -- while BOTH correlations rotate at the
            -- residual rate. The first bench kept y1 dominant always and
            -- missed the cross-tone prev bug the system bench caught.
            if (symn / 2) mod 2 = 0 then a1 := amp;      a2 := 0.3*amp;
            else                         a1 := 0.3*amp;  a2 := amp;
            end if;
            symn := symn + 1;
            y1r <= to_signed(integer(round(a1*cos(ph))), 24);
            y1i <= to_signed(integer(round(a1*sin(ph))), 24);
            y2r <= to_signed(integer(round(a2*cos(ph))), 24);
            y2i <= to_signed(integer(round(a2*sin(ph))), 24);
            yv <= '1'; wait until rising_edge(clk); yv <= '0';
            for c in 1 to 59 loop wait until rising_edge(clk); end loop;
            -- demod domain: rotation = MINUS the antenna residual
            resid := offset - real(to_integer(est));
            ph := ph - 2.0*MATH_PI*resid/R;
        end procedure;
        procedure chk(constant cond : boolean; constant msg : string) is
        begin
            if cond then report "PASS: " & msg severity note;
            else report "FAIL: " & msg severity error; fails <= fails + 1;
            end if;
            wait for 0 ns;
        end procedure;
    begin
        wait until rising_edge(clk); wait until rising_edge(clk);
        rst <= '0';

        -- T1: +5 kHz
        offset := 5000.0;
        for k in 1 to 900 loop sym(300000.0); end loop;
        report "T1 est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(st = 3, "T1 state HELD after acquisition");
        chk(abs(to_integer(est) - 5000) < 60, "T1 est converged to +5000");

        -- T2: anti-wedge step to -3 kHz
        offset := -3000.0;
        for k in 1 to 1200 loop sym(300000.0); end loop;
        report "T2 est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(st = 3, "T2 re-HELD after mid-run offset step");
        chk(abs(to_integer(est) + 3000) < 60, "T2 est converged to -3000");

        -- T3: dead air
        for k in 1 to 200 loop sym(0.0); end loop;
        report "T3 est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(st = 1 or st = 4, "T3 dead air -> LOST/SEARCH");
        chk(abs(to_integer(est) + 3000) < 80, "T3 estimate retained (warm)");

        -- T4: the wedge scenario -- signal returns at a NEW offset
        offset := 2000.0;
        for k in 1 to 1200 loop sym(300000.0); end loop;
        report "T4 est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(st = 3, "T4 reacquired without restart (anti-wedge)");
        chk(abs(to_integer(est) - 2000) < 60, "T4 est converged to +2000");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0'; wait;
    end process;
end architecture;
