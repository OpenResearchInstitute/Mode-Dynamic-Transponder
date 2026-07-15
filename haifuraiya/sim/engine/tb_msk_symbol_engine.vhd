-- tb_msk_symbol_engine.vhd
-- Serves stim_engine.txt as sample memory; captures per-symbol Y outputs
-- and the position word to engine_dump.txt for integer-for-integer
-- comparison against golden_engine.txt (check_engine.py).
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_msk_symbol_engine is
end entity;

architecture sim of tb_msk_symbol_engine is
  constant NSAMP : integer := 60000;
  type mem_t is array (0 to NSAMP-1) of integer;

  impure function load_col(fname : string; col : integer) return mem_t is
    file f     : text open read_mode is fname;
    variable l : line;
    variable a, b : integer;
    variable r : mem_t;
  begin
    for i in 0 to NSAMP-1 loop
      readline(f, l);
      read(l, a);
      read(l, b);
      -- offset-encoded file: subtract 32768 (see engine README)
      if col = 0 then r(i) := a - 32768; else r(i) := b - 32768; end if;
    end loop;
    return r;
  end function;

  constant MI : mem_t := load_col("stim_engine.txt", 0);
  constant MQ : mem_t := load_col("stim_engine.txt", 1);

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal mem_addr : unsigned(23 downto 0);
  signal mem_i    : signed(15 downto 0);
  signal mem_q    : signed(15 downto 0);
  signal y_valid  : std_logic;
  signal y1_re, y1_im, y2_re, y2_im : signed(23 downto 0);
  signal sym_index : unsigned(23 downto 0);
  signal pos_q16   : unsigned(47 downto 0);
  signal dbg_mac   : std_logic;
  signal dbg_a1r   : signed(39 downto 0);
  signal done      : std_logic;
begin
  clk <= not clk after 5 ns;
  rst <= '0' after 50 ns;

  -- combinational sample memory (registered address in DUT gives the
  -- one-cycle-later data the MAC state expects: data valid same cycle
  -- as use because address settles in S_WIN_SETUP / previous MAC cycle)
  mem_i <= to_signed(MI(to_integer(mem_addr)), 16);
  mem_q <= to_signed(MQ(to_integer(mem_addr)), 16);

  dut: entity work.msk_symbol_engine
    generic map ( G_NSAMP => NSAMP )
    port map (
      clk => clk, rst => rst,
      mem_addr => mem_addr, mem_i => mem_i, mem_q => mem_q,
      y_valid => y_valid,
      y1_re => y1_re, y1_im => y1_im, y2_re => y2_re, y2_im => y2_im,
      sym_index => sym_index, pos_q16 => pos_q16,
      dbg_mac => dbg_mac, dbg_a1r => dbg_a1r, done => done );

  trace: process(clk)
    file f     : text open write_mode is "mac_trace.txt";
    variable l : line;
    variable cnt : integer := 0;
  begin
    if rising_edge(clk) then
      if dbg_mac = '1' and cnt < 200 then
        write(l, to_integer(mem_addr));           write(l, string'(" "));
        write(l, to_integer(mem_i));              write(l, string'(" "));
        write(l, to_integer(mem_q));              write(l, string'(" "));
        write(l, to_integer(dbg_a1r));
        writeline(f, l);
        cnt := cnt + 1;
      end if;
    end if;
  end process;

  dump: process(clk)
    file f     : text open write_mode is "engine_dump.txt";
    variable l : line;
  begin
    if rising_edge(clk) then
      if y_valid = '1' then
        write(l, to_integer(sym_index));       write(l, string'(" "));
        -- 48-bit position printed as two 24-bit halves: to_integer of a
        -- >31-bit unsigned wraps negative in xsim (bug #4, caught at the
        -- exact symbol where pos crossed 2^31)
        write(l, to_integer(pos_q16(47 downto 24))); write(l, string'(" "));
        write(l, to_integer(pos_q16(23 downto 0)));  write(l, string'(" "));
        write(l, to_integer(y1_re));           write(l, string'(" "));
        write(l, to_integer(y1_im));           write(l, string'(" "));
        write(l, to_integer(y2_re));           write(l, string'(" "));
        write(l, to_integer(y2_im));
        writeline(f, l);
      end if;
      if done = '1' then
        report "ENGINE DONE" severity note;
        std.env.finish;
      end if;
    end if;
  end process;
end architecture;
