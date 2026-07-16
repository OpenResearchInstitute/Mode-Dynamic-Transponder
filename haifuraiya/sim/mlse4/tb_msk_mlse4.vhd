-- tb_msk_mlse4.vhd
-- Feeds the VERIFIED symbol-engine Y stream (golden_engine.txt) into
-- msk_mlse4 one symbol per interval; captures soft decisions and theta
-- debug taps to mlse_dump.txt for integer-for-integer comparison against
-- mlse_golden.txt (check_mlse.py). ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_msk_mlse4 is
end entity;

architecture sim of tb_msk_mlse4 is
  constant NSYM : integer := 5202;
  type arr_t is array (0 to NSYM-1) of integer;

  impure function load_col(fname : string; col : integer) return arr_t is
    file f     : text open read_mode is fname;
    variable l : line;
    variable v : integer;
    variable r : arr_t;
  begin
    for i in 0 to NSYM-1 loop
      readline(f, l);
      for j in 0 to 3 loop
        read(l, v);
        -- offset-encoded (value + 8388608): no negatives, all < 2^25
        if j = col then r(i) := v - 8388608; end if;
      end loop;
    end loop;
    return r;
  end function;

  -- y_stream columns (offset-encoded): y1r y1i y2r y2i
  constant Y1R : arr_t := load_col("y_stream.txt", 0);
  constant Y1I : arr_t := load_col("y_stream.txt", 1);
  constant Y2R : arr_t := load_col("y_stream.txt", 2);
  constant Y2I : arr_t := load_col("y_stream.txt", 3);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal y_valid : std_logic := '0';
  signal y1_re, y1_im, y2_re, y2_im : signed(23 downto 0);
  signal soft_valid : std_logic;
  signal soft_idx   : unsigned(23 downto 0);
  signal soft_out   : signed(15 downto 0);
  signal dbg_best   : unsigned(1 downto 0);
  signal dbg_th0, dbg_th1, dbg_th2, dbg_th3 : unsigned(15 downto 0);
  signal dut_step_valid : std_logic;
  signal dut_m0, dut_m1, dut_m2, dut_m3 : signed(23 downto 0);
begin
  clk <= not clk after 5 ns;
  rst <= '0' after 50 ns;

  dut: entity work.msk_mlse4
    port map (
      clk => clk, rst => rst,
      y_valid => y_valid,
      y1_re => y1_re, y1_im => y1_im, y2_re => y2_re, y2_im => y2_im,
      busy => open,
      soft_valid => soft_valid, soft_idx => soft_idx, soft_out => soft_out,
      dbg_best => dbg_best,
      dbg_th0 => dbg_th0, dbg_th1 => dbg_th1,
      dbg_th2 => dbg_th2, dbg_th3 => dbg_th3,
      dbg_step_valid => dut_step_valid,
      dbg_m0 => dut_m0, dbg_m1 => dut_m1,
      dbg_m2 => dut_m2, dbg_m3 => dut_m3 );

  feed: process
  begin
    wait until rst = '0';
    wait for 100 ns;
    for i in 0 to NSYM-1 loop
      wait until rising_edge(clk);
      y1_re <= to_signed(Y1R(i), 24);
      y1_im <= to_signed(Y1I(i), 24);
      y2_re <= to_signed(Y2R(i), 24);
      y2_im <= to_signed(Y2I(i), 24);
      y_valid <= '1';
      wait until rising_edge(clk);
      y_valid <= '0';
      -- generous gap: ACS(4) + NORM + TB(65) + EMIT ~ 75 clocks
      for g in 0 to 90 loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    for g in 0 to 300 loop
      wait until rising_edge(clk);
    end loop;
    report "MLSE FEED DONE" severity note;
    std.env.finish;
  end process;

  -- per-step state trace: post-norm metrics + thetas after each step
  strace: process(clk)
    file f     : text open write_mode is "step_trace.txt";
    variable l : line;
    variable cnt : integer := 0;
  begin
    if rising_edge(clk) then
      if dut_step_valid = '1' and cnt < 100 then
        write(l, cnt);                       write(l, string'(" "));
        write(l, to_integer(dut_m0));        write(l, string'(" "));
        write(l, to_integer(dut_m1));        write(l, string'(" "));
        write(l, to_integer(dut_m2));        write(l, string'(" "));
        write(l, to_integer(dut_m3));        write(l, string'(" "));
        write(l, to_integer(dbg_th0));       write(l, string'(" "));
        write(l, to_integer(dbg_th1));       write(l, string'(" "));
        write(l, to_integer(dbg_th2));       write(l, string'(" "));
        write(l, to_integer(dbg_th3));
        writeline(f, l);
        cnt := cnt + 1;
      end if;
    end if;
  end process;

  dump: process(clk)
    file f     : text open write_mode is "mlse_dump.txt";
    variable l : line;
  begin
    if rising_edge(clk) then
      if soft_valid = '1' then
        write(l, to_integer(soft_idx));  write(l, string'(" "));
        write(l, to_integer(soft_out));  write(l, string'(" "));
        write(l, to_integer(dbg_best));  write(l, string'(" "));
        write(l, to_integer(dbg_th0));   write(l, string'(" "));
        write(l, to_integer(dbg_th1));   write(l, string'(" "));
        write(l, to_integer(dbg_th2));   write(l, string'(" "));
        write(l, to_integer(dbg_th3));
        writeline(f, l);
      end if;
    end if;
  end process;
end architecture;
