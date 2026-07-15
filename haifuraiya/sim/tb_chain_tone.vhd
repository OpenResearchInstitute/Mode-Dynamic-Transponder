-- tb_chain_tone.vhd
-- 20 Msps chain bench: halfband_decimator -> haifuraiya_channelizer_top.
-- Same stimulus/capture format as tb_core_tone; input is at 20 Msps.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_chain_tone is
    generic (
        STIM_FILE  : string  := "tone20_p.txt";
        OUT_FILE   : string  := "chain_out_p.txt";
        SMP_PERIOD : integer := 5
    );
end entity;

architecture sim of tb_chain_tone is
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';
    signal in_i, in_q : signed(15 downto 0) := (others => '0');
    signal in_valid   : std_logic := '0';
    signal dec_i, dec_q : signed(15 downto 0);
    signal dec_valid    : std_logic;
    signal channel_re, channel_im : std_logic_vector(39 downto 0);
    signal channel_idx  : std_logic_vector(5 downto 0);
    signal channel_valid, channel_last : std_logic;
    signal core_ready, frame_dropped : std_logic;
    signal stim_done : boolean := false;
    signal n_dropped : integer := 0;
begin
    clk <= not clk after 5 ns;

    u_hb : entity work.halfband_decimator
        port map (clk => clk, rst => reset,
                  in_valid => in_valid, in_i => in_i, in_q => in_q,
                  out_valid => dec_valid, out_i => dec_i, out_q => dec_q);

    u_ch : entity work.haifuraiya_channelizer_top
        generic map (N_CHANNELS => 64, M_DECIMATION => 16,
                     TAPS_PER_BRANCH => 24, DATA_WIDTH => 16,
                     COEFF_WIDTH => 16, ACCUM_WIDTH => 40)
        port map (clk => clk, reset => reset,
                  sample_re => std_logic_vector(dec_i),
                  sample_im => std_logic_vector(dec_q),
                  sample_valid => dec_valid,
                  channel_re => channel_re, channel_im => channel_im,
                  channel_idx => channel_idx, channel_valid => channel_valid,
                  channel_last => channel_last,
                  ready => core_ready, frame_dropped => frame_dropped);

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
            in_i <= to_signed(vi, 16);
            in_q <= to_signed(vq, 16);
            in_valid <= '1';
            wait until rising_edge(clk);
            in_valid <= '0';
            for k in 1 to SMP_PERIOD - 1 loop
                wait until rising_edge(clk);
            end loop;
        end loop;
        file_close(fin);
        for k in 1 to 800 loop wait until rising_edge(clk); end loop;
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
            end if;
            if frame_dropped = '1' then n_dropped <= n_dropped + 1; end if;
        end if;
    end process;

    p_done : process
    begin
        wait until stim_done;
        report "dropped_frames = " & integer'image(n_dropped) severity note;
        finish;
    end process;
end architecture;
