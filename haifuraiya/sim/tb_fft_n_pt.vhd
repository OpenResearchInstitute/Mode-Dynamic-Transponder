-- =========================================================================
-- Standalone testbench for fft_n_pt.
--
-- Drives the FFT with several test vectors (DC, tones at various k, impulse,
-- random) and dumps each output frame to a text file. A Python script then
-- compares to numpy.fft to verify.
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.fft_pkg.all;

entity tb_fft_n_pt is
end entity;

architecture rtl of tb_fft_n_pt is

    constant CLK_PERIOD : time     := 10 ns;
    constant N          : positive := 64;
    constant DATA_WIDTH : positive := 40;
    constant LOG2_N     : positive := clog2(N);

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal running : boolean   := true;

    signal x_re    : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal x_im    : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal x_idx   : std_logic_vector(LOG2_N - 1 downto 0)     := (others => '0');
    signal x_valid : std_logic := '0';
    signal x_last  : std_logic := '0';

    signal out_re    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal out_im    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal out_idx   : std_logic_vector(LOG2_N - 1 downto 0);
    signal out_valid : std_logic;
    signal out_last  : std_logic;
    signal busy      : std_logic;

    -- File output, one line per emitted sample, format:
    --     <test_label> <bin_idx> <re> <im>
    file dump_file : text open write_mode is "fft_n_dump.txt";

    -- Active test lbl (passed to capture process via signal)
    signal test_label : string(1 to 16) := (others => ' ');

begin

    ---------------------------------------------------------------------------
    -- Clock
    ---------------------------------------------------------------------------
    clk_proc : process
    begin
        while running loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.fft_n_pt
        generic map (
            N          => N,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_re      => x_re,
            x_im      => x_im,
            x_idx     => x_idx,
            x_valid   => x_valid,
            x_last    => x_last,
            out_re    => out_re,
            out_im    => out_im,
            out_idx   => out_idx,
            out_valid => out_valid,
            out_last  => out_last,
            busy      => busy
        );

    ---------------------------------------------------------------------------
    -- Capture process: write each emitted sample to the dump file.
    ---------------------------------------------------------------------------
    cap : process(clk)
        variable ln : line;
    begin
        if rising_edge(clk) and out_valid = '1' then
            write(ln, test_label);
            write(ln, string'(" "));
            write(ln, integer'image(to_integer(unsigned(out_idx))));
            write(ln, string'(" "));
            write(ln, integer'image(to_integer(signed(out_re))));
            write(ln, string'(" "));
            write(ln, integer'image(to_integer(signed(out_im))));
            writeline(dump_file, ln);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus: a sequence of test frames.
    ---------------------------------------------------------------------------
    stim : process

        ----------------------------------------------------------------------
        -- Feed one N-sample frame with the given (re, im) pair per index.
        ----------------------------------------------------------------------
        procedure feed_frame(
            re_int : in integer_vector(0 to N - 1);
            im_int : in integer_vector(0 to N - 1)
        ) is
        begin
            for nn in 0 to N - 1 loop
                x_re    <= std_logic_vector(to_signed(re_int(nn), DATA_WIDTH));
                x_im    <= std_logic_vector(to_signed(im_int(nn), DATA_WIDTH));
                x_idx   <= std_logic_vector(to_unsigned(nn, LOG2_N));
                x_valid <= '1';
                if nn = N - 1 then
                    x_last <= '1';
                else
                    x_last <= '0';
                end if;
                wait until rising_edge(clk);
            end loop;
            x_valid <= '0';
            x_last  <= '0';
            -- Wait for the FFT to finish this frame
            wait until busy = '0' for 50 us;
            wait for 5 * CLK_PERIOD;
        end procedure;

        ----------------------------------------------------------------------
        -- Set up a DC frame
        ----------------------------------------------------------------------
        procedure run_dc(amp : in integer; lbl : in string) is
            variable re_v, im_v : integer_vector(0 to N - 1);
        begin
            for nn in 0 to N - 1 loop
                re_v(nn) := amp;
                im_v(nn) := 0;
            end loop;
            test_label <= lbl & (lbl'length + 1 to 16 => ' ');
            wait for CLK_PERIOD;
            feed_frame(re_v, im_v);
        end procedure;

        ----------------------------------------------------------------------
        -- Set up a tone frame: exp(j*2*pi*k*n/N) * amp
        ----------------------------------------------------------------------
        procedure run_tone(k : in integer; amp : in integer; lbl : in string) is
            variable re_v, im_v : integer_vector(0 to N - 1);
            variable angle      : real;
        begin
            for nn in 0 to N - 1 loop
                angle    := 2.0 * MATH_PI * real(k) * real(nn) / real(N);
                re_v(nn) := integer(real(amp) * cos(angle));
                im_v(nn) := integer(real(amp) * sin(angle));
            end loop;
            test_label <= lbl & (lbl'length + 1 to 16 => ' ');
            wait for CLK_PERIOD;
            feed_frame(re_v, im_v);
        end procedure;

        ----------------------------------------------------------------------
        -- Set up an impulse frame: x[0] = amp, x[n>0] = 0
        ----------------------------------------------------------------------
        procedure run_impulse(amp : in integer; lbl : in string) is
            variable re_v, im_v : integer_vector(0 to N - 1);
        begin
            re_v(0) := amp;
            im_v(0) := 0;
            for nn in 1 to N - 1 loop
                re_v(nn) := 0;
                im_v(nn) := 0;
            end loop;
            test_label <= lbl & (lbl'length + 1 to 16 => ' ');
            wait for CLK_PERIOD;
            feed_frame(re_v, im_v);
        end procedure;

    begin
        report "fft_n_pt standalone testbench" severity note;

        wait for 5 * CLK_PERIOD;
        reset <= '0';
        wait until rising_edge(clk);
        wait for CLK_PERIOD;

        -- DC test
        run_dc(16384, "dc");

        -- Tone tests at various k.  Amplitude well below 2^39 to avoid overflow
        -- after 6 stages of accumulation (worst case grows by ~N).
        run_tone( 0, 16384, "tone_k0");
        run_tone( 1, 16384, "tone_k1");
        run_tone( 4, 16384, "tone_k4");
        run_tone( 7, 16384, "tone_k7");
        run_tone(16, 16384, "tone_k16");
        run_tone(28, 16384, "tone_k28");
        run_tone(32, 16384, "tone_k32");
        run_tone(40, 16384, "tone_k40");
        run_tone(55, 16384, "tone_k55");
        run_tone(63, 16384, "tone_k63");

        -- Impulse: should give a flat magnitude across all bins
        run_impulse(16384, "impulse");

        report "fft_n_pt standalone testbench: complete" severity note;
        running <= false;
        wait;
    end process;

end architecture;
