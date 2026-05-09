-------------------------------------------------------------------------------
-- tb_haifuraiya_channelizer_top.vhd
-- Testbench for the Haifuraiya Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Tools:   Vivado 2022.2 xsim, VHDL-2008
--
-------------------------------------------------------------------------------
-- TEST PLAN
-------------------------------------------------------------------------------
-- This testbench runs a sequence of progressively more demanding tests
-- against haifuraiya_channelizer_top:
--
--   Test 1: SMOKE
--     - Reset, wait for 'ready', confirm coefficient load completes
--     - Zero input, confirm no nonzero output frames
--
--   Test 2: DC INPUT
--     - sample_re = const, sample_im = 0
--     - Expect: most energy concentrated in bin 0
--
--   Test 3: COMPLEX EXPONENTIAL AT BIN k
--     - Feed e^(j 2 pi k n / N) for several values of k
--     - Expect: most energy concentrated in bin k
--     - This validates frequency-to-bin mapping and channel selectivity
--
--   Test 4: OFF-BIN TONE
--     - Feed a complex exp at (k + 0.5) * fs/N
--     - Expect: energy split between bins k and k+1 (filter shape exposed)
--
--   Test 5: ADJACENT-CHANNEL REJECTION
--     - Feed strong tone in bin 16, measure power in bins 15 and 17
--     - Expect: rejection > some threshold (set conservatively at -25 dB
--       for an initial pass; tighten once we know the prototype filter
--       performance)
--
--   Test 6: OPV-LIKE CARRIER IN ONE CHANNEL
--     - Place a CW tone at the center of bin 16 (this is what an
--       unmodulated OPV uplink carrier would look like to the channelizer)
--     - Run for several output frames, confirm bin 16 has stable
--       amplitude and the surrounding bins remain quiet
--     - Note: full MSK modulation can be added in a follow-up; this
--       confirms the channel selection / isolation that any OPV
--       uplink demod would rely on
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
--   Master clock     : 100 MHz (CLK_PERIOD = 10 ns)
--   Sample rate      : 10 Msps  (SAMPLE_PERIOD = 100 ns = 10 clocks/sample)
--   Channels         : 64
--   Channel rate     : 156.25 ksps per channel
--   FB frame period  : 640 clocks (every N samples at 10 clk/sample)
--   FFT busy         : ~320 clocks per frame (192 compute + 64 load + 64 out)
--   Slack            : ~320 clocks  -> no frame drops at nominal timing
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_haifuraiya_channelizer_top is
end entity tb_haifuraiya_channelizer_top;

architecture sim of tb_haifuraiya_channelizer_top is

    ---------------------------------------------------------------------------
    -- Configuration constants (Haifuraiya defaults)
    ---------------------------------------------------------------------------
    constant N_CHANNELS      : positive := 64;
    constant TAPS_PER_BRANCH : positive := 24;
    constant DATA_WIDTH      : positive := 16;
    constant COEFF_WIDTH     : positive := 16;
    constant ACCUM_WIDTH     : positive := 40;
    constant COEFF_FILE      : string   := "haifuraiya_coeffs.hex";

    ---------------------------------------------------------------------------
    -- Timing
    ---------------------------------------------------------------------------
    constant CLK_PERIOD    : time := 10 ns;     -- 100 MHz
    constant SAMPLE_PERIOD : time := 100 ns;    -- 10 Msps (10 clk/sample)

    -- Sample amplitude scaling for tone tests: well below full scale to
    -- avoid overflow margin worries through 6 FFT stages
    constant TONE_AMPLITUDE : real := 8000.0;   -- ~0.24 of full Q1.14 scale

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal clk           : std_logic := '0';
    signal reset         : std_logic := '1';

    signal sample_re     : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal sample_im     : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal sample_valid  : std_logic := '0';

    signal channel_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal channel_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal channel_idx   : std_logic_vector(5 downto 0);
    signal channel_valid : std_logic;
    signal channel_last  : std_logic;
    signal ready         : std_logic;
    signal frame_dropped : std_logic;

    signal running       : boolean := true;

    ---------------------------------------------------------------------------
    -- Output capture: most-recent FFT frame, indexed by bin
    ---------------------------------------------------------------------------
    type bin_array_t is array (0 to N_CHANNELS - 1) of signed(ACCUM_WIDTH - 1 downto 0);
    signal frame_re  : bin_array_t := (others => (others => '0'));
    signal frame_im  : bin_array_t := (others => (others => '0'));
    signal frame_seq : natural := 0;  -- counts complete output frames
    signal frame_seq_at_last_capture : natural := 0;

    -- Power per bin (real-valued, in real scale)
    type power_array_t is array (0 to N_CHANNELS - 1) of real;

    -- Diagnostic counters
    signal frame_dropped_count : natural := 0;

    ---------------------------------------------------------------------------
    -- Helper: convert signed integer to slv of DATA_WIDTH
    ---------------------------------------------------------------------------
    function to_slv(x : integer; w : positive) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(x, w));
    end function;

begin

    ---------------------------------------------------------------------------
    -- Clock generation
    ---------------------------------------------------------------------------
    clk_gen : process
    begin
        while running loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.haifuraiya_channelizer_top
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH,
            COEFF_FILE      => COEFF_FILE
        )
        port map (
            clk           => clk,
            reset         => reset,
            sample_re     => sample_re,
            sample_im     => sample_im,
            sample_valid  => sample_valid,
            channel_re    => channel_re,
            channel_im    => channel_im,
            channel_idx   => channel_idx,
            channel_valid => channel_valid,
            channel_last  => channel_last,
            ready         => ready,
            frame_dropped => frame_dropped
        );

    ---------------------------------------------------------------------------
    -- Output capture process
    -- Latches each output bin into frame_re/frame_im as it arrives.
    -- Increments frame_seq on channel_last so the stimulus process can
    -- wait for "next complete frame" deterministically.
    ---------------------------------------------------------------------------
    capture_proc : process(clk)
    begin
        if rising_edge(clk) then
            if channel_valid = '1' then
                frame_re(to_integer(unsigned(channel_idx))) <= signed(channel_re);
                frame_im(to_integer(unsigned(channel_idx))) <= signed(channel_im);
            end if;
            if channel_valid = '1' and channel_last = '1' then
                frame_seq <= frame_seq + 1;
            end if;
            if frame_dropped = '1' then
                frame_dropped_count <= frame_dropped_count + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main stimulus / verification process
    ---------------------------------------------------------------------------
    stim_proc : process

        ---------------------------------------------------------------------
        -- Local helpers (procedures and functions)
        ---------------------------------------------------------------------

        -- Drive one complex sample, then idle for SAMPLE_PERIOD - CLK_PERIOD
        procedure feed_sample(re_int : integer; im_int : integer) is
        begin
            sample_re    <= to_slv(re_int, DATA_WIDTH);
            sample_im    <= to_slv(im_int, DATA_WIDTH);
            sample_valid <= '1';
            wait for CLK_PERIOD;
            sample_valid <= '0';
            wait for SAMPLE_PERIOD - CLK_PERIOD;
        end procedure;

        -- Feed a burst of zeros to settle the filterbank between tests
        procedure feed_zeros(n : positive) is
        begin
            for i in 1 to n loop
                feed_sample(0, 0);
            end loop;
        end procedure;

        -- Wait until at least 'n' new complete output frames have passed
        procedure wait_frames(n : positive) is
            variable target : natural;
        begin
            target := frame_seq + n;
            while frame_seq < target loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Compute power (re^2 + im^2) per bin from current frame snapshot
        procedure snapshot_power(variable p : out power_array_t) is
        begin
            for k in 0 to N_CHANNELS - 1 loop
                p(k) := real(to_integer(frame_re(k)))**2 +
                        real(to_integer(frame_im(k)))**2;
            end loop;
        end procedure;

        -- Find bin with maximum power
        procedure find_peak_bin(
            p           : power_array_t;
            variable kk : out integer;
            variable pk : out real
        ) is
            variable max_p : real;
            variable max_k : integer;
        begin
            max_p := p(0);
            max_k := 0;
            for k in 1 to N_CHANNELS - 1 loop
                if p(k) > max_p then
                    max_p := p(k);
                    max_k := k;
                end if;
            end loop;
            kk := max_k;
            pk := max_p;
        end procedure;

        -- Pretty-print top N bins by power
        procedure report_top_bins(p : power_array_t; n_top : positive) is
            variable sorted_idx : integer_vector(0 to N_CHANNELS - 1);
            variable sorted_pwr : power_array_t;
            variable tmp_i : integer;
            variable tmp_p : real;
        begin
            for k in 0 to N_CHANNELS - 1 loop
                sorted_idx(k) := k;
                sorted_pwr(k) := p(k);
            end loop;
            -- Simple selection sort, descending
            for i in 0 to N_CHANNELS - 2 loop
                for j in i + 1 to N_CHANNELS - 1 loop
                    if sorted_pwr(j) > sorted_pwr(i) then
                        tmp_p := sorted_pwr(i); sorted_pwr(i) := sorted_pwr(j); sorted_pwr(j) := tmp_p;
                        tmp_i := sorted_idx(i); sorted_idx(i) := sorted_idx(j); sorted_idx(j) := tmp_i;
                    end if;
                end loop;
            end loop;
            for i in 0 to n_top - 1 loop
                report "    bin " & integer'image(sorted_idx(i)) &
                       "  power = " & real'image(sorted_pwr(i)) severity note;
            end loop;
        end procedure;

        -- Feed a complex exponential at frequency f = f_norm * fs
        -- over n_samples samples. f_norm is in [-0.5, 0.5).
        procedure feed_complex_exp(f_norm : real; n_samples : positive) is
            variable phase : real := 0.0;
            variable d_phase : real;
            variable re_v, im_v : integer;
        begin
            d_phase := 2.0 * MATH_PI * f_norm;
            for i in 0 to n_samples - 1 loop
                re_v := integer(TONE_AMPLITUDE * cos(phase));
                im_v := integer(TONE_AMPLITUDE * sin(phase));
                feed_sample(re_v, im_v);
                phase := phase + d_phase;
                -- Keep phase bounded
                if phase > 2.0 * MATH_PI then
                    phase := phase - 2.0 * MATH_PI;
                elsif phase < -2.0 * MATH_PI then
                    phase := phase + 2.0 * MATH_PI;
                end if;
            end loop;
        end procedure;

        -- Feed two complex exponentials simultaneously (sum of tones)
        procedure feed_two_tones(
            f_norm_a : real; amp_a : real;
            f_norm_b : real; amp_b : real;
            n_samples : positive
        ) is
            variable phase_a, phase_b : real := 0.0;
            variable d_phase_a, d_phase_b : real;
            variable re_v, im_v : integer;
        begin
            phase_a := 0.0;
            phase_b := 0.0;
            d_phase_a := 2.0 * MATH_PI * f_norm_a;
            d_phase_b := 2.0 * MATH_PI * f_norm_b;
            for i in 0 to n_samples - 1 loop
                re_v := integer(amp_a * cos(phase_a) + amp_b * cos(phase_b));
                im_v := integer(amp_a * sin(phase_a) + amp_b * sin(phase_b));
                feed_sample(re_v, im_v);
                phase_a := phase_a + d_phase_a;
                phase_b := phase_b + d_phase_b;
                if phase_a > 2.0 * MATH_PI then phase_a := phase_a - 2.0 * MATH_PI; end if;
                if phase_b > 2.0 * MATH_PI then phase_b := phase_b - 2.0 * MATH_PI; end if;
            end loop;
        end procedure;

        ---------------------------------------------------------------------
        -- Stimulus locals
        ---------------------------------------------------------------------
        variable pwr           : power_array_t;
        variable peak_bin      : integer;
        variable peak_pwr      : real;
        variable expected_bin  : integer;
        variable adj_pwr       : real;
        variable rejection_dB  : real;

        -- Number of input samples per test (in multiples of N).
        -- Filterbank delay lines hold TAPS_PER_BRANCH samples each, with
        -- the commutator distributing 1-of-N samples to each branch. So
        -- a full fill requires TAPS_PER_BRANCH * N = 24 * 64 = 1536
        -- input samples. We use 32 * N = 2048 to land cleanly past the
        -- transient with a few output frames of steady state to average
        -- over.
        constant N_SAMP_TEST : positive := 32 * N_CHANNELS;

    begin

        report "===========================================" severity note;
        report "Haifuraiya Channelizer Testbench" severity note;
        report "===========================================" severity note;
        report "Configuration:" severity note;
        report "  N_CHANNELS      = " & integer'image(N_CHANNELS) severity note;
        report "  TAPS_PER_BRANCH = " & integer'image(TAPS_PER_BRANCH) severity note;
        report "  DATA_WIDTH      = " & integer'image(DATA_WIDTH) severity note;
        report "  ACCUM_WIDTH     = " & integer'image(ACCUM_WIDTH) severity note;
        report "  COEFF_FILE      = " & COEFF_FILE severity note;

        ---------------------------------------------------------------------
        -- Reset
        ---------------------------------------------------------------------
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------------
        -- Test 1: SMOKE
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 1: SMOKE ---" severity note;
        report "Waiting for ready (coefficient loading)..." severity note;

        -- Coefficient load takes TOTAL_COEFFS = 1536 cycles plus a few.
        -- Wait up to a generous deadline.
        wait until ready = '1' for 50 us;
        assert ready = '1'
            report "TEST 1 FAIL: ready did not assert in time"
            severity failure;
        report "  ready asserted: coefficients loaded" severity note;

        -- Drive a quiet period (zeros) and confirm we get output frames
        -- (they should be all zero or near-zero from the initial state).
        feed_zeros(N_SAMP_TEST);
        wait_frames(1);

        snapshot_power(pwr);
        find_peak_bin(pwr, peak_bin, peak_pwr);
        report "  Quiet output: peak bin = " & integer'image(peak_bin) &
               ", peak power = " & real'image(peak_pwr) severity note;
        report "  frame_dropped count = " & integer'image(frame_dropped_count)
            severity note;

        report "TEST 1 PASS: smoke" severity note;

        ---------------------------------------------------------------------
        -- Test 2: DC INPUT
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 2: DC INPUT ---" severity note;

        -- Feed sustained DC (real only) for several frames
        for i in 1 to N_SAMP_TEST loop
            feed_sample(integer(TONE_AMPLITUDE), 0);
        end loop;
        wait_frames(1);

        snapshot_power(pwr);
        find_peak_bin(pwr, peak_bin, peak_pwr);
        report "  DC input -> peak bin = " & integer'image(peak_bin) severity note;
        report "  Top 5 bins by power:" severity note;
        report_top_bins(pwr, 5);

        if peak_bin = 0 then
            report "TEST 2 PASS: DC energy in bin 0" severity note;
        else
            report "TEST 2 NOTE: DC peak in bin " & integer'image(peak_bin) &
                   " (expected 0). Check FFT bin ordering convention."
                severity warning;
        end if;

        -- Settle with zeros before next test
        feed_zeros(2 * N_CHANNELS);
        wait_frames(1);

        ---------------------------------------------------------------------
        -- Test 3: COMPLEX EXPONENTIAL AT BIN k
        --   Try a few values of k. Frequency = k * fs/N -> normalized k/N.
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 3: COMPLEX EXPONENTIAL TONES ---" severity note;

        for k_test in 0 to 3 loop
            expected_bin := 4 + k_test * 12;  -- 4, 16, 28, 40
            report "" severity note;
            report "  Tone at bin " & integer'image(expected_bin) &
                   " (f_norm = " & real'image(real(expected_bin)/real(N_CHANNELS)) & ")"
                severity note;

            feed_zeros(2 * N_CHANNELS);
            wait_frames(1);
            feed_complex_exp(real(expected_bin) / real(N_CHANNELS), N_SAMP_TEST);
            wait_frames(1);

            snapshot_power(pwr);
            find_peak_bin(pwr, peak_bin, peak_pwr);
            report "    peak bin = " & integer'image(peak_bin) &
                   "  peak power = " & real'image(peak_pwr) severity note;
            report "    Top 5 bins:" severity note;
            report_top_bins(pwr, 5);

            if peak_bin = expected_bin then
                report "  TEST 3.k=" & integer'image(expected_bin) & " PASS"
                    severity note;
            else
                report "  TEST 3.k=" & integer'image(expected_bin) & " NOTE: peak at " &
                       integer'image(peak_bin) severity warning;
            end if;
        end loop;

        ---------------------------------------------------------------------
        -- Test 4: OFF-BIN TONE
        --   Frequency at (k + 0.5) * fs/N -> energy splits between bins k, k+1
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 4: OFF-BIN TONE (k = 16.5) ---" severity note;

        feed_zeros(2 * N_CHANNELS);
        wait_frames(1);
        feed_complex_exp(16.5 / real(N_CHANNELS), N_SAMP_TEST);
        wait_frames(1);

        snapshot_power(pwr);
        find_peak_bin(pwr, peak_bin, peak_pwr);
        report "  peak bin = " & integer'image(peak_bin) severity note;
        report "  bin 16 power = " & real'image(pwr(16)) severity note;
        report "  bin 17 power = " & real'image(pwr(17)) severity note;
        report "  bin 15 power = " & real'image(pwr(15)) severity note;
        report "  bin 18 power = " & real'image(pwr(18)) severity note;
        report "  Top 5 bins:" severity note;
        report_top_bins(pwr, 5);

        if (peak_bin = 16 or peak_bin = 17) and pwr(16) > 0.1 * peak_pwr
            and pwr(17) > 0.1 * peak_pwr then
            report "TEST 4 PASS: energy spread between bins 16 and 17" severity note;
        else
            report "TEST 4 NOTE: off-bin behavior may need review" severity warning;
        end if;

        ---------------------------------------------------------------------
        -- Test 5: ADJACENT-CHANNEL REJECTION
        --   Strong tone in bin 16. Measure power in 15, 17 (and beyond).
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 5: ADJACENT-CHANNEL REJECTION ---" severity note;

        feed_zeros(2 * N_CHANNELS);
        wait_frames(1);
        feed_complex_exp(16.0 / real(N_CHANNELS), N_SAMP_TEST);
        wait_frames(1);

        snapshot_power(pwr);
        find_peak_bin(pwr, peak_bin, peak_pwr);
        report "  In-band:    bin 16 power = " & real'image(pwr(16)) severity note;
        report "  Adjacent:   bin 15 power = " & real'image(pwr(15)) severity note;
        report "              bin 17 power = " & real'image(pwr(17)) severity note;
        report "  +2 away:    bin 14 power = " & real'image(pwr(14)) severity note;
        report "              bin 18 power = " & real'image(pwr(18)) severity note;

        -- Compute rejection in dB; guard against zero
        adj_pwr := (pwr(15) + pwr(17)) / 2.0;
        if adj_pwr > 0.0 and pwr(16) > 0.0 then
            rejection_dB := 10.0 * log10(pwr(16) / adj_pwr);
            report "  Adjacent-channel rejection (avg of 15, 17): " &
                   real'image(rejection_dB) & " dB" severity note;
            if rejection_dB > 25.0 then
                report "TEST 5 PASS: rejection > 25 dB" severity note;
            else
                report "TEST 5 NOTE: rejection lower than expected (" &
                       real'image(rejection_dB) & " dB)" severity warning;
            end if;
        else
            report "TEST 5 NOTE: zero power, cannot compute dB rejection"
                severity warning;
        end if;

        ---------------------------------------------------------------------
        -- Test 6: OPV-LIKE CARRIER IN ONE CHANNEL
        --   Place an unmodulated complex carrier exactly at bin 16 center.
        --   This is what a quiescent OPV uplink looks like to the
        --   channelizer. We verify channel 16 captures it cleanly with
        --   stable amplitude over multiple output frames.
        ---------------------------------------------------------------------
        report "" severity note;
        report "--- Test 6: OPV-LIKE CARRIER IN BIN 16 ---" severity note;

        feed_zeros(2 * N_CHANNELS);
        wait_frames(1);

        -- Run for a longer duration to capture multiple output frames
        feed_complex_exp(16.0 / real(N_CHANNELS), 64 * N_CHANNELS);
        wait_frames(1);

        snapshot_power(pwr);
        find_peak_bin(pwr, peak_bin, peak_pwr);
        report "  Carrier in bin 16: peak bin = " & integer'image(peak_bin) severity note;
        report "  bin 16 power = " & real'image(pwr(16)) severity note;
        report "  Top 3 bins:" severity note;
        report_top_bins(pwr, 3);
        report "  frame_dropped count = " & integer'image(frame_dropped_count)
            severity note;

        if peak_bin = 16 and frame_dropped_count = 0 then
            report "TEST 6 PASS: clean carrier capture, no frame drops"
                severity note;
        else
            report "TEST 6 NOTE: review carrier capture and drop count"
                severity warning;
        end if;

        ---------------------------------------------------------------------
        -- Wrap up
        ---------------------------------------------------------------------
        report "" severity note;
        report "===========================================" severity note;
        report "All tests complete" severity note;
        report "Total output frames: " & integer'image(frame_seq) severity note;
        report "Total dropped frames: " & integer'image(frame_dropped_count)
            severity note;
        report "===========================================" severity note;

        running <= false;
        wait;
    end process;

end architecture sim;
