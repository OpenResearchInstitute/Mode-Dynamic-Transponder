library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all; use std.env.all;

entity frame_sync_tb is end entity;
architecture sim of frame_sync_tb is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal rx_bit : std_logic := '0';
  signal rx_bit_valid : std_logic := '0';
  signal soft_in : signed(15 downto 0) := (others=>'0');
  signal sb_tdata : std_logic_vector(2 downto 0);
  signal sb_tvalid, sb_tlast : std_logic;
  signal locked : std_logic;
  signal frames_received, frame_errs, dbg_bitcnt : std_logic_vector(31 downto 0);
  signal ovf : std_logic;
  signal demod_lock : std_logic := '0';
  signal done : boolean := false;
begin
  clk <= not clk after 5 ns;
  dut: entity work.frame_sync_detector_soft
    port map(
      clk=>clk, reset=>reset, rx_bit=>rx_bit, rx_bit_valid=>rx_bit_valid,
      s_axis_soft_tdata=>soft_in,
      m_axis_tdata=>open, m_axis_tvalid=>open, m_axis_tready=>'1', m_axis_tlast=>open,
      m_axis_soft_bit_tdata=>sb_tdata, m_axis_soft_bit_tvalid=>sb_tvalid,
      m_axis_soft_bit_tready=>'1', m_axis_soft_bit_tlast=>sb_tlast,
      frame_sync_locked=>locked, frames_received=>frames_received,
      frame_sync_errors=>frame_errs, frame_buffer_overflow=>ovf,
      demod_sync_lock=>demod_lock,
      debug_state=>open, debug_correlation=>open, debug_corr_peak=>open,
      debug_bit_count=>dbg_bitcnt, debug_missed_syncs=>open, debug_consecutive_good=>open,
      debug_soft_current=>open, debug_soft_quantized=>open, debug_byte_v=>open);

  stim: process
    file f : text open read_mode is "/tmp/seam_soft.txt";
    variable l : line; variable v : integer;
  begin
    reset<='1'; demod_lock<='0'; rx_bit_valid<='0';
    wait for 53 ns; wait until rising_edge(clk);
    reset<='0'; demod_lock<='1'; wait until rising_edge(clk);
    while not endfile(f) loop
      readline(f,l); read(l,v);
      soft_in <= to_signed(v,16);
      if v<0 then rx_bit<='1'; else rx_bit<='0'; end if;
      rx_bit_valid<='1';
      wait until rising_edge(clk);
      rx_bit_valid<='0';
      -- realistic symbol spacing: emission (1/clk) drains the single soft_frame_buf
      -- well before the next frame's payload starts writing (~24 symbol gap in HW)
      for g in 1 to 119 loop wait until rising_edge(clk); end loop;
    end loop;
    rx_bit_valid<='0';
    for i in 0 to 300 loop wait until rising_edge(clk); end loop;
    report "DONE frames_received="&integer'image(to_integer(unsigned(frames_received)))
         &" locked="&std_logic'image(locked);
    done<=true; wait;
  end process;

  cap: process(clk)
    file g : text open write_mode is "/tmp/seam_out.txt";
    variable l : line;
    variable buf : integer_vector(0 to 2143);
    variable idx : natural := 0;
    variable nframes : natural := 0;
    variable closed : boolean := false;
  begin
    if rising_edge(clk) then
      if sb_tvalid='1' and not closed then
        if idx <= 2143 then buf(idx) := to_integer(unsigned(sb_tdata)); end if;
        if sb_tlast='1' then
          if idx = 2143 then
            for k in 0 to 2143 loop write(l, buf(k)); writeline(g,l); end loop;
            nframes := nframes + 1;
          end if;
          idx := 0;
        else
          idx := idx + 1;
        end if;
      end if;
      if done and not closed then
        report "CAP complete frames="&integer'image(nframes);
        file_close(g); closed := true;
      end if;
    end if;
  end process;

  fin: process begin wait until done; wait for 50 ns; stop; end process;
end architecture;
