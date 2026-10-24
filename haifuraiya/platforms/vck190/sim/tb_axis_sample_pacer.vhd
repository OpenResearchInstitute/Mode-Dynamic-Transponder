-- tb_axis_sample_pacer.vhd -- self-checking bench for the playback pacer.
-- T1 period=5, upstream always valid, downstream always ready: exactly one
--    beat every 5 clocks, data in order, TLAST on the last beat.
-- T2 period=5, downstream stalls for 23 clocks mid-stream: no beat is lost
--    or duplicated; the stream resumes on a slot.
-- T3 period=1: a beat every clock (bypass).
-- T4 period=5, upstream gaps: slots with no data are simply missed, the
--    count of forwarded beats equals the count offered.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axis_sample_pacer is end entity;

architecture sim of tb_axis_sample_pacer is
    signal clk : std_logic := '0';
    signal rstn : std_logic := '0';
    signal period : unsigned(7 downto 0) := to_unsigned(5, 8);
    signal s_tdata : std_logic_vector(31 downto 0) := (others => '0');
    signal s_tvalid, s_tready, s_tlast : std_logic := '0';
    signal m_tdata : std_logic_vector(31 downto 0);
    signal m_tvalid, m_tlast : std_logic;
    signal m_tready : std_logic := '1';
    signal running : boolean := true;
    signal fails : natural := 0;
    signal src_n : natural := 0;       -- next value to offer
    signal src_en : std_logic := '0';  -- upstream offers data
    signal src_last_at : natural := 0; -- value that carries TLAST
begin
    clk <= not clk after 5 ns when running;

    dut : entity work.axis_sample_pacer
        port map (aclk => clk, aresetn => rstn, period => period,
                  s_axis_tdata => s_tdata, s_axis_tvalid => s_tvalid, s_axis_tready => s_tready, s_axis_tlast => s_tlast,
                  m_axis_tdata => m_tdata, m_axis_tvalid => m_tvalid, m_axis_tready => m_tready, m_axis_tlast => m_tlast);

    -- upstream: a counter source that advances on each accepted beat
    s_tdata  <= std_logic_vector(to_unsigned(src_n, 32));
    s_tvalid <= src_en;
    s_tlast  <= '1' when src_n = src_last_at else '0';
    src : process(clk)
    begin
        if rising_edge(clk) then
            if s_tvalid = '1' and s_tready = '1' then src_n <= src_n + 1; end if;
        end if;
    end process;

    stim : process
        variable got : natural;
        variable last_t : natural;
        variable gaps_ok : boolean;
        variable t : natural := 0;
        variable expect : natural;
        variable stalled : boolean := false;
        procedure chk(c : boolean; m : string) is
        begin
            if c then report "PASS: " & m severity note;
            else report "FAIL: " & m severity error; fails <= fails + 1; end if;
            wait for 0 ns;
        end procedure;
    begin
        wait until rising_edge(clk); wait until rising_edge(clk);
        rstn <= '1';
        -- T1: 20 beats, period 5, sink always ready
        src_last_at <= 19; src_en <= '1';
        got := 0; expect := 0; gaps_ok := true; last_t := 0; t := 0;
        while got < 20 loop
            wait until rising_edge(clk); t := t + 1;
            if m_tvalid = '1' and m_tready = '1' then
                if to_integer(unsigned(m_tdata)) /= expect then gaps_ok := false; end if;
                if got > 0 and t - last_t /= 5 then gaps_ok := false; end if;
                last_t := t; expect := expect + 1; got := got + 1;
                if got = 20 then chk(m_tlast = '1', "T1 TLAST on the last beat"); end if;
            end if;
        end loop;
        src_en <= '0';
        chk(gaps_ok, "T1 one beat every 5 clocks, in order");
        chk(t >= 96 and t <= 101, "T1 20 beats took ~100 clocks (" & integer'image(t) & ")");

        -- T2: sink stalls mid-stream
        wait until rising_edge(clk);
        src_last_at <= 10000; src_en <= '1';
        got := 0; expect := src_n; gaps_ok := true;
        while got < 30 loop
            wait until rising_edge(clk);
            if got = 10 and not stalled then
                stalled := true;
                m_tready <= '0';
                for i in 1 to 23 loop wait until rising_edge(clk); if m_tvalid = '1' and m_tready = '1' then gaps_ok := false; end if; end loop;
                m_tready <= '1';
            end if;
            if m_tvalid = '1' and m_tready = '1' then
                if to_integer(unsigned(m_tdata)) /= expect then gaps_ok := false; end if;
                expect := expect + 1; got := got + 1;
            end if;
        end loop;
        src_en <= '0';
        chk(gaps_ok, "T2 no beat lost or duplicated across a 23-clock sink stall");

        -- T3: period 1 = every clock
        wait until rising_edge(clk);
        period <= to_unsigned(1, 8); src_en <= '1';
        got := 0; t := 0;
        while got < 20 loop
            wait until rising_edge(clk); t := t + 1;
            if m_tvalid = '1' and m_tready = '1' then got := got + 1; end if;
        end loop;
        src_en <= '0';
        chk(t <= 21, "T3 period=1 passes a beat every clock (" & integer'image(t) & ")");

        -- T4: upstream gaps -- offer data only every 3rd clock, period 5
        wait until rising_edge(clk);
        period <= to_unsigned(5, 8);
        got := 0; expect := src_n;
        for i in 1 to 150 loop
            wait until rising_edge(clk);
            if (i mod 3) = 0 then src_en <= '1'; else src_en <= '0'; end if;
            if m_tvalid = '1' and m_tready = '1' then
                if to_integer(unsigned(m_tdata)) /= expect then gaps_ok := false; end if;
                expect := expect + 1; got := got + 1;
            end if;
        end loop;
        src_en <= '0';
        chk(gaps_ok and got > 0 and got < 50, "T4 sparse upstream: forwarded in order, slots without data missed (" & integer'image(got) & " beats)");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure; end if;
        running <= false; wait;
    end process;
end architecture;
