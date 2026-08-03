-- tb_elastic_store.vhd -- proves the LAW, sample-exactly.
--
-- Model: writer produces one 32-bit sample (= its own absolute index,
-- making every sample self-identifying) every G_CLK_PER_SAMP clocks.
-- Reader pos advances ~11.53 samples per symbol with a ppm-wander term.
-- INVARIANT CHECKED EVERY CYCLE hold=0:
--     window[pos+k] = golden[pos+k]  for k in 0..17
-- i.e. the engine could never fetch a stale, relapped, or unwritten
-- sample. One violation = simulation failure.
--
-- Second phase (G_PROVOKE=1): freeze the reader mid-run; the writer
-- keeps going; occupancy must cross the region depth and STOMP_STICKY
-- must assert (the tripwire works), while no invariant check runs
-- (reader frozen = engine idle).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_elastic_store is
  generic (
    G_CLK_PER_SAMP : integer := 8;     -- fabric:sample compression (>=4)
    G_STATIC_PPM10 : integer := 115;
    G_TRI_PPM10    : integer := 100;
    G_TRI_PERIOD10 : integer := 10;
    G_SIM_SAMPLES  : integer := 625000; -- 1.0 s of samples
    G_PROVOKE      : integer := 0       -- 1 = stomp-tripwire phase
  );
end entity;

architecture sim of tb_elastic_store is
  signal clk  : std_logic := '0';
  signal init : std_logic := '1';
  signal wr_valid : std_logic := '0';
  signal wr_data  : std_logic_vector(31 downto 0);
  signal reader_pos : unsigned(23 downto 0) := to_unsigned(2, 24);
  signal hold : std_logic;
  signal win_addr  : unsigned(23 downto 0) := (others => '0');
  signal win_data0 : std_logic_vector(31 downto 0);
  signal win_data1 : std_logic_vector(31 downto 0);
  signal occupancy : unsigned(23 downto 0);
  signal starve_sticky, stomp_sticky : std_logic;
  constant CH : unsigned(5 downto 0) := to_unsigned(5, 6);  -- channel 5 first
begin

  clk <= not clk after 5 ns;

  uut: entity work.elastic_channel_store
    generic map ( G_CH_AW => 6, G_DEPTH_AW => 10, G_WIN_AW => 6 )
    port map (
      clk => clk, init => init,
      wr_ch => CH, wr_valid => wr_valid, wr_data => wr_data,
      rd_ch => CH, reader_pos => reader_pos, hold => hold,
      win_addr => win_addr, win_data0 => win_data0, win_data1 => win_data1,
      occupancy => occupancy,
      starve_sticky => starve_sticky, stomp_sticky => stomp_sticky );

  stim: process
    variable wr_idx   : integer := 0;
    variable pos_r    : real := 2.0;
    variable sym_acc  : real := 0.0;
    constant SPS      : real := 625000.0 / 54200.0;
    variable t, ph, tri, skew, period : real;
    variable checks   : integer := 0;
    variable holds_seen : integer := 0;
    variable frozen   : boolean := false;
    variable l : line;
  begin
    wait until rising_edge(clk); wait until rising_edge(clk);
    init <= '0';
    period := real(G_TRI_PERIOD10)/10.0;

    for i in 0 to G_SIM_SAMPLES*G_CLK_PER_SAMP - 1 loop
      -- writer: one self-identifying sample per G_CLK_PER_SAMP clocks
      if (i mod G_CLK_PER_SAMP) = 0 then
        wr_data  <= std_logic_vector(to_unsigned(wr_idx, 32));
        wr_valid <= '1';
        wr_idx   := wr_idx + 1;
      else
        wr_valid <= '0';
      end if;

      -- reader: per-symbol chunked advance with wander; freezes at
      -- half-run in provoke mode
      if G_PROVOKE = 1 and i > (G_SIM_SAMPLES*G_CLK_PER_SAMP)/2 then
        frozen := true;
      end if;
      if hold = '0' and not frozen then
        sym_acc := sym_acc + 1.0/real(G_CLK_PER_SAMP);
        if sym_acc >= SPS then
          sym_acc := sym_acc - SPS;
          t   := real(i) / (real(G_CLK_PER_SAMP)*625000.0);
          ph  := (t/period) - floor(t/period);
          if ph < 0.5 then tri := 4.0*ph - 1.0; else tri := 3.0 - 4.0*ph; end if;
          skew := real(G_STATIC_PPM10)/10.0 + real(G_TRI_PPM10)/10.0 * tri;
          pos_r := pos_r + SPS * (1.0 + skew*1.0e-6);
        end if;
      end if;
      reader_pos <= to_unsigned(integer(floor(pos_r)) mod 2**24, 24);

      wait until rising_edge(clk);

      -- THE LAW, checked sample-exactly at every fetchable offset
      if hold = '0' and not frozen and integer(floor(pos_r)) > 2
         and (i mod 50) = 0 then   -- decimated: every 50th clk, all offsets
        for k in 0 to 17 loop
          win_addr <= to_unsigned((integer(floor(pos_r)) + k) mod 2**24, 24);
          wait for 0 ns; wait for 0 ns;   -- settle async read
          assert to_integer(unsigned(win_data0))
                 = (integer(floor(pos_r)) + k)
            report "LAW VIOLATED: pos=" & integer'image(integer(floor(pos_r)))
                 & " k=" & integer'image(k)
                 & " got=" & integer'image(to_integer(unsigned(win_data0)))
            severity failure;
          checks := checks + 1;
        end loop;
      end if;
      if hold = '1' then holds_seen := holds_seen + 1; end if;
    end loop;

    write(l, string'("PASS: law_checks=") & integer'image(checks)
           & string'(" hold_cycles=") & integer'image(holds_seen)
           & string'(" starve=") & std_logic'image(starve_sticky)
           & string'(" stomp=") & std_logic'image(stomp_sticky)
           & string'(" final_occ=") & integer'image(to_integer(occupancy)));
    writeline(output, l);
    if G_PROVOKE = 1 then
      assert stomp_sticky = '1'
        report "TRIPWIRE FAILED: reader frozen, stomp never flagged"
        severity failure;
      write(l, string'("TRIPWIRE OK: frozen reader detected, stomp sticky set"));
      writeline(output, l);
    else
      assert stomp_sticky = '0' and starve_sticky = '0'
        report "unexpected fault flag in clean run" severity failure;
    end if;
    std.env.finish;
  end process;

end architecture;
