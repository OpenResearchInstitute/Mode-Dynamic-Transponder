-- tb_chain.vhd
--
-- INTEGRATION BENCH: the complete new-receiver signal path in RTL.
--   canonical chan5 stimulus (C++ opv-mod through the verified
--   channelizer, 276132 samples)
--     -> msk_symbol_engine (verified bit-exact, sim/engine)
--     -> msk_mlse4         (verified bit-exact, sim/mlse4)
--     -> chain_soft.txt
-- check_chain.py then runs the repo's proven model frame path
-- (extract_frames + K=7 decode) on the fabric soft stream and compares
-- the decoded frames byte-for-byte against cxx_frames.bin.
--
-- Pre-flight (python, identical integer arithmetic): 10/10 frames
-- byte-identical, ALL DECODE METRICS ZERO. That is the expected result.
--
-- Two-phase structure: the bench memory serves samples instantly, which
-- makes the engine unrealistically fast (~40 clk/sym) versus mlse4's
-- ~75 clk/sym. In the real fabric the engine is sample-rate-bound
-- (~1840 clk/sym at 100 MHz), so no FIFO is needed there; here we run
-- the engine to completion first, capture its Y stream, then feed mlse4
-- at its own pace. Same RTL, same chained data, no rate artifact.
--
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_chain is
end entity;

architecture sim of tb_chain is
  constant NSAMP  : integer := 276132;
  constant MAXSYM : integer := 24500;

  type mem_t  is array (0 to NSAMP-1)  of integer;
  type ysto_t is array (0 to MAXSYM-1) of integer;

  impure function load_col(fname : string; col : integer) return mem_t is
    file f     : text open read_mode is fname;
    variable l : line;
    variable a, b : integer;
    variable r : mem_t;
  begin
    for i in 0 to NSAMP-1 loop
      readline(f, l);
      read(l, a); read(l, b);
      -- offset-encoded (+32768): textio-immune
      if col = 0 then r(i) := a - 32768; else r(i) := b - 32768; end if;
    end loop;
    return r;
  end function;

  constant MI : mem_t := load_col("stim_chain.txt", 0);
  constant MQ : mem_t := load_col("stim_chain.txt", 1);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- engine
  signal mem_addr : unsigned(23 downto 0);
  signal mem_i, mem_q : signed(15 downto 0);
  signal e_valid  : std_logic;
  signal e_y1r, e_y1i, e_y2r, e_y2i : signed(23 downto 0);
  signal e_symidx : unsigned(23 downto 0);
  signal e_pos    : unsigned(47 downto 0);
  signal e_done   : std_logic;

  -- captured Y stream (phase 1 -> phase 2)
  signal y1r_s, y1i_s, y2r_s, y2i_s : ysto_t;
  signal ncap : integer := 0;

  -- mlse4
  signal m_valid : std_logic := '0';
  signal m_y1r, m_y1i, m_y2r, m_y2i : signed(23 downto 0);
  signal soft_valid : std_logic;
  signal soft_idx   : unsigned(23 downto 0);
  signal soft_out   : signed(15 downto 0);
  signal dbg_best   : unsigned(1 downto 0);
  signal th0, th1, th2, th3 : unsigned(15 downto 0);

begin
  clk <= not clk after 5 ns;
  rst <= '0' after 50 ns;

  mem_i <= to_signed(MI(to_integer(mem_addr)), 16);
  mem_q <= to_signed(MQ(to_integer(mem_addr)), 16);

  engine: entity work.msk_symbol_engine
    generic map ( G_NSAMP => NSAMP )
    port map (
      clk => clk, rst => rst,
      mem_addr => mem_addr, mem_i => mem_i, mem_q => mem_q,
      y_valid => e_valid,
      y1_re => e_y1r, y1_im => e_y1i, y2_re => e_y2r, y2_im => e_y2i,
      sym_index => e_symidx, pos_q16 => e_pos,
      dbg_mac => open, dbg_a1r => open,
      done => e_done );

  mlse: entity work.msk_mlse4
    port map (
      clk => clk, rst => rst,
      y_valid => m_valid,
      y1_re => m_y1r, y1_im => m_y1i, y2_re => m_y2r, y2_im => m_y2i,
      busy => open,
      soft_valid => soft_valid, soft_idx => soft_idx, soft_out => soft_out,
      dbg_best => dbg_best,
      dbg_th0 => th0, dbg_th1 => th1, dbg_th2 => th2, dbg_th3 => th3,
      dbg_step_valid => open,
      dbg_m0 => open, dbg_m1 => open, dbg_m2 => open, dbg_m3 => open );

  -- phase 1: capture the engine's Y stream
  cap: process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' and e_valid = '1' and ncap < MAXSYM then
        y1r_s(ncap) <= to_integer(e_y1r);
        y1i_s(ncap) <= to_integer(e_y1i);
        y2r_s(ncap) <= to_integer(e_y2r);
        y2i_s(ncap) <= to_integer(e_y2i);
        ncap <= ncap + 1;
      end if;
    end if;
  end process;

  -- phase 2: feed mlse4 at its own pace after the engine finishes
  feed: process
  begin
    wait until rst = '0';
    wait until e_done = '1';
    wait for 200 ns;
    report "PHASE 2: feeding mlse4" severity note;
    for i in 0 to MAXSYM-1 loop
      exit when i >= ncap;
      wait until rising_edge(clk);
      m_y1r <= to_signed(y1r_s(i), 24);
      m_y1i <= to_signed(y1i_s(i), 24);
      m_y2r <= to_signed(y2r_s(i), 24);
      m_y2i <= to_signed(y2i_s(i), 24);
      m_valid <= '1';
      wait until rising_edge(clk);
      m_valid <= '0';
      for g in 0 to 88 loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    for g in 0 to 300 loop
      wait until rising_edge(clk);
    end loop;
    report "CHAIN DONE" severity note;
    std.env.finish;
  end process;

  dump: process(clk)
    file f     : text open write_mode is "chain_soft.txt";
    variable l : line;
  begin
    if rising_edge(clk) then
      if soft_valid = '1' then
        write(l, to_integer(soft_idx)); write(l, string'(" "));
        write(l, to_integer(soft_out));
        writeline(f, l);
      end if;
    end if;
  end process;
end architecture;
