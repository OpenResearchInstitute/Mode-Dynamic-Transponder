-- tb_chain_opv.vhd
-- OPV decode-oracle bench: halfband_decimator -> haifuraiya_channelizer_top
-- at 20 Msps, capturing ONLY raw FFT bin 59 (relabeled channel 5) as
-- "I Q" text -- the chan_iq dump that feeds convert_chan_iq.py and
-- opv-demod -c -R 625000. Same structure as tb_chain_tone; the capture
-- filter and the longer runtime are the only differences.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_chain_opv is
    generic (
        STIM_FILE  : string  := "opv20_stim.txt";
        OUT_FILE   : string  := "chan5_iq.txt";
        SMP_PERIOD : integer := 5;
        CAPTURE_BIN : integer := 59      -- raw FFT bin (channel 5 relabeled)
    );
end entity;

architecture sim of tb_chain_opv is
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
    signal n_dropped, n_cap : integer := 0;
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
        for k in 1 to 2000 loop wait until rising_edge(clk); end loop;
        stim_done <= true;
        wait;
    end process;

    p_cap : process(clk)
        file fo : text open write_mode is OUT_FILE;
        variable l : line;
    begin
        if rising_edge(clk) then
            if channel_valid = '1' and
               to_integer(unsigned(channel_idx)) = CAPTURE_BIN then
                write(l, to_integer(signed(channel_re)));
                write(l, string'(" "));
                write(l, to_integer(signed(channel_im)));
                writeline(fo, l);
                n_cap <= n_cap + 1;
            end if;
            if frame_dropped = '1' then n_dropped <= n_dropped + 1; end if;
        end if;
    end process;

    p_done : process
    begin
        wait until stim_done;
        report "dropped_frames    = " & integer'image(n_dropped) severity note;
        report "channel-5 samples = " & integer'image(n_cap) severity note;
        assert n_dropped = 0 report "FRAME DROPS OCCURRED" severity error;
        finish;
    end process;
end architecture;
