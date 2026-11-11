------------------------------------------------------------------------------------------------------
-- tb_esi_link_hw -- the hardware wrapper with a stand-in transceiver: registers, snapshot, split clocks
------------------------------------------------------------------------------------------------------
-- What the GT does here: a 4-cycle delay line per lane in tx_clk, then one
-- register in rx_clk.  rx_clk is tx_clk's frequency with a fixed phase offset
-- (as a loopback's recovered clock is), aclk is 100 MHz -- three real domains,
-- so the synchronizers and the snapshot handshake are exercised, not bypassed.
-- GT status lines (powergood, lcpll_lock, resetdone) come up on a schedule
-- after a gt_reset pulse, as the bridge would make them -- but only if the
-- reference clock is at 156.25 MHz while the reset runs, as on the board.
-- The reference clock (gt_refclk_mon) starts at 100 MHz, the SI570's
-- power-up frequency, and is switched to 156.25 MHz at REFCLK_GOOD_AT, the
-- way Linux programs it long after the PL came up.
--
-- Checks:
--   1. with the reference at 100 MHz: no gt_reset is issued, refclk_valid
--      stays 0, REFCLK_PERIOD reads ~1024; after the switch: exactly one
--      gt_reset, refclk_valid 1, REFCLK_PERIOD ~655, REFCLK_GOOD_EVENTS 1
--   2. STATUS reaches link_ready; TX and RX clocks report alive
--   3. N_SAMPLES I/Q beats in at one per 5 aclk come out identical and in order
--   4. SNAPSHOT: SAMPLES_SENT = SAMPLES_RCVD = N_SAMPLES, error counters 0,
--      and the TX_CLK/ACLK count ratio between two snapshots is 1.5625 +/- 1 %
--   5. an AXI-Lite write with W three cycles before AW completes (bvalid) --
--      the case the older register blocks mishandled
--   6. SYNC_REQ re-synchronizes: link_ready comes back; LOOPBACK reads back
--   7. the reference drops to 100 MHz and returns: refclk_valid falls and
--      rises, one more gt_reset (REFCLK_GOOD_EVENTS 2), the link comes back
--
-- nvc:  haifuraiya/platforms/vck190/sim/esi/run_esi_link_hw_nvc.sh
-- Pass = "PASS: tb_esi_link_hw".
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_esi_link_hw is
    generic (N_SAMPLES : natural := 2000;
             REFCLK_GOOD_AT : time := 80 us);     -- when "Linux" programs the SI570
end entity tb_esi_link_hw;

architecture sim of tb_esi_link_hw is
    constant ACLK_PERIOD : time := 10 ns;                -- 100 MHz
    constant LCLK_PERIOD : time := 6.4 ns;               -- 156.25 MHz
    constant REF_WRONG   : time := 10 ns;                -- the SI570 at power-up: 100 MHz
    constant REF_RIGHT   : time := 6.4 ns;               -- after Linux programs it
    signal ref_period    : time := REF_WRONG;
    signal gt_refclk     : std_logic := '0';
    constant RX_PHASE    : time := 2.3 ns;               -- rx_clk lags tx_clk

    signal aclk, tx_clk, rx_clk : std_logic := '0';
    signal aresetn : std_logic := '0';
    signal done    : boolean := false;

    -- AXI-Stream
    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_tvalid, s_tready : std_logic := '0';
    signal m_tdata  : std_logic_vector(31 downto 0);
    signal m_tvalid : std_logic;

    -- AXI-Lite
    signal awaddr, araddr : std_logic_vector(11 downto 0) := (others => '0');
    signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
    signal arvalid, arready, rvalid, rready : std_logic := '0';
    signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal bresp, rresp : std_logic_vector(1 downto 0);

    -- GT stand-in
    signal gt_tx0, gt_tx1, gt_rx0, gt_rx1 : std_logic_vector(127 downto 0) := (others => '0');
    type dl_t is array (0 to 3) of std_logic_vector(63 downto 0);
    signal dl0, dl1 : dl_t := (others => (others => '0'));
    signal gt_powergood, gt_lcpll_lock, gt_tx_resetdone, gt_rx_resetdone, gt_link_status : std_logic := '0';
    signal ref_is_right  : boolean := false;
    signal gt_reset : std_logic;
    signal gt_loopback : std_logic_vector(2 downto 0);
    signal link_ready : std_logic;
    signal gt_reset_pulses : natural := 0;

    -- scoreboard
    signal n_out : natural := 0;
    signal n_bad : natural := 0;

    function sample_word(i : natural) return std_logic_vector is
        variable iv, qv : signed(15 downto 0);
    begin
        iv := to_signed((i * 37) mod 30000 - 15000, 16);
        qv := to_signed((i * 91) mod 28000 - 14000, 16);
        return std_logic_vector(qv) & std_logic_vector(iv);
    end function;

    constant A_ID      : std_logic_vector(11 downto 0) := x"000";
    constant A_CONTROL : std_logic_vector(11 downto 0) := x"004";
    constant A_STATUS  : std_logic_vector(11 downto 0) := x"008";
    constant A_SENT    : std_logic_vector(11 downto 0) := x"00C";
    constant A_RCVD    : std_logic_vector(11 downto 0) := x"010";
    constant A_SEQ     : std_logic_vector(11 downto 0) := x"014";
    constant A_MARKER  : std_logic_vector(11 downto 0) := x"018";
    constant A_MULTI   : std_logic_vector(11 downto 0) := x"01C";
    constant A_TXCLK   : std_logic_vector(11 downto 0) := x"020";
    constant A_RXCLK   : std_logic_vector(11 downto 0) := x"024";
    constant A_ACLK    : std_logic_vector(11 downto 0) := x"028";
    constant A_DROPS   : std_logic_vector(11 downto 0) := x"02C";
    constant A_REFPER  : std_logic_vector(11 downto 0) := x"030";
    constant A_REFGOOD : std_logic_vector(11 downto 0) := x"034";
begin
    aclk   <= not aclk   after ACLK_PERIOD / 2 when not done;
    tx_clk <= not tx_clk after LCLK_PERIOD / 2 when not done;
    -- the reference clock, at whatever frequency the "oscillator" is set to
    p_refclk : process
    begin
        while not done loop
            gt_refclk <= '1'; wait for ref_period / 2;
            gt_refclk <= '0'; wait for ref_period / 2;
        end loop;
        wait;
    end process;
    ref_is_right <= ref_period = REF_RIGHT;
    rx_clk <= transport tx_clk after RX_PHASE;

    dut : entity work.esi_link_hw
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_tdata, s_axis_tvalid => s_tvalid, s_axis_tready => s_tready,
            m_axis_tdata => m_tdata, m_axis_tvalid => m_tvalid, m_axis_tready => '1',
            s_axi_awaddr => awaddr, s_axi_awvalid => awvalid, s_axi_awready => awready,
            s_axi_wdata => wdata, s_axi_wstrb => "1111", s_axi_wvalid => wvalid, s_axi_wready => wready,
            s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
            s_axi_araddr => araddr, s_axi_arvalid => arvalid, s_axi_arready => arready,
            s_axi_rdata => rdata, s_axi_rresp => rresp, s_axi_rvalid => rvalid, s_axi_rready => rready,
            tx_clk => tx_clk, rx_clk => rx_clk,
            gt_tx_data_ch0 => gt_tx0, gt_tx_data_ch1 => gt_tx1,
            gt_rx_data_ch0 => gt_rx0, gt_rx_data_ch1 => gt_rx1,
            gt_powergood => gt_powergood, gt_lcpll_lock => gt_lcpll_lock,
            gt_tx_resetdone => gt_tx_resetdone, gt_rx_resetdone => gt_rx_resetdone,
            gt_link_status => gt_link_status, gt_refclk_mon => gt_refclk, gt_reset => gt_reset, gt_loopback => gt_loopback,
            link_ready => link_ready);

    ---------------------------------------------------------------------------
    -- the stand-in transceiver: delay in tx_clk, retime in rx_clk
    ---------------------------------------------------------------------------
    p_gt_tx : process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            dl0 <= gt_tx0(63 downto 0) & dl0(0 to 2);
            dl1 <= gt_tx1(63 downto 0) & dl1(0 to 2);
        end if;
    end process;
    p_gt_rx : process(rx_clk)
    begin
        if rising_edge(rx_clk) then
            gt_rx0 <= (127 downto 64 => '0') & dl0(3);
            gt_rx1 <= (127 downto 64 => '0') & dl1(3);
        end if;
    end process;

    -- bridge-like status schedule: powergood soon after reset; the PLL locks
    -- and the resets finish some time after each gt_reset pulse
    p_gt_status : process
    begin
        wait until aresetn = '1';
        wait for 100 ns;
        gt_powergood <= '1';
        loop
            wait until rising_edge(gt_reset) or (not ref_is_right and gt_lcpll_lock = '1');
            if gt_reset = '1' then
                gt_reset_pulses <= gt_reset_pulses + 1;
                report "GT stand-in: reset pulse " & integer'image(gt_reset_pulses + 1) & " at " & time'image(now)
                     & " with the reference " & boolean'image(ref_is_right) severity note;
                gt_lcpll_lock <= '0'; gt_tx_resetdone <= '0'; gt_rx_resetdone <= '0'; gt_link_status <= '0';
                wait until falling_edge(gt_reset);
                if ref_is_right then                 -- the PLL locks only to the right reference
                    wait for 500 ns;  gt_lcpll_lock   <= '1';
                    wait for 200 ns;  gt_tx_resetdone <= '1';
                    wait for 150 ns;  gt_rx_resetdone <= '1';
                    wait for 100 ns;  gt_link_status  <= '1';
                end if;
            else                                     -- the reference went wrong while locked: lock is lost
                gt_lcpll_lock <= '0'; gt_tx_resetdone <= '0'; gt_rx_resetdone <= '0'; gt_link_status <= '0';
            end if;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- scoreboard on the receiver side
    ---------------------------------------------------------------------------
    p_score : process(aclk)
    begin
        if rising_edge(aclk) then
            if m_tvalid = '1' then
                if m_tdata /= sample_word(n_out) then
                    n_bad <= n_bad + 1;
                    if n_bad < 5 then
                        report "MISMATCH at " & integer'image(n_out) severity warning;
                    end if;
                end if;
                n_out <= n_out + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- the test
    ---------------------------------------------------------------------------
    p_main : process
        variable rd, rd2 : std_logic_vector(31 downto 0);
        variable sent, rcvd, e1, e2, e3, tx1, tx2, ac1, ac2 : unsigned(31 downto 0);
        variable ratio   : real;
        variable fails   : natural := 0;
        variable t0      : time;

        procedure axi_write(addr : std_logic_vector(11 downto 0); data : std_logic_vector(31 downto 0);
                            w_first_cycles : natural := 0) is
        begin
            -- optionally put W on the bus some cycles before AW (split-phase master)
            wait until rising_edge(aclk);
            wdata <= data; wvalid <= '1';
            for i in 1 to w_first_cycles loop
                wait until rising_edge(aclk);
                if wvalid = '1' and wready = '1' then wvalid <= '0'; end if;   -- W may complete before AW is even offered
            end loop;
            awaddr <= addr; awvalid <= '1';
            -- wait for both handshakes, in any order
            t0 := now;
            loop
                wait until rising_edge(aclk);
                if awvalid = '1' and awready = '1' then awvalid <= '0'; end if;
                if wvalid = '1' and wready = '1' then wvalid <= '0'; end if;
                exit when (awvalid = '0' or awready = '1') and (wvalid = '0' or wready = '1');
                if now - t0 > 1 us then
                    report "AXI write to " & to_hstring(addr) & ": address/data handshake stuck" severity error;
                    fails := fails + 1; exit;
                end if;
            end loop;
            awvalid <= '0'; wvalid <= '0';
            bready <= '1';
            t0 := now;
            loop
                wait until rising_edge(aclk);
                exit when bvalid = '1';
                if now - t0 > 1 us then
                    report "AXI write to " & to_hstring(addr) & ": no bvalid within 1 us" severity error;
                    fails := fails + 1; exit;
                end if;
            end loop;
            bready <= '0';
        end procedure;

        procedure axi_read(addr : std_logic_vector(11 downto 0); data : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(aclk);
            araddr <= addr; arvalid <= '1';
            loop wait until rising_edge(aclk); exit when arready = '1'; end loop;
            arvalid <= '0'; rready <= '1';
            loop wait until rising_edge(aclk); exit when rvalid = '1'; end loop;
            data := rdata;
            rready <= '0';
        end procedure;

        procedure snapshot(sent, rcvd, e1, e2, e3, txc, acl : out unsigned(31 downto 0)) is
            variable r, v : std_logic_vector(31 downto 0);
        begin
            v := (others => '0'); v(7) := '1'; v(6 downto 4) := gt_loopback;   -- SNAPSHOT, keep the loopback mode
            axi_write(A_CONTROL, v);
            loop
                axi_read(A_STATUS, r);
                exit when r(8) = '0';
            end loop;
            axi_read(A_SENT, r);   sent := unsigned(r);
            axi_read(A_RCVD, r);   rcvd := unsigned(r);
            axi_read(A_SEQ, r);    e1 := unsigned(r);
            axi_read(A_MARKER, r); e2 := unsigned(r);
            axi_read(A_MULTI, r);  e3 := unsigned(r);
            axi_read(A_TXCLK, r);  txc := unsigned(r);
            axi_read(A_ACLK, r);   acl := unsigned(r);
        end procedure;

        procedure wait_link_ready(tmo : time; what : string) is
        begin
            t0 := now;
            loop
                axi_read(A_STATUS, rd);
                exit when rd(7) = '1';
                if now - t0 > tmo then
                    report what & ": link_ready not seen within " & time'image(tmo) & "  STATUS=" & to_hstring(rd) severity error;
                    fails := fails + 1; exit;
                end if;
            end loop;
        end procedure;
    begin
        aresetn <= '0';
        wait for 200 ns;
        wait until rising_edge(aclk);
        aresetn <= '1';

        -- ID
        axi_read(A_ID, rd);
        if rd /= x"45534931" then report "ID read " & to_hstring(rd) severity error; fails := fails + 1; end if;

        -- 1a. the reference is wrong (100 MHz): no reset, not valid, period ~1024
        if now < REFCLK_GOOD_AT - 1 us then wait for (REFCLK_GOOD_AT - 1 us) - now; end if;   -- 'wait until now' never wakes
        axi_read(A_STATUS, rd);
        axi_read(A_REFPER, rd2);
        report "with the reference at 100 MHz: STATUS " & to_hstring(rd) & "  REFCLK_PERIOD " & integer'image(to_integer(unsigned(rd2)))
             & "  gt_reset pulses " & integer'image(gt_reset_pulses) severity note;
        if gt_reset_pulses /= 0 or rd(11) = '1' then
            report "a transceiver reset was issued, or refclk_valid set, with the reference at 100 MHz" severity error;
            fails := fails + 1;
        end if;
        if to_integer(unsigned(rd2)) < 1000 or to_integer(unsigned(rd2)) > 1048 then
            report "REFCLK_PERIOD at 100 MHz should read ~1024" severity error; fails := fails + 1;
        end if;

        -- 1b. "Linux programs the SI570": the reference becomes right
        if now < REFCLK_GOOD_AT then wait for REFCLK_GOOD_AT - now; end if;
        ref_period <= REF_RIGHT;
        report "reference clock switched to 156.25 MHz at " & time'image(now) severity note;
        wait for 80 us;                                  -- 8 good windows of 6.55 us, plus margin
        axi_read(A_STATUS, rd);
        axi_read(A_REFPER, rd2);
        report "after the switch: STATUS " & to_hstring(rd) & "  REFCLK_PERIOD " & integer'image(to_integer(unsigned(rd2)))
             & "  gt_reset pulses " & integer'image(gt_reset_pulses) severity note;
        if gt_reset_pulses /= 1 or rd(11) = '0' then
            report "expected exactly one automatic gt_reset and refclk_valid after the switch" severity error;
            fails := fails + 1;
        end if;
        if to_integer(unsigned(rd2)) < 638 or to_integer(unsigned(rd2)) > 672 then
            report "REFCLK_PERIOD at 156.25 MHz should read ~655" severity error; fails := fails + 1;
        end if;
        axi_read(A_REFGOOD, rd2);
        if to_integer(unsigned(rd2)) /= 1 then
            report "REFCLK_GOOD_EVENTS should be 1, read " & integer'image(to_integer(unsigned(rd2))) severity error; fails := fails + 1;
        end if;

        -- 2. link comes up; clocks alive
        wait_link_ready(20 us, "bring-up");
        axi_read(A_STATUS, rd);
        report "STATUS after bring-up = " & to_hstring(rd) & "  (link_ready after " & time'image(now) & ")" severity note;
        if rd(9) = '0' or rd(10) = '0' then
            report "clock-alive bits not set: " & to_hstring(rd) severity error; fails := fails + 1;
        end if;
        if rd(5) = '0' or rd(6) = '0' then
            report "xcvr_ready/lanes_ready not set: " & to_hstring(rd) severity error; fails := fails + 1;
        end if;

        -- 4a. first snapshot (nothing sent yet; take the clock counters)
        snapshot(sent, rcvd, e1, e2, e3, tx1, ac1);

        -- 3. samples, one per 5 aclk, as the pacer would
        for i in 0 to N_SAMPLES - 1 loop
            wait until rising_edge(aclk);
            s_tdata <= sample_word(i); s_tvalid <= '1';
            loop wait until rising_edge(aclk); exit when s_tready = '1'; end loop;
            s_tvalid <= '0';
            wait until rising_edge(aclk); wait until rising_edge(aclk); wait until rising_edge(aclk);
        end loop;
        wait for 2 us;
        if n_out /= N_SAMPLES or n_bad /= 0 then
            report "stream: out " & integer'image(n_out) & " of " & integer'image(N_SAMPLES) & ", mismatched " & integer'image(n_bad) severity error;
            fails := fails + 1;
        end if;

        -- 4b. second snapshot: counters and the clock ratio
        snapshot(sent, rcvd, e1, e2, e3, tx2, ac2);
        report "snapshot: sent " & integer'image(to_integer(sent)) & "  rcvd " & integer'image(to_integer(rcvd))
             & "  seq " & integer'image(to_integer(e1)) & "  marker " & integer'image(to_integer(e2))
             & "  multi " & integer'image(to_integer(e3)) severity note;
        if to_integer(sent) /= N_SAMPLES or to_integer(rcvd) /= N_SAMPLES or e1 /= 0 or e2 /= 0 or e3 /= 0 then
            report "snapshot counters wrong" severity error; fails := fails + 1;
        end if;
        ratio := real(to_integer(tx2 - tx1)) / real(to_integer(ac2 - ac1));
        report "tx_clk / aclk ratio over " & integer'image(to_integer(ac2 - ac1)) & " aclk = " & real'image(ratio) severity note;
        if ratio < 1.5469 or ratio > 1.5781 then
            report "clock ratio off (expect 1.5625 +/- 1 %)" severity error; fails := fails + 1;
        end if;

        -- 5. split-phase write: W three cycles before AW, must still complete
        axi_write(A_CONTROL, x"00000020", 3);          -- loopback 010, nothing else
        axi_read(A_CONTROL, rd);
        if rd(6 downto 4) /= "010" then report "CONTROL readback after split write: " & to_hstring(rd) severity error; fails := fails + 1; end if;

        -- 6. loopback write/readback, then SYNC_REQ and the link returns
        axi_write(A_CONTROL, x"00000010");             -- loopback 001
        axi_read(A_CONTROL, rd);
        if rd(6 downto 4) /= "001" or gt_loopback /= "001" then report "LOOPBACK readback: " & to_hstring(rd) severity error; fails := fails + 1; end if;
        axi_write(A_CONTROL, x"00000022");             -- loopback 010 + SYNC_REQ
        wait for 1 us;
        wait_link_ready(20 us, "after SYNC_REQ");
        axi_read(A_DROPS, rd);
        report "LINK_DROPS after re-sync = " & integer'image(to_integer(unsigned(rd))) severity note;

        -- 7. the reference goes wrong and comes back: valid falls, then one more reset
        ref_period <= REF_WRONG;
        report "reference clock dropped to 100 MHz at " & time'image(now) severity note;
        wait for 40 us;
        axi_read(A_STATUS, rd);
        if rd(11) = '1' or rd(7) = '1' then
            report "refclk_valid/link_ready still set 40 us after the reference went wrong: " & to_hstring(rd) severity error;
            fails := fails + 1;
        end if;
        ref_period <= REF_RIGHT;
        report "reference clock back to 156.25 MHz at " & time'image(now) severity note;
        wait for 80 us;
        wait_link_ready(20 us, "after the reference returned");
        axi_read(A_REFGOOD, rd2);
        axi_read(A_DROPS, rd);
        report "after the reference returned: REFCLK_GOOD_EVENTS " & integer'image(to_integer(unsigned(rd2)))
             & "  gt_reset pulses " & integer'image(gt_reset_pulses) & "  LINK_DROPS " & integer'image(to_integer(unsigned(rd))) severity note;
        if to_integer(unsigned(rd2)) /= 2 or gt_reset_pulses /= 2 then
            report "expected a second automatic reset and REFCLK_GOOD_EVENTS = 2" severity error; fails := fails + 1;
        end if;

        if fails = 0 then
            report "PASS: tb_esi_link_hw" severity note;
        else
            report "FAIL: tb_esi_link_hw (" & integer'image(fails) & " checks)" severity error;
        end if;
        done <= true;
        wait;
    end process;
end architecture sim;
