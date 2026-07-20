-- tb_sym_lock_detector.vhd -- self-checking bench, normalized-ratio contract
-- T1 noise (uncorrelated E/L, ratio ~90%) never locks
-- T2 clean (ratio ~2%) locks when window fills; ratio_pct readback sane
-- T3 hysteresis: ratio ~33% (between 25 and 50) stays locked
-- T4 ratio ~70% unlocks
-- T5 window reconfig flushes; relocks after refill
-- T6 config sweep: three percent settings x lock/never/unlock
-- T7 AMPLITUDE INVARIANCE: same ratio at 16x amplitude -> identical verdicts
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sym_lock_detector is end entity;

architecture sim of tb_sym_lock_detector is
    constant CLK_P : time := 10 ns;
    signal clk   : std_logic := '0';
    signal init  : std_logic := '1';
    signal ev    : std_logic := '0';
    signal ee    : unsigned(15 downto 0) := (others => '0');
    signal el    : unsigned(15 downto 0) := (others => '0');
    signal pl    : unsigned(7 downto 0) := to_unsigned(25, 8);
    signal pu    : unsigned(7 downto 0) := to_unsigned(50, 8);
    signal wl2   : unsigned(3 downto 0) := to_unsigned(6, 4);
    signal lck   : std_logic;
    signal pct   : unsigned(7 downto 0);
    signal wfull : std_logic;
    signal fails : natural := 0;
    signal running : std_logic := '1';
begin
    clkgen : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_P/2;
            clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    dut : entity work.sym_lock_detector
        port map (clk => clk, init => init, e_valid => ev,
                  e_early => ee, e_late => el,
                  pct_lock => pl, pct_unlock => pu, window_log2 => wl2,
                  locked => lck, ratio_pct => pct, window_full => wfull);

    stim : process
        procedure sym(constant early_v, late_v : natural) is
        begin
            ee <= to_unsigned(early_v, 16);
            el <= to_unsigned(late_v, 16);
            ev <= '1'; wait until rising_edge(clk);
            ev <= '0';
            for i in 1 to 12 loop wait until rising_edge(clk); end loop; -- room for divider
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
        init <= '0'; wait until rising_edge(clk);

        -- T1: uncorrelated E/L, ratio ~90%
        for i in 1 to 200 loop
            if (i mod 2) = 0 then sym(2000, 100); else sym(100, 2000); end if;
        end loop;
        chk(lck = '0', "T1 noise never locks");
        chk(wfull = '1' and pct > pu, "T1 ratio_pct above unlock (" &
            integer'image(to_integer(pct)) & "%)");

        -- T2: clean timing, ratio ~2.4% (E=1000, L=1050)
        for i in 1 to 200 loop sym(1000, 1050); end loop;
        chk(lck = '1', "T2 locks on clean ratio");
        chk(pct < pl, "T2 ratio_pct below lock (" &
            integer'image(to_integer(pct)) & "%)");

        -- T3: hysteresis band ~33% (E=1000, L=2000)
        for i in 1 to 200 loop sym(1000, 2000); end loop;
        chk(lck = '1', "T3 stays locked in hysteresis band (" &
            integer'image(to_integer(pct)) & "%)");

        -- T4: ~70% (E=500, L=2800) -> unlock
        for i in 1 to 200 loop sym(500, 2800); end loop;
        chk(lck = '0', "T4 unlocks above UNLOCK (" &
            integer'image(to_integer(pct)) & "%)");

        -- T5: relock, then window change flushes
        for i in 1 to 200 loop sym(1000, 1020); end loop;
        chk(lck = '1', "T5 relocks clean");
        wl2 <= to_unsigned(4, 4);
        wait until rising_edge(clk); wait until rising_edge(clk);
        chk(lck = '0', "T5 window change flushes");
        for i in 1 to 40 loop sym(1000, 1020); end loop;
        chk(lck = '1', "T5 relocks after refill (window 16)");

        -- T6: config sweep
        for cfg in 0 to 2 loop
            case cfg is
                when 0 => pl <= to_unsigned(15,8); pu <= to_unsigned(30,8);
                          wl2 <= to_unsigned(4,4);
                when 1 => pl <= to_unsigned(25,8); pu <= to_unsigned(50,8);
                          wl2 <= to_unsigned(6,4);
                when others => pl <= to_unsigned(40,8); pu <= to_unsigned(80,8);
                          wl2 <= to_unsigned(8,4);
            end case;
            init <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
            init <= '0'; wait until rising_edge(clk);
            for i in 1 to 600 loop
                if (i mod 2)=0 then sym(3000,100); else sym(100,3000); end if;
            end loop;
            chk(lck = '0', "T6 cfg" & integer'image(cfg) & " noise never locks");
            for i in 1 to 600 loop sym(2000, 2050); end loop;
            chk(lck = '1', "T6 cfg" & integer'image(cfg) & " clean locks");
            for i in 1 to 600 loop sym(200, 3000); end loop;
            chk(lck = '0', "T6 cfg" & integer'image(cfg) & " gross unlocks");
        end loop;

        -- T7: amplitude invariance -- restore defaults, lock at small
        -- amplitude, jump 16x with the SAME ratio: verdict must not move
        pl <= to_unsigned(25,8); pu <= to_unsigned(50,8); wl2 <= to_unsigned(6,4);
        init <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
        init <= '0'; wait until rising_edge(clk);
        for i in 1 to 200 loop sym(500, 520); end loop;
        chk(lck = '1', "T7 locks at low amplitude");
        for i in 1 to 200 loop sym(8000, 8320); end loop;   -- 16x, same 4% ratio
        chk(lck = '1', "T7 HOLDS at 16x amplitude, same ratio (" &
            integer'image(to_integer(pct)) & "%)");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0';
        wait;
    end process;
end architecture;
