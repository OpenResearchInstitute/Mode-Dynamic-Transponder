-------------------------------------------------------------------------------
-- tb_channel_normalizer_mux.vhd
--
-- The block under test is one line of arithmetic:
--
--     gain = GAIN_TARGET / sqrt( max(power, SQUELCH_THR) )
--     out  = saturate( round( in * gain ) )
--
-- so the bench is short. It needs no golden vectors and no python: the analytic
-- oracle is real-arithmetic, computed here, against the RTL's fixed-point.
--
-- ORACLES
--   A1  latency is exactly 5 clocks, and out_valid / out_chan / out_last travel
--       WITH the data. Feeding a downstream block the raw upstream valid gives a
--       uniform one-sample delay that still decodes and still locks -- it fails
--       silently, so it is checked both ways.
--   A2  BYPASS: gain_mode='0', gain_manual=0x0400 -> the output is bit-for-bit
--       identical to the input. This is the reset default. A receiver that has
--       never been configured behaves exactly as before this block existed.
--   A3  SATURATION clamps to +/- full scale and raises gain_sat. It never wraps.
--       (A wrapping requantizer flips the sign of strong symbols; that is what
--       produced negative sync correlation peaks in the demod.)
--   A4  THE GAIN LAW. Over a 60 dB sweep of channel power, gain_current must
--       match GAIN_TARGET/sqrt(power) to better than GAIN_TOL_DB.
--   A5  THE POINT OF THE BLOCK. Feed a constant-envelope signal at many
--       different amplitudes, each with its own honest power. Every one must
--       come out at GAIN_TARGET. That is what "all channels have the same
--       power" means, and it is the only thing the demod cares about.
--   A6  SQUELCH FLOOR. Below SQUELCH_THR the gain STOPS GROWING. A dead channel
--       carrying only receiver noise is not amplified to full scale.
--   A7  ZERO-POWER GUARD. power=0 and squelch_thr=0 must not produce X, must not
--       divide by zero, must not wrap.
--   A8  NO STATE. The block is a pure function of (in_i, in_q, power). Present
--       the same beat twice, far apart in time, with unrelated traffic between:
--       the output must be identical. If this fails, someone added state.
--
-- Uses std.env finish (not stop).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_channel_normalizer_mux is
    generic (
        GAIN_TOL_DB : real := 0.05;   -- gain-law tolerance; RTL measures 0.017
        LEVEL_TOL_DB: real := 0.05    -- output-level tolerance
    );
end entity;

architecture sim of tb_channel_normalizer_mux is

    constant DATA_W    : positive := 16;
    constant CHAN_W    : positive := 6;
    constant GAIN_W    : positive := 16;
    constant GAIN_FRAC : positive := 10;
    constant POWER_W   : positive := 31;
    constant LATENCY   : positive := 5;

    constant UNITY     : integer := 2**GAIN_FRAC;   -- 1024
    constant GAIN_MAX  : integer := 2**GAIN_W - 1;  -- 65535

    -- the three registers, at their recommended values (see NORMALIZER_REGISTERS.md)
    constant C_TARGET  : integer := 16000;   -- -6.2 dBFS setpoint
    constant C_SQUELCH : integer := 65536;   -- amplitude 256; >= (16000*1024/65535)^2

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';

    signal in_valid : std_logic := '0';
    signal in_chan  : unsigned(CHAN_W-1 downto 0) := (others => '0');
    signal in_last  : std_logic := '0';
    signal in_i, in_q : signed(DATA_W-1 downto 0) := (others => '0');
    signal power    : std_logic_vector(POWER_W-1 downto 0) := (others => '0');

    signal gain_mode   : std_logic := '0';
    signal gain_target : std_logic_vector(GAIN_W-1 downto 0) :=
                         std_logic_vector(to_unsigned(C_TARGET, GAIN_W));
    signal squelch_thr : std_logic_vector(POWER_W-1 downto 0) :=
                         std_logic_vector(to_unsigned(C_SQUELCH, POWER_W));
    signal gain_manual : std_logic_vector(GAIN_W-1 downto 0) :=
                         std_logic_vector(to_unsigned(UNITY, GAIN_W));

    signal out_valid : std_logic;
    signal out_chan  : unsigned(CHAN_W-1 downto 0);
    signal out_last  : std_logic;
    signal out_i, out_q : signed(DATA_W-1 downto 0);
    signal gain_current : std_logic_vector(GAIN_W-1 downto 0);
    signal gain_sat     : std_logic;

    signal errs : integer := 0;
    signal lat_meas : integer := -1;
    signal done : boolean := false;

    -- A1b capture. out_valid for the first beats of a burst arrives while the
    -- LAST beats are still being driven, so the checker cannot be inline with
    -- the driver -- it would miss them and then wait forever. Concurrent monitor.
    constant NB : integer := 8;
    type ia is array (1 to NB) of integer;
    signal cap_i, cap_c : ia := (others => 0);
    signal cap_l : std_logic_vector(1 to NB) := (others => '0');
    signal cap_n : integer := 0;
    signal cap_en : boolean := false;

    procedure fail(msg : in string; signal e : inout integer) is
    begin
        report "FAIL: " & msg severity error;
        e <= e + 1;
    end procedure;

begin
    clk <= not clk after 5 ns when not done else '0';

    monitor : process(clk)
    begin
        if rising_edge(clk) then
            if cap_en and out_valid = '1' and cap_n < NB then
                cap_n <= cap_n + 1;
                cap_i(cap_n + 1) <= to_integer(out_i);
                cap_c(cap_n + 1) <= to_integer(out_chan);
                cap_l(cap_n + 1) <= out_last;
            end if;
        end if;
    end process;

    dut : entity work.channel_normalizer_mux
        generic map (DATA_W => DATA_W, CHAN_W => CHAN_W, GAIN_W => GAIN_W,
                     GAIN_FRAC => GAIN_FRAC, POWER_W => POWER_W,
                     MANT_FRAC => 6, ROM_FRAC => 15)
        port map (
            clk => clk, rst => rst,
            in_valid => in_valid, in_chan => in_chan, in_last => in_last,
            in_i => in_i, in_q => in_q, power => power,
            gain_mode => gain_mode, gain_target => gain_target,
            squelch_thr => squelch_thr, gain_manual => gain_manual,
            out_valid => out_valid, out_chan => out_chan, out_last => out_last,
            out_i => out_i, out_q => out_q,
            gain_current => gain_current, gain_sat => gain_sat);

    main : process
        variable nclk : integer;
        variable e0   : integer;
        variable g_rtl, g_exact : real;
        variable err_db : real;
        variable worst  : real := 0.0;
        variable lvl    : real;
        variable A      : integer;
        variable p      : integer;
        variable oi1, oq1 : integer;

        -- present one beat and wait LATENCY clocks for it to emerge
        procedure beat(constant ii, qq, pw, ch : in integer; constant lst : in std_logic) is
        begin
            in_i <= to_signed(ii, DATA_W);
            in_q <= to_signed(qq, DATA_W);
            power <= std_logic_vector(to_unsigned(pw, POWER_W));
            in_chan <= to_unsigned(ch, CHAN_W);
            in_last <= lst;
            in_valid <= '1';
            wait until rising_edge(clk);
            in_valid <= '0';
            for k in 1 to LATENCY loop wait until rising_edge(clk); end loop;
        end procedure;
    begin
        rst <= '1'; wait for 100 ns;
        wait until rising_edge(clk); rst <= '0'; wait until rising_edge(clk);

        -----------------------------------------------------------------------
        -- A1 latency == 5, sideband travels with the data.  A2 bypass identity.
        -----------------------------------------------------------------------
        e0 := errs;
        gain_mode <= '0';
        gain_manual <= std_logic_vector(to_unsigned(UNITY, GAIN_W));
        wait until rising_edge(clk);

        for b in 1 to 6 loop
            in_i <= to_signed(b*1000, DATA_W);
            in_q <= to_signed(-b*777, DATA_W);
            power <= std_logic_vector(to_unsigned(C_SQUELCH, POWER_W));
            in_chan <= to_unsigned(b mod 64, CHAN_W);
            if b = 3 then in_last <= '1'; else in_last <= '0'; end if;
            in_valid <= '1';
            wait until rising_edge(clk);
            in_valid <= '0';

            if b > 1 and out_i = to_signed(b*1000, DATA_W) then
                fail("A1: out already correct at the raw upstream valid", errs);
            end if;

            nclk := 0;
            loop
                wait until rising_edge(clk);
                nclk := nclk + 1;
                exit when out_valid = '1';
                if nclk > 10 then fail("A1: no out_valid within 10 clocks", errs); exit; end if;
            end loop;
            if lat_meas < 0 then lat_meas <= nclk; end if;
            if nclk /= LATENCY then
                fail("A1: latency = " & integer'image(nclk) & ", expected "
                     & integer'image(LATENCY), errs);
            end if;
            if out_i /= to_signed(b*1000, DATA_W) or out_q /= to_signed(-b*777, DATA_W) then
                fail("A2: bypass is not a bit-exact identity at beat "
                     & integer'image(b), errs);
            end if;
            if out_chan /= to_unsigned(b mod 64, CHAN_W) then
                fail("A1: out_chan does not travel with the data", errs);
            end if;
            if (b = 3 and out_last /= '1') or (b /= 3 and out_last /= '0') then
                fail("A1: out_last does not travel with the data", errs);
            end if;
            wait until rising_edge(clk);
        end loop;
        -- A1b: BACK-TO-BACK beats with distinct tags. A single beat followed by
        -- idle cannot see a one-stage tag skew, because the alignment pipeline
        -- holds the same value in adjacent stages. A burst can.
        cap_en <= true;
        wait until rising_edge(clk);
        for b in 1 to NB loop
            in_i    <= to_signed(b*100, DATA_W);
            in_q    <= to_signed(-b*50, DATA_W);
            power   <= std_logic_vector(to_unsigned(C_SQUELCH, POWER_W));
            in_chan <= to_unsigned(b, CHAN_W);
            if b = 5 then in_last <= '1'; else in_last <= '0'; end if;
            in_valid <= '1';
            wait until rising_edge(clk);
        end loop;
        in_valid <= '0'; in_last <= '0';
        for k in 1 to LATENCY + 3 loop wait until rising_edge(clk); end loop;
        cap_en <= false;
        wait until rising_edge(clk);

        if cap_n /= NB then
            fail("A1b: captured " & integer'image(cap_n) & " of " & integer'image(NB)
                 & " beats", errs);
        end if;
        for b in 1 to NB loop
            if cap_c(b) /= b then
                fail("A1b: tag skew -- beat " & integer'image(b) & " emerged with chan "
                     & integer'image(cap_c(b)), errs);
            end if;
            if cap_i(b) /= b*100 then
                fail("A1b: data/tag misalignment at beat " & integer'image(b), errs);
            end if;
            if (b = 5 and cap_l(b) /= '1') or (b /= 5 and cap_l(b) /= '0') then
                fail("A1b: out_last skewed at beat " & integer'image(b), errs);
            end if;
        end loop;

        if errs = e0 then
            report "A1 PASS: latency = 5; out_valid, out_chan and out_last carry the data";
            report "A1b PASS: 8 back-to-back beats emerge in order, tags aligned";
            report "A2 PASS: gain_mode='0' with gain_manual=0x0400 is a bit-exact identity";
        end if;

        -----------------------------------------------------------------------
        -- A3 saturation clamps, gain_sat asserts.
        -----------------------------------------------------------------------
        e0 := errs;
        gain_manual <= std_logic_vector(to_unsigned(60*UNITY, GAIN_W));
        wait until rising_edge(clk);
        beat(30000, -30000, C_SQUELCH, 9, '0');
        if out_i /= to_signed(2**(DATA_W-1)-1, DATA_W) then
            fail("A3: positive overflow did not clamp (got "
                 & integer'image(to_integer(out_i)) & ") -- WRAPAROUND", errs);
        end if;
        if out_q /= to_signed(-(2**(DATA_W-1)), DATA_W) then
            fail("A3: negative overflow did not clamp (got "
                 & integer'image(to_integer(out_q)) & ") -- WRAPAROUND", errs);
        end if;
        if gain_sat /= '1' then fail("A3: gain_sat not asserted", errs); end if;
        if errs = e0 then
            report "A3 PASS: saturation clamps to +/-full scale, gain_sat asserts";
        end if;
        gain_manual <= std_logic_vector(to_unsigned(UNITY, GAIN_W));

        -----------------------------------------------------------------------
        -- A4 the gain law, over a 60 dB sweep of power.
        -----------------------------------------------------------------------
        e0 := errs;
        gain_mode <= '1';
        squelch_thr <= (others => '0');     -- unclamped, so the law is visible
        wait until rising_edge(clk);
        A := 32000;
        while A >= 300 loop
            p := A*A;
            beat(0, 0, p, 0, '0');
            g_rtl   := real(to_integer(unsigned(gain_current)));
            g_exact := real(C_TARGET) / real(A) * real(UNITY);
            if g_exact <= real(GAIN_MAX) then
                err_db := 20.0 * log10(g_rtl / g_exact);
                if abs(err_db) > worst then worst := abs(err_db); end if;
                if abs(err_db) > GAIN_TOL_DB then
                    fail("A4: gain law off by " & real'image(err_db) & " dB at amplitude "
                         & integer'image(A), errs);
                end if;
            end if;
            A := A / 2;
        end loop;
        if errs = e0 then
            report "A4 PASS: gain = TARGET/sqrt(power) over 60 dB; worst error "
                 & real'image(worst) & " dB";
        end if;

        -----------------------------------------------------------------------
        -- A5 THE POINT: every input amplitude comes out at GAIN_TARGET.
        -----------------------------------------------------------------------
        e0 := errs;
        A := 32000;
        while A >= 300 loop
            p := A*A;
            beat(A, 0, p, 0, '0');
            lvl := real(to_integer(out_i));
            if lvl > 0.0 then
                err_db := 20.0 * log10(lvl / real(C_TARGET));
                if abs(err_db) > LEVEL_TOL_DB then
                    fail("A5: input amplitude " & integer'image(A) & " emerged at "
                         & integer'image(to_integer(out_i)) & ", not "
                         & integer'image(C_TARGET), errs);
                end if;
            end if;
            A := A / 2;
        end loop;
        if errs = e0 then
            report "A5 PASS: every input amplitude from 32000 down to 500 emerges at "
                 & integer'image(C_TARGET) & " +/- " & real'image(LEVEL_TOL_DB) & " dB";
        end if;

        -----------------------------------------------------------------------
        -- A6 squelch floor: below it, the gain STOPS GROWING.
        -----------------------------------------------------------------------
        e0 := errs;
        squelch_thr <= std_logic_vector(to_unsigned(C_SQUELCH, POWER_W));
        wait until rising_edge(clk);
        beat(0, 0, C_SQUELCH, 0, '0');
        g_rtl := real(to_integer(unsigned(gain_current)));
        for k in 0 to 5 loop
            beat(0, 0, C_SQUELCH / (4**k), 0, '0');   -- 0, -6, -12 ... dB below
            if real(to_integer(unsigned(gain_current))) > g_rtl then
                fail("A6: gain grew below the squelch floor", errs);
            end if;
        end loop;
        if errs = e0 then
            report "A6 PASS: gain is clamped at " & integer'image(integer(g_rtl))
                 & " (" & real'image(g_rtl/real(UNITY)) & "x) below SQUELCH_THR;"
                 & " a dead channel cannot be amplified to full scale";
        end if;

        -----------------------------------------------------------------------
        -- A7 zero-power guard.
        -----------------------------------------------------------------------
        e0 := errs;
        squelch_thr <= (others => '0');
        wait until rising_edge(clk);
        beat(100, -100, 0, 0, '0');
        if is_x(std_logic_vector(out_i)) or is_x(std_logic_vector(out_q))
           or is_x(gain_current) then
            fail("A7: power=0 and squelch_thr=0 produced X", errs);
        end if;
        if errs = e0 then
            report "A7 PASS: power=0 with squelch_thr=0 produces no X";
        end if;
        squelch_thr <= std_logic_vector(to_unsigned(C_SQUELCH, POWER_W));

        -----------------------------------------------------------------------
        -- A8 the block has NO STATE. Same beat twice, unrelated traffic between.
        -----------------------------------------------------------------------
        e0 := errs;
        wait until rising_edge(clk);
        beat(5000, -3000, 25000000, 7, '0');
        oi1 := to_integer(out_i); oq1 := to_integer(out_q);
        -- 200 beats of unrelated traffic on other channels, other powers
        for k in 0 to 199 loop
            beat(((k*37) mod 20000) - 10000, ((k*91) mod 20000) - 10000,
                 100000 + k*1000000, (k mod 64), '0');
        end loop;
        beat(5000, -3000, 25000000, 7, '0');
        if to_integer(out_i) /= oi1 or to_integer(out_q) /= oq1 then
            fail("A8: the same beat gave a different answer. The block has STATE.", errs);
        end if;
        if errs = e0 then
            report "A8 PASS: identical beat, 200 unrelated beats apart, identical output."
                 & " The block is stateless.";
        end if;

        -----------------------------------------------------------------------
        report "=======================================================";
        report "tb_channel_normalizer_mux: failures = " & integer'image(errs);
        report "  latency=" & integer'image(lat_meas)
             & "  GAIN_TARGET=" & integer'image(C_TARGET)
             & "  SQUELCH_THR=" & integer'image(C_SQUELCH);
        assert errs = 0 report "CHANNEL NORMALIZER TB FAILED" severity failure;
        report "CHANNEL NORMALIZER TB PASSED (latency 5, bypass identity, saturation "
             & "clamp, gain law, constant output level, squelch floor, zero guard, "
             & "stateless)" severity note;
        report "=======================================================";
        done <= true;
        finish;
    end process;
end architecture sim;
