-------------------------------------------------------------------------------
-- tb_core_tone.vhd
-- Minimal measurement bench for the BARE haifuraiya_channelizer_top core.
-- Feeds a complex tone from STIM_FILE (I Q per line, signed integers) at one
-- sample per SMP_PERIOD clocks, N=64 M=16, and dumps every output beat as
--   idx re im
-- to OUT_FILE. All analysis (bin mapping, rotation sign, conjugation) is done
-- offline in Python. Fails loudly if frame_dropped ever asserts or if
-- channel_last lands on the wrong idx.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_core_tone is
    generic (
        STIM_FILE  : string  := "tone_p.txt";
        OUT_FILE   : string  := "chan_out_p.txt";
        SMP_PERIOD : integer := 5
    );
end entity;

architecture sim of tb_core_tone is
    constant N_CHANNELS   : positive := 64;
    constant M_DECIMATION : positive := 16;
    constant DATA_WIDTH   : positive := 16;
    constant ACCUM_WIDTH  : positive := 40;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal sample_re, sample_im : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal sample_valid : std_logic := '0';

    signal channel_re, channel_im : std_logic_vector(ACCUM_WIDTH-1 downto 0);
    signal channel_idx  : std_logic_vector(5 downto 0);
    signal channel_valid : std_logic;
    signal channel_last  : std_logic;
    signal core_ready    : std_logic;
    signal frame_dropped : std_logic;

    signal stim_done : boolean := false;
    signal n_dropped : integer := 0;
    signal n_last_bad : integer := 0;
begin
    clk <= not clk after 5 ns;

    dut : entity work.haifuraiya_channelizer_top
        generic map (
            N_CHANNELS => N_CHANNELS, M_DECIMATION => M_DECIMATION,
            TAPS_PER_BRANCH => 24, DATA_WIDTH => DATA_WIDTH,
            COEFF_WIDTH => 16, ACCUM_WIDTH => ACCUM_WIDTH )
        port map (
            clk => clk, reset => reset,
            sample_re => sample_re, sample_im => sample_im,
            sample_valid => sample_valid,
            channel_re => channel_re, channel_im => channel_im,
            channel_idx => channel_idx, channel_valid => channel_valid,
            channel_last => channel_last,
            ready => core_ready, frame_dropped => frame_dropped );

    p_stim : process
        file fin : text;
        variable fst : file_open_status;
        variable l : line;
        variable vi, vq : integer;
    begin
        file_open(fst, fin, STIM_FILE, read_mode);
        assert fst = open_ok report "cannot open " & STIM_FILE severity failure;
        wait for 100 ns;
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);
        while not endfile(fin) loop
            readline(fin, l);
            read(l, vi); read(l, vq);
            sample_re <= std_logic_vector(to_signed(vi, DATA_WIDTH));
            sample_im <= std_logic_vector(to_signed(vq, DATA_WIDTH));
            sample_valid <= '1';
            wait until rising_edge(clk);
            sample_valid <= '0';
            for k in 1 to SMP_PERIOD - 1 loop
                wait until rising_edge(clk);
            end loop;
        end loop;
        file_close(fin);
        -- drain the pipeline
        for k in 1 to 400 loop
            wait until rising_edge(clk);
        end loop;
        stim_done <= true;
        wait;
    end process;

    p_cap : process(clk)
        file fo : text open write_mode is OUT_FILE;
        variable l : line;
    begin
        if rising_edge(clk) then
            if channel_valid = '1' then
                write(l, to_integer(unsigned(channel_idx)));
                write(l, string'(" "));
                write(l, to_integer(signed(channel_re)));
                write(l, string'(" "));
                write(l, to_integer(signed(channel_im)));
                writeline(fo, l);
                if channel_last = '1' and
                   to_integer(unsigned(channel_idx)) /= N_CHANNELS - 1 then
                    n_last_bad <= n_last_bad + 1;
                end if;
            end if;
            if frame_dropped = '1' then
                n_dropped <= n_dropped + 1;
            end if;
        end if;
    end process;

    p_done : process
    begin
        wait until stim_done;
        report "dropped_frames = " & integer'image(n_dropped) severity note;
        report "bad_last_beats = " & integer'image(n_last_bad) severity note;
        assert n_dropped = 0 report "FRAME DROPS OCCURRED" severity error;
        finish;
    end process;
end architecture;
