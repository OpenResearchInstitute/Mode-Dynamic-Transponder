-------------------------------------------------------------------------------
-- tb_power_detector.vhd -- dual-oracle bit-exact bench for the ORI power_detector
-- (two-stage lowpass_ema cascade over I^2+Q^2) as used in Haifuraiya/MDT.
--
-- DUT sources (git submodules, public ORI repos, CERN-OHL-W, M. Wishek):
--   third_party/lowpass_ema/src/lowpass_ema.vhd       @ 280fe847
--   third_party/power_detector/src/power_detector.vhd @ 86bae9a0
-- Confirm these match your pinned submodule commits before trusting the vectors.
--
-- ORACLE 1 (in-hardware, vector-independent): when stage-1 is not enabled
--   (dbg_ema_1_ena='0'), the stage-1 average must HOLD -- proves data_ena gating
--   (the EMA freezes on quiet cycles, e.g. the data_ena gap in the stream).
-- ORACLE 2 (bit-exact): power_squared and dbg_ema_1 equal the golden model
--   (power_detector_model.py, proven bit-exact by dump-compare). Captured into
--   arrays and aligned by a pipeline-latency search, then asserted zero-mismatch.
--
-- Config: DATA_W=16, ALPHA_W=18, IQ_MOD, EMA_CASCADE; alpha1=4096, alpha2=64.
-- Vectors: VEC_DIR/pd_input.txt "I Q ena", VEC_DIR/pd_expected.txt "psq ema_1".
-- Uses std.env finish (not stop).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_power_detector is
    generic ( VEC_DIR : string := "" );
end entity;

architecture sim of tb_power_detector is
    constant DW : integer := 16;
    constant PW : integer := 2*DW - 1;
    constant MAXN : integer := 4000;

    signal clk  : std_logic := '0';
    signal init : std_logic := '1';
    signal ena  : std_logic := '0';
    signal di, dq : std_logic_vector(DW-1 downto 0) := (others => '0');
    signal a1, a2 : std_logic_vector(17 downto 0) := (others => '0');
    signal psq, ddsum, dema1 : std_logic_vector(PW-1 downto 0);
    signal dse2, de1 : std_logic;

    type int_arr is array (0 to MAXN-1) of integer;
    signal exp_psq, exp_e1 : int_arr := (others => 0);
    signal rtl_psq, rtl_e1 : int_arr := (others => 0);
    signal n_exp : integer := 0;    -- expected samples captured (by stim)
    signal n_rtl : integer := 0;    -- rtl samples captured (by sampler)
    signal hold_errs : integer := 0;
    signal fed_done  : boolean := false;
    signal done      : boolean := false;
begin
    clk <= not clk after 5 ns;

    dut : entity work.power_detector
        generic map (DATA_W => DW, ALPHA_W => 18, IQ_MOD => true,
                     I_USED => true, Q_USED => true, EMA_CASCADE => true)
        port map (clk => clk, init => init, alpha1 => a1, alpha2 => a2,
                  data_I => di, data_Q => dq, data_ena => ena,
                  power_squared => psq, dbg_dsum => ddsum, dbg_dsum_e2 => dse2,
                  dbg_ema_1 => dema1, dbg_ema_1_ena => de1);

    ---------------------------------------------------------------------------
    -- Stimulus: drive input[n]; record expected[n].
    ---------------------------------------------------------------------------
    stim : process
        file fi, fe : text;
        variable si, se : file_open_status;
        variable Li, Le : line;
        variable vi, vq, ve, vp, vm : integer;
        variable k : integer := 0;
    begin
        file_open(si, fi, VEC_DIR & "pd_input.txt", read_mode);
        if si /= open_ok then file_open(si, fi, "pd_input.txt", read_mode); end if;
        assert si = open_ok report "cannot open pd_input.txt" severity failure;
        file_open(se, fe, VEC_DIR & "pd_expected.txt", read_mode);
        if se /= open_ok then file_open(se, fe, "pd_expected.txt", read_mode); end if;
        assert se = open_ok report "cannot open pd_expected.txt" severity failure;
        a1 <= std_logic_vector(to_unsigned(4096, 18));
        a2 <= std_logic_vector(to_unsigned(64, 18));
        init <= '1'; ena <= '0';
        for j in 0 to 3 loop wait until rising_edge(clk); end loop;
        init <= '0';
        wait until rising_edge(clk);
        while not endfile(fi) loop
            readline(fi, Li); read(Li, vi); read(Li, vq); read(Li, ve);
            readline(fe, Le); read(Le, vp); read(Le, vm);
            di <= std_logic_vector(to_signed(vi, DW));
            dq <= std_logic_vector(to_signed(vq, DW));
            if ve = 1 then ena <= '1'; else ena <= '0'; end if;
            exp_psq(k) <= vp; exp_e1(k) <= vm; n_exp <= k + 1;
            k := k + 1;
            wait until rising_edge(clk);
        end loop;
        ena <= '0';
        for j in 0 to 8 loop wait until rising_edge(clk); end loop;
        fed_done <= true;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Sampler: record RTL outputs each cycle after init; live hold-gating check.
    ---------------------------------------------------------------------------
    sampler : process
        variable r : integer := 0;
        variable prev_e1 : integer := 0;
        variable have_prev : boolean := false;
    begin
        wait until rising_edge(clk);
        if init = '0' then
            if r < MAXN then
                rtl_psq(r) <= to_integer(signed(psq));
                rtl_e1(r)  <= to_integer(signed(dema1));
                n_rtl <= r + 1;
                r := r + 1;
            end if;
            -- ORACLE 1: stage-1 holds when not enabled
            if have_prev and de1 = '0' then
                if to_integer(signed(dema1)) /= prev_e1 then
                    hold_errs <= hold_errs + 1;
                    report "HOLD violation: ema_1 changed while ema_1_ena=0" severity error;
                end if;
            end if;
            prev_e1 := to_integer(signed(dema1));
            have_prev := true;
        end if;
        if fed_done then done <= true; wait; end if;
    end process;

    ---------------------------------------------------------------------------
    -- Final: align by latency search (0..8) and assert bit-exact at best offset.
    ---------------------------------------------------------------------------
    final : process
        variable best_off, best_bad, ncmp, bad : integer;
    begin
        wait until done;
        wait until rising_edge(clk);
        best_off := 0; best_bad := integer'high;
        for off in 0 to 8 loop
            bad := 0; ncmp := 0;
            for i in 0 to n_exp-1 loop
                if (i + off) < n_rtl then
                    ncmp := ncmp + 1;
                    if exp_psq(i) /= rtl_psq(i+off) or exp_e1(i) /= rtl_e1(i+off) then
                        bad := bad + 1;
                    end if;
                end if;
            end loop;
            if bad < best_bad then best_bad := bad; best_off := off; end if;
        end loop;
        report "=======================================================";
        report "tb_power_detector: n_exp=" & integer'image(n_exp)
             & " n_rtl=" & integer'image(n_rtl)
             & " best latency=" & integer'image(best_off)
             & " mismatches=" & integer'image(best_bad)
             & " hold_errs=" & integer'image(hold_errs);
        assert best_bad = 0 and hold_errs = 0
            report "POWER DETECTOR TB FAILED" severity failure;
        report "POWER DETECTOR TB PASSED (bit-exact power_squared + ema_1, hold gating)"
            severity note;
        report "=======================================================";
        finish;
    end process;
end architecture;
