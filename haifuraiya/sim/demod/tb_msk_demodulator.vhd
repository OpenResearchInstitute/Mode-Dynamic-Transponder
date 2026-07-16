-- tb_msk_demodulator.vhd
-- THE INTEGRATION-CONTRACT BENCH: canonical stimulus fed as a STREAM
-- (rx_svalid pulses) into msk_demodulator_mlse; soft output captured;
-- check_demod.py runs the proven model frame path and compares frames
-- byte-for-byte against cxx_frames.bin. Expected: 10/10, metrics 0
-- (polarity handled by the checker, which tries both).
--
-- Cadence: one sample per 40 clocks -- DELIBERATELY faster than the
-- real 160, so the engine outruns the writes and the HOLD/stall path
-- gets exercised thousands of times. The sticky flags must stay low.
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_msk_demodulator is
end entity;

architecture sim of tb_msk_demodulator is
  constant NSAMP : integer := 276132;
  type mem_t is array (0 to NSAMP-1) of integer;

  impure function load_col(fname : string; col : integer) return mem_t is
    file f     : text open read_mode is fname;
    variable l : line;
    variable a, b : integer;
    variable r : mem_t;
  begin
    for i in 0 to NSAMP-1 loop
      readline(f, l);
      read(l, a); read(l, b);
      if col = 0 then r(i) := a - 32768; else r(i) := b - 32768; end if;
    end loop;
    return r;
  end function;

  constant MI : mem_t := load_col("stim_chain.txt", 0);
  constant MQ : mem_t := load_col("stim_chain.txt", 1);

  signal clk : std_logic := '0';
  signal init : std_logic := '1';
  signal rx_svalid : std_logic := '0';
  signal rx_i, rx_q : std_logic_vector(15 downto 0);
  signal rx_data : std_logic;
  signal rx_data_soft : signed(15 downto 0);
  signal rx_dvalid : std_logic;
  signal demod_lock, ovfl_mlse, ring_lag : std_logic;
  signal dbg_pos : unsigned(47 downto 0);
  signal dbg_sym : unsigned(23 downto 0);
  signal dbg_th0 : unsigned(15 downto 0);
  signal nsoft : integer := 0;
begin
  clk <= not clk after 5 ns;
  init <= '0' after 100 ns;

  dut: entity work.msk_demodulator_mlse
    port map (
      clk => clk, init => init,
      rx_enable => '1', rx_svalid => rx_svalid,
      rx_i_samples => rx_i, rx_q_samples => rx_q,
      rx_data => rx_data, rx_data_soft => rx_data_soft,
      rx_dvalid => rx_dvalid,
      demod_lock => demod_lock,
      ovfl_mlse => ovfl_mlse, ring_lag => ring_lag,
      dbg_pos => dbg_pos, dbg_sym => dbg_sym, dbg_th0 => dbg_th0 );

  feed: process
  begin
    wait until init = '0';
    wait for 100 ns;
    for i in 0 to NSAMP-1 loop
      wait until rising_edge(clk);
      rx_i <= std_logic_vector(to_signed(MI(i), 16));
      rx_q <= std_logic_vector(to_signed(MQ(i), 16));
      rx_svalid <= '1';
      wait until rising_edge(clk);
      rx_svalid <= '0';
      for g in 0 to 37 loop               -- ~40 clk/sample (4x real speed)
        wait until rising_edge(clk);
      end loop;
    end loop;
    for g in 0 to 20000 loop              -- drain the pipeline
      wait until rising_edge(clk);
    end loop;
    report "STREAM DONE; soft count and flags follow" severity note;
    report "flags: ovfl=" & std_logic'image(ovfl_mlse) &
           " lag=" & std_logic'image(ring_lag) &
           " lock=" & std_logic'image(demod_lock) severity note;
    std.env.finish;
  end process;

  -- engine-trajectory audit: probe the wrapper's internal engine
  -- outputs via VHDL-2008 external names; dump (sym, pos-hi, pos-lo,
  -- Y1, Y2) per symbol for diff against golden_engine.txt
  etrace: process(clk)
    file f     : text open write_mode is "engine_trace.txt";
    variable l : line;
    alias a_ev  is << signal .tb_msk_demodulator.dut.e_valid  : std_logic >>;
    alias a_sym is << signal .tb_msk_demodulator.dut.e_sym    : unsigned(23 downto 0) >>;
    alias a_pos is << signal .tb_msk_demodulator.dut.e_pos    : unsigned(47 downto 0) >>;
    alias a_y1r is << signal .tb_msk_demodulator.dut.e_y1r    : signed(23 downto 0) >>;
    alias a_y1i is << signal .tb_msk_demodulator.dut.e_y1i    : signed(23 downto 0) >>;
    alias a_y2r is << signal .tb_msk_demodulator.dut.e_y2r    : signed(23 downto 0) >>;
    alias a_y2i is << signal .tb_msk_demodulator.dut.e_y2i    : signed(23 downto 0) >>;
    variable cnt : integer := 0;
  begin
    if rising_edge(clk) then
      if a_ev = '1' and cnt < 6000 then
        write(l, to_integer(a_sym));                  write(l, string'(" "));
        write(l, to_integer(a_pos(47 downto 24)));    write(l, string'(" "));
        write(l, to_integer(a_pos(23 downto 0)));     write(l, string'(" "));
        write(l, to_integer(a_y1r));                  write(l, string'(" "));
        write(l, to_integer(a_y1i));                  write(l, string'(" "));
        write(l, to_integer(a_y2r));                  write(l, string'(" "));
        write(l, to_integer(a_y2i));
        writeline(f, l);
        cnt := cnt + 1;
      end if;
    end if;
  end process;

  -- ring-service audit: what data did the ring serve for each address?
  rtrace: process(clk)
    file f     : text open write_mode is "ring_trace.txt";
    variable l : line;
    alias a_ma is << signal .tb_msk_demodulator.dut.mem_addr : unsigned(23 downto 0) >>;
    alias a_mi is << signal .tb_msk_demodulator.dut.mem_i    : signed(15 downto 0) >>;
    alias a_mq is << signal .tb_msk_demodulator.dut.mem_q    : signed(15 downto 0) >>;
    variable cnt  : integer := 0;
    variable prev : integer := -1;
  begin
    if rising_edge(clk) then
      if cnt < 600 and to_integer(a_ma) /= prev then
        prev := to_integer(a_ma);
        write(l, to_integer(a_ma));  write(l, string'(" "));
        write(l, to_integer(a_mi));  write(l, string'(" "));
        write(l, to_integer(a_mq));
        writeline(f, l);
        cnt := cnt + 1;
      end if;
    end if;
  end process;

  dump: process(clk)
    file f     : text open write_mode is "demod_soft.txt";
    variable l : line;
  begin
    if rising_edge(clk) then
      if rx_dvalid = '1' then
        write(l, nsoft);                  write(l, string'(" "));
        write(l, to_integer(rx_data_soft));
        writeline(f, l);
        nsoft <= nsoft + 1;
      end if;
    end if;
  end process;
end architecture;
