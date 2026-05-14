-------------------------------------------------------------------------------
-- tb_polyphase_M_timing.vhd
-- Verifies that polyphase_filterbank_parallel fires outputs_valid every M
-- input samples (not every N) when M_DECIMATION /= N_CHANNELS.
--
-- Test cases:
--   1.  N=64, M=64  (default / critical sampling, backward compat)
--   2.  N=64, M=16  (Haifuraiya production: 4x oversampled)
--   3.  N=64, M=32  (2x oversampled)
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_polyphase_M_timing is
end entity;

architecture sim of tb_polyphase_M_timing is

    constant N_CHANNELS_C  : positive := 64;
    constant TAPS_C        : positive := 24;
    constant DATA_W_C      : positive := 16;
    constant COEFF_W_C     : positive := 16;
    constant ACCUM_W_C     : positive := 40;
    constant COEFF_FILE_C  : string   := "haifuraiya_coeffs.hex";
    constant CLK_PERIOD    : time     := 10 ns;  -- 100 MHz

    -- Per-test signals (one set per configuration)
    type test_io_t is record
        sample_in     : std_logic_vector(DATA_W_C - 1 downto 0);
        sample_valid  : std_logic;
        outputs_valid : std_logic;
        branch_out    : std_logic_vector(N_CHANNELS_C * ACCUM_W_C - 1 downto 0);
    end record;

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';

    signal io_m64 : test_io_t := (sample_in => (others => '0'),
                                  sample_valid => '0',
                                  outputs_valid => '0',
                                  branch_out => (others => '0'));
    signal io_m32 : test_io_t := (sample_in => (others => '0'),
                                  sample_valid => '0',
                                  outputs_valid => '0',
                                  branch_out => (others => '0'));
    signal io_m16 : test_io_t := (sample_in => (others => '0'),
                                  sample_valid => '0',
                                  outputs_valid => '0',
                                  branch_out => (others => '0'));

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    ---------------------------------------------------------------------------
    -- Three instances, one per M value, all driven from the same stimulus
    ---------------------------------------------------------------------------
    u_m64 : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS       => N_CHANNELS_C,
            M_DECIMATION     => 64,
            TAPS_PER_BRANCH  => TAPS_C,
            DATA_WIDTH       => DATA_W_C,
            COEFF_WIDTH      => COEFF_W_C,
            ACCUM_WIDTH      => ACCUM_W_C,
            COEFF_FILE       => COEFF_FILE_C
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => io_m64.sample_in,
            sample_valid   => io_m64.sample_valid,
            branch_outputs => io_m64.branch_out,
            outputs_valid  => io_m64.outputs_valid
        );

    u_m32 : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS       => N_CHANNELS_C,
            M_DECIMATION     => 32,
            TAPS_PER_BRANCH  => TAPS_C,
            DATA_WIDTH       => DATA_W_C,
            COEFF_WIDTH      => COEFF_W_C,
            ACCUM_WIDTH      => ACCUM_W_C,
            COEFF_FILE       => COEFF_FILE_C
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => io_m32.sample_in,
            sample_valid   => io_m32.sample_valid,
            branch_outputs => io_m32.branch_out,
            outputs_valid  => io_m32.outputs_valid
        );

    u_m16 : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS       => N_CHANNELS_C,
            M_DECIMATION     => 16,
            TAPS_PER_BRANCH  => TAPS_C,
            DATA_WIDTH       => DATA_W_C,
            COEFF_WIDTH      => COEFF_W_C,
            ACCUM_WIDTH      => ACCUM_W_C,
            COEFF_FILE       => COEFF_FILE_C
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => io_m16.sample_in,
            sample_valid   => io_m16.sample_valid,
            branch_outputs => io_m16.branch_out,
            outputs_valid  => io_m16.outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Stimulus + per-instance frame-timing check
    --
    -- Drives sample_valid='1' for one clock every CLK_PER_SAMPLE clocks,
    -- with a unit-amplitude tone at channel 4 center frequency.
    -- Counts samples between outputs_valid pulses; reports if any are
    -- not exactly M.
    ---------------------------------------------------------------------------
    stim_proc : process
        constant CLK_PER_SAMPLE : positive := 10;
        constant N_SAMPLES      : positive := 64 * 12;    -- 12 critical frames
        constant TONE_BIN       : real     := 4.0;
        constant N_REAL         : real     := real(N_CHANNELS_C);

        variable sample_re  : integer;
        variable angle      : real := 0.0;
        variable two_pi     : real := 2.0 * 3.14159265358979;

        -- Frame timing tracking (per instance)
        type tracker_t is record
            seen_first      : boolean;
            samples_since   : integer;
            frame_count     : integer;
            bad_count       : integer;
            expected_M      : integer;
        end record;
        variable t_m64 : tracker_t := (false, 0, 0, 0, 64);
        variable t_m32 : tracker_t := (false, 0, 0, 0, 32);
        variable t_m16 : tracker_t := (false, 0, 0, 0, 16);

        procedure check_one(signal valid_pulse : in std_logic;
                            variable t        : inout tracker_t;
                            sample_just_fired : in boolean;
                            constant name     : in string) is
        begin
            -- Count samples between outputs_valid pulses.
            -- outputs_valid is the d1-pipelined version, so it appears one
            -- clock AFTER frame_complete_d0 was asserted, which was the cycle
            -- the Mth sample arrived.  So the "samples since last frame" at
            -- the time outputs_valid='1' should be exactly M.
            if sample_just_fired then
                t.samples_since := t.samples_since + 1;
            end if;
            if valid_pulse = '1' then
                t.frame_count := t.frame_count + 1;
                if t.seen_first then
                    if t.samples_since /= t.expected_M then
                        report name & ": frame " & integer'image(t.frame_count) &
                               " arrived after " & integer'image(t.samples_since) &
                               " samples (expected " & integer'image(t.expected_M) & ")"
                               severity warning;
                        t.bad_count := t.bad_count + 1;
                    end if;
                end if;
                t.seen_first := true;
                t.samples_since := 0;
            end if;
        end procedure;

    begin
        -- Reset
        reset <= '1';
        io_m64.sample_valid <= '0';
        io_m32.sample_valid <= '0';
        io_m16.sample_valid <= '0';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Drive samples and check frame timing each clock
        for n in 0 to N_SAMPLES - 1 loop
            -- Generate tone at channel 4
            angle := two_pi * TONE_BIN * real(n) / N_REAL;
            sample_re := integer(15000.0 * cos(angle));

            -- Assert valid + sample for 1 clock
            io_m64.sample_in    <= std_logic_vector(to_signed(sample_re, DATA_W_C));
            io_m32.sample_in    <= std_logic_vector(to_signed(sample_re, DATA_W_C));
            io_m16.sample_in    <= std_logic_vector(to_signed(sample_re, DATA_W_C));
            io_m64.sample_valid <= '1';
            io_m32.sample_valid <= '1';
            io_m16.sample_valid <= '1';
            wait until rising_edge(clk);
            check_one(io_m64.outputs_valid, t_m64, true,  "M=64");
            check_one(io_m32.outputs_valid, t_m32, true,  "M=32");
            check_one(io_m16.outputs_valid, t_m16, true,  "M=16");

            io_m64.sample_valid <= '0';
            io_m32.sample_valid <= '0';
            io_m16.sample_valid <= '0';
            -- Hold for the remaining clocks of the sample period
            for k in 1 to CLK_PER_SAMPLE - 1 loop
                wait until rising_edge(clk);
                check_one(io_m64.outputs_valid, t_m64, false, "M=64");
                check_one(io_m32.outputs_valid, t_m32, false, "M=32");
                check_one(io_m16.outputs_valid, t_m16, false, "M=16");
            end loop;
        end loop;

        -- Allow trailing frame_complete pulses to drain
        for k in 0 to 50 loop
            wait until rising_edge(clk);
            check_one(io_m64.outputs_valid, t_m64, false, "M=64");
            check_one(io_m32.outputs_valid, t_m32, false, "M=32");
            check_one(io_m16.outputs_valid, t_m16, false, "M=16");
        end loop;

        -- Report
        report "=== M=64: " & integer'image(t_m64.frame_count) & " frames, " &
               integer'image(t_m64.bad_count) & " bad spacings ===";
        report "=== M=32: " & integer'image(t_m32.frame_count) & " frames, " &
               integer'image(t_m32.bad_count) & " bad spacings ===";
        report "=== M=16: " & integer'image(t_m16.frame_count) & " frames, " &
               integer'image(t_m16.bad_count) & " bad spacings ===";

        -- Expected frame counts (modulo warm-up):
        --   N_SAMPLES = 768
        --   M=64  -> 12 frames
        --   M=32  -> 24 frames
        --   M=16  -> 48 frames
        assert t_m64.frame_count = 12
            report "M=64 frame count " & integer'image(t_m64.frame_count) &
                   " /= expected 12"
            severity error;
        assert t_m32.frame_count = 24
            report "M=32 frame count " & integer'image(t_m32.frame_count) &
                   " /= expected 24"
            severity error;
        assert t_m16.frame_count = 48
            report "M=16 frame count " & integer'image(t_m16.frame_count) &
                   " /= expected 48"
            severity error;
        assert t_m64.bad_count = 0
            report "M=64 has bad spacings"
            severity error;
        assert t_m32.bad_count = 0
            report "M=32 has bad spacings"
            severity error;
        assert t_m16.bad_count = 0
            report "M=16 has bad spacings"
            severity error;

        report "ALL TESTS PASSED" severity note;

        sim_done <= true;
        wait;
    end process;

end architecture;
