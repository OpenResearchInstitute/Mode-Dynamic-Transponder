-- tb_mlse_wrapper_live.vhd -- the corpse hunt (2026-07-29).
-- Instantiates the ENTIRE msk_demodulator_mlse (ring + engine + mlse4 +
-- sym lock + AFC) and feeds pseudo-random I/Q at the real cadence
-- (1 sample per 160 clks = 625 ksps at 100 MHz). The question is binary:
-- does dbg_pos ADVANCE (engine consuming samples) or not.
--   ALIVE  : dbg_pos int part tracks samples fed (minus ring margin),
--            rx_dvalid strobes, afc_quality accumulates.
--   CORPSE : dbg_pos parks (held forever) or races (free-run on empty
--            ring) -- the QUAL=0 silicon fingerprint, reproduced where
--            we can see every wire. ASCII only. 73.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mlse_wrapper_live is
end entity;

architecture sim of tb_mlse_wrapper_live is
  signal clk    : std_logic := '0';
  signal init   : std_logic := '1';
  signal svalid : std_logic := '0';
  signal si, sq : std_logic_vector(15 downto 0) := (others => '0');
  signal dvalid : std_logic;
  signal dbit   : std_logic;
  signal dsoft  : signed(15 downto 0);
  signal qual   : unsigned(15 downto 0);
  signal astate : unsigned(2 downto 0);
  signal aest   : signed(15 downto 0);
  signal alock  : std_logic;
  signal slr    : unsigned(7 downto 0);
  signal slf    : std_logic;
  signal dlock  : std_logic;
  signal ovfl, lag : std_logic;
  signal dpos   : unsigned(47 downto 0);
  signal dsym   : unsigned(23 downto 0);
  signal dth0   : unsigned(15 downto 0);
  signal sclk   : signed(31 downto 0);
  signal nfed   : integer := 0;
  signal ndv    : integer := 0;
begin
  clk <= not clk after 5 ns;
  init <= '0' after 205 ns;

  dut : entity work.msk_demodulator_mlse
    port map (
      clk => clk, init => init,
      rx_enable => '1', rx_svalid => svalid,
      rx_i_samples => si, rx_q_samples => sq,
      rx_data => dbit, rx_data_soft => dsoft, rx_dvalid => dvalid,
      tim_alpha => to_unsigned(328, 16),
      tim_beta  => to_unsigned(168, 16),
      sym_clk_offset => sclk,
      afc_alpha_trk => to_unsigned(6, 8),
      afc_alpha_acq => to_unsigned(10, 8),
      afc_est_hz => aest, afc_state => astate,
      afc_quality => qual, afc_locked => alock,
      sl_pct_lock => to_unsigned(25, 8),
      sl_pct_unlock => to_unsigned(50, 8),
      sl_window_log2 => to_unsigned(6, 4),
      sl_ratio_pct => slr, sl_window_full => slf,
      demod_lock => dlock,
      ovfl_mlse => ovfl, ring_lag => lag,
      dbg_pos => dpos, dbg_sym => dsym, dbg_th0 => dth0 );

  -- writer: one sample per 160 clks, 32-bit LFSR noise, amp ~ +/-8k
  stim : process
    variable lfsr : unsigned(31 downto 0) := x"ACE1BEEF";  -- noise gen
    procedure step is
      variable b : std_logic;
    begin
      b := lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0);
      lfsr := lfsr(30 downto 0) & b;
    end procedure;
  begin
    wait until init = '0';
    for n in 1 to 40000 loop            -- 40k samples = 64 ms real time
      for k in 1 to 159 loop wait until rising_edge(clk); end loop;
      step; si <= std_logic_vector(resize(signed(resize(lfsr(13 downto 0),15)) - 8192, 16));
      step; sq <= std_logic_vector(resize(signed(resize(lfsr(13 downto 0),15)) - 8192, 16));
      svalid <= '1';
      wait until rising_edge(clk);
      svalid <= '0';
      nfed <= nfed + 1;
    end loop;
    wait for 10 us;
    report "FED " & integer'image(nfed) & " samples; dvalid strobes = "
           & integer'image(ndv);
    std.env.finish;
  end process;

  cnt : process(clk)
  begin
    if rising_edge(clk) and dvalid = '1' then ndv <= ndv + 1; end if;
  end process;

  -- liveness reporter: every 2000 samples' worth of time
  mon : process
  begin
    wait until init = '0';
    loop
      wait for 3200 us / 1000;  -- 3.2 us * 1000 = every 2000 clk... (see loop)
      wait for 3196800 ns;      -- = 2000 samples * 160 clks * 10 ns
      report "t: fed=" & integer'image(nfed)
           & " pos_int=" & integer'image(to_integer(dpos(39 downto 16)))
           & " dvalid=" & integer'image(ndv)
           & " qual=" & integer'image(to_integer(qual))
           & " sym=" & integer'image(to_integer(dsym))
           & " lag=" & std_logic'image(lag);
    end loop;
  end process;
end architecture;
