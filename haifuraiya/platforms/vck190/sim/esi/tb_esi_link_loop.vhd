------------------------------------------------------------------------------------------------------
-- tb_esi_link_loop -- link-level bench: known samples in, same samples out, in order
------------------------------------------------------------------------------------------------------
-- Drives esi_link_loop (IDEAL_LINK) with N_SAMPLES I/Q beats at one per
-- SMP_PERIOD clocks of a 100 MHz clock (20 MSps for SMP_PERIOD = 5, as the
-- pacer does), with a 156.25 MHz link clock, and checks that every beat comes
-- out the far side unchanged and in order.  Pass criteria, all measured:
--   - link_ready within 20 us of reset release
--   - N_SAMPLES beats received, each equal to the one sent
--   - seq_errors = marker_errors = multi_errors = 0
--   - a second instance fed through a faulty "transceiver" (lane-1 SEQ bit
--     stuck after link-up) counts exactly 2*N_SAMPLES/NB_LANES seq_errors:
--     the error counters are proven able to fail, not just quiet
-- Runs in nvc (with sim/esi/rx_xpm_async_fifo_sim.vhd) and in xsim (with the
-- real Teledyne XPM wrapper).  See run_esi_link_nvc.sh.
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;

entity tb_esi_link_loop is
    generic (
        N_SAMPLES  : natural := 3000;
        SMP_PERIOD : natural := 5;
        NB_LANES   : natural := 8
    );
end entity tb_esi_link_loop;

architecture sim of tb_esi_link_loop is
    constant ACLK_PERIOD : time := 10 ns;      -- 100 MHz
    constant LCLK_PERIOD : time := 6.4 ns;     -- 156.25 MHz

    signal aclk, link_clk : std_logic := '0';
    signal aresetn, link_rstn : std_logic := '0';

    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal m_tdata  : std_logic_vector(31 downto 0);
    signal m_tvalid : std_logic;

    signal link_ready : std_logic;
    signal seq_errors, marker_errors, multi_errors, samples_sent, samples_rcvd : unsigned(31 downto 0);

    signal n_sent, n_rcvd, n_bad : natural := 0;
    signal done : boolean := false;

    -- second instance, hardware-mode ports, with the bench playing a faulty
    -- transceiver: once the link is up, bit 48 of every lane-1 word is stuck
    -- inverted (frame 3 bit 0 = SEQ bit 0 in the esi_loop_pkg layout).  Every
    -- sample that rides lane 1 (one in NB_LANES) arrives with SEQ off by one,
    -- which the reassembler must count: 2 errors per hit (the hit, and the
    -- next sample measured against the wrong expectation).  Proves the
    -- counters can fail; a lane swap would NOT be caught at this sample rate
    -- (one sample per ~8 link words, so swapping lanes never reorders them).
    signal x_tx   : slv_ser_width_array_n(NB_LANES-1 downto 0);
    signal x_rx   : slv_deser_width_array_n(NB_LANES-1 downto 0);
    signal sw_tready, sw_tvalid, sw_ready : std_logic;
    signal sw_tdata : std_logic_vector(31 downto 0);
    signal sw_seq_errors, sw_marker_errors, sw_multi_errors, sw_rcvd : unsigned(31 downto 0);
    signal sw_n_rcvd : natural := 0;

    function sample_of(n : natural) return std_logic_vector is
        variable i_v, q_v : signed(15 downto 0);
    begin
        i_v := to_signed((n * 7919) mod 65536 - 32768, 16);     -- spread over the full 16-bit range
        q_v := to_signed((n * 104729 + 12345) mod 65536 - 32768, 16);
        return std_logic_vector(q_v) & std_logic_vector(i_v);
    end function;
begin
    aclk     <= not aclk     after ACLK_PERIOD / 2 when not done;
    link_clk <= not link_clk after LCLK_PERIOD / 2 when not done;

    dut : entity work.esi_link_loop
        generic map (NB_LANES => NB_LANES, IDEAL_LINK => true)
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_tdata, s_axis_tvalid => s_tvalid, s_axis_tready => s_tready,
            m_axis_tdata => m_tdata, m_axis_tvalid => m_tvalid, m_axis_tready => '1',
            tx_clk => link_clk, tx_rstn => link_rstn, rx_clk => link_clk, rx_rstn => link_rstn,
            link_ready => link_ready,
            seq_errors => seq_errors, marker_errors => marker_errors, multi_errors => multi_errors,
            samples_sent => samples_sent, samples_rcvd => samples_rcvd);

    dut_faulty : entity work.esi_link_loop
        generic map (NB_LANES => NB_LANES, IDEAL_LINK => false)
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_tdata, s_axis_tvalid => s_tvalid, s_axis_tready => sw_tready,
            m_axis_tdata => sw_tdata, m_axis_tvalid => sw_tvalid, m_axis_tready => '1',
            tx_clk => link_clk, tx_rstn => link_rstn, rx_clk => link_clk, rx_rstn => link_rstn, xcvr_ready => '1',
            xcvr_tx_data => x_tx, xcvr_rx_data => x_rx,
            link_ready => sw_ready,
            seq_errors => sw_seq_errors, marker_errors => sw_marker_errors, multi_errors => sw_multi_errors,
            samples_sent => open, samples_rcvd => sw_rcvd);
    g_xlink : for l in 0 to NB_LANES-1 generate
        g_bad : if l = 1 generate
            x_rx(1) <= x_tx(1) xor (x"0001000000000000" and (63 downto 0 => sw_ready));
        end generate;
        g_ok : if l /= 1 generate x_rx(l) <= x_tx(l); end generate;
    end generate;
    p_sw_count : process(aclk)
    begin
        if rising_edge(aclk) then
            if sw_tvalid = '1' then sw_n_rcvd <= sw_n_rcvd + 1; end if;
        end if;
    end process;

    -- stimulus: wait for the link, then one sample every SMP_PERIOD clocks,
    -- holding tvalid until tready (AXI-Stream rules; the pacer does the same)
    p_stim : process
        variable t0 : time;
    begin
        aresetn <= '0'; link_rstn <= '0';
        wait for 200 ns;
        link_rstn <= '1';
        wait for 50 ns;
        aresetn <= '1';
        t0 := now;
        wait until link_ready = '1' for 20 us;
        assert link_ready = '1' report "FAIL: link never became ready" severity failure;
        report "link_ready after " & time'image(now - t0) & " (from reset release)";
        wait for 1 us;
        for n in 0 to N_SAMPLES-1 loop
            wait until rising_edge(aclk);
            s_tdata  <= sample_of(n);
            s_tvalid <= '1';
            loop
                wait until rising_edge(aclk);
                exit when s_tready = '1';
            end loop;
            s_tvalid <= '0';
            n_sent <= n + 1;
            for k in 1 to SMP_PERIOD - 2 loop
                wait until rising_edge(aclk);
            end loop;
        end loop;
        wait for 20 us;                     -- drain
        report "sent " & integer'image(n_sent) & "  received " & integer'image(n_rcvd) &
               "  mismatched " & integer'image(n_bad) &
               "  seq_err " & integer'image(to_integer(seq_errors)) &
               "  marker_err " & integer'image(to_integer(marker_errors)) &
               "  multi_err " & integer'image(to_integer(multi_errors)) &
               "  (dut counters sent " & integer'image(to_integer(samples_sent)) &
               " rcvd " & integer'image(to_integer(samples_rcvd)) & ")";
        report "faulty-lane instance: received " & integer'image(sw_n_rcvd) &
               "  seq_err " & integer'image(to_integer(sw_seq_errors)) &
               "  marker_err " & integer'image(to_integer(sw_marker_errors)) &
               "  multi_err " & integer'image(to_integer(sw_multi_errors)) &
               "  (expect seq_err = " & integer'image(2 * (N_SAMPLES / NB_LANES)) & ": lane-1 SEQ bit 0 stuck by the bench)";
        if n_rcvd = N_SAMPLES and n_bad = 0 and seq_errors = 0 and marker_errors = 0 and multi_errors = 0
           and sw_n_rcvd = N_SAMPLES and sw_seq_errors = 2 * (N_SAMPLES / NB_LANES)
           and sw_marker_errors = 0 and sw_multi_errors = 0 then
            report "PASS: tb_esi_link_loop" severity note;
        else
            report "FAIL: tb_esi_link_loop" severity error;
        end if;
        done <= true;
        wait;
    end process;

    -- checker: every received beat must be sample_of(index)
    p_check : process(aclk)
    begin
        if rising_edge(aclk) then
            if m_tvalid = '1' then
                if m_tdata /= sample_of(n_rcvd) then
                    n_bad <= n_bad + 1;
                    if n_bad < 5 then
                        report "mismatch at " & integer'image(n_rcvd) severity warning;
                    end if;
                end if;
                n_rcvd <= n_rcvd + 1;
            end if;
        end if;
    end process;
end architecture sim;
