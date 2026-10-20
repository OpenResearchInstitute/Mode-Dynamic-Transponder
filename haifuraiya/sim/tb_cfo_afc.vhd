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
    signal pset   : signed(15 downto 0) := (others => '0');  -- preamble preset
    signal pset_v : std_logic := '0';
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
                  pre_set => pset, pre_set_v => pset_v,
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

        -- ===== CLOSED-LOOP ACQUISITION HANDOFF (the real system behavior) ===
        -- These tests model what actually happens in the system: the preamble
        -- measurement is a RESIDUAL (offset - est, post-rotator), fed as
        -- pre_set; est must ACCUMULATE it and the decision-directed loop must
        -- be held off while the preamble is present (in_acq), then take over.
        -- The isolated inject tests (old T5-T7) could not show the race that
        -- broke in-system; these do.

        -- T5: COLD ACQUISITION OWNED BY THE PREAMBLE.  Reset, then even while
        -- the decision-directed loop WOULD run, periodic preamble measurements
        -- (residual = offset - est) must drive est to the true offset and hold
        -- it.  The self-correcting accumulate lands est on truth regardless of
        -- where the loop crawled first.
        rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
        rst <= '0';
        offset := 500.0;
        -- let the loop run cold a little first (it will crawl -- that's the
        -- race), THEN the first preamble measurement must snap est to 500
        for k in 1 to 120 loop sym(300000.0); end loop;
        report "T5 pre-preamble est=" & integer'image(to_integer(est)) severity note;
        -- first preamble measurement: residual = offset - est
        pset <= to_signed(500 - to_integer(est), 16);
        pset_v <= '1'; wait until rising_edge(clk); pset_v <= '0';
        for k in 1 to 8 loop sym(300000.0); end loop;
        report "T5 after 1st preamble est=" & integer'image(to_integer(est)) severity note;
        chk(abs(to_integer(est) - 500) < 20,
            "T5 one preamble measurement snaps est to +500 (self-correcting)");
        -- keep measuring across the preamble (every ~256 sym), est holds ~500
        for w in 1 to 6 loop
            for k in 1 to 256 loop sym(300000.0); end loop;
            pset <= to_signed(500 - to_integer(est), 16);
            pset_v <= '1'; wait until rising_edge(clk); pset_v <= '0';
        end loop;
        for k in 1 to 8 loop sym(300000.0); end loop;
        report "T5 end-of-preamble est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(abs(to_integer(est) - 500) < 20, "T5 est held at +500 through preamble");
        chk(st = 3, "T5 HELD by end of preamble");

        -- T6: HANDOFF TO TRACKING.  Stop the preamble measurements (payload
        -- begins).  After G_PRE_TAIL symbols in_acq drops and the slow loop
        -- owns the word; est must STAY ~500 (no drift away on handoff).
        for k in 1 to 500 loop sym(300000.0); end loop;
        report "T6 post-handoff est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(abs(to_integer(est) - 500) < 40, "T6 est stable after handoff to tracking");

        -- T7: TRACKING WORKS after handoff -- a real carrier step (no presets)
        -- is followed by the slow loop (proves the loop is live, not frozen).
        offset := 800.0;
        for k in 1 to 6000 loop sym(300000.0); end loop;
        report "T7 est=" & integer'image(to_integer(est)) &
               " state=" & integer'image(to_integer(st)) severity note;
        chk(abs(to_integer(est) - 800) < 80, "T7 slow loop tracked a +300 Hz step after handoff");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0'; wait;
    end process;
end architecture;
