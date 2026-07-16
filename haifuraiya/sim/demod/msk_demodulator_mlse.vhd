-- msk_demodulator_mlse.vhd
--
-- Top-level MSK demodulator for the Haifuraiya receive chain: the
-- Phase 0 MLSE receiver (msk_symbol_engine + msk_mlse4) behind the
-- streaming interface haifuraiya_rx_top expects. Replaces the Costas
-- msk_demodulator: no NCO freq words, no loop-filter tuning forest --
-- the receiver has no Costas loops to tune.
--
-- Contract (matches u_demod's data-side usage in haifuraiya_rx_top):
--   in : rx_svalid + rx_i/q_samples, one complex sample per channel
--        beat (~625 ksps), SIXTEEN-bit (feed the full-width normalized
--        gi/gq; program the normalizer gain_target for the LEVEL_PLAN
--        rms-9000 operating point -- this replaces the old 12-bit
--        slice-as-Kd arrangement)
--   out: rx_data (hard bit), rx_data_soft signed(15:0), rx_dvalid,
--        demod_lock for frame_sync_detector_soft's demod_sync_lock.
--
-- SOFT POLARITY: fsync's convention is positive = confident '0'
-- (see its header). The MLSE convention is positive = bit '1'.
-- The shim negates (with -32768 saturation) and derives the hard bit
-- consistently: rx_data = '1' exactly when rx_data_soft < 0.
--
-- Internals: 64-deep LUTRAM ring (asynchronous read preserves the
-- engine's bench-verified same-cycle memory contract), write pointer at
-- the sample clock-enable rate, and a HOLD line that freezes the engine
-- whenever its window could outrun the writes. In the real system the
-- engine is sample-rate-bound and stalls most of the time; the bench
-- feeds fast on purpose to exercise the stall path.
--
-- Sticky status flags (cleared by init):
--   ovfl_mlse : engine emitted a symbol while mlse4 was busy
--               ("cannot happen" at real rates -- instrumented anyway)
--   ring_lag  : engine fell >48 samples behind the writes
--               (cannot happen while hold works -- instrumented anyway)
--
-- KNOWN LIMIT (bring-up scope): the engine's absolute sample index
-- wraps at 2^24 samples (~26.8 s at 625 ksps); the NCO phase jumps at
-- the wrap. Fine for burst testing; continuous operation needs
-- incremental phase tracking (scoped, not blocking).
--
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity msk_demodulator_mlse is
  generic (
    G_LUT_FILE : string := "lut16q_hex.txt";
    G_LOCK_SYM : integer := 1200        -- symbols to declared lock
  );
  port (
    clk          : in  std_logic;       -- 100 MHz fabric clock
    init         : in  std_logic;       -- synchronous reset / restart

    rx_enable    : in  std_logic;
    rx_svalid    : in  std_logic;       -- one pulse per channel sample
    rx_i_samples : in  std_logic_vector(15 downto 0);
    rx_q_samples : in  std_logic_vector(15 downto 0);

    rx_data      : out std_logic;
    rx_data_soft : out signed(15 downto 0);
    rx_dvalid    : out std_logic;

    demod_lock   : out std_logic;

    -- sticky diagnostics (cleared by init)
    ovfl_mlse    : out std_logic;
    ring_lag     : out std_logic;

    -- debug taps
    dbg_pos      : out unsigned(47 downto 0);
    dbg_sym      : out unsigned(23 downto 0);
    dbg_th0      : out unsigned(15 downto 0)
  );
end entity;

architecture rtl of msk_demodulator_mlse is

  -- 64-deep sample ring, asynchronous read (LUTRAM)
  type ring_t is array (0 to 63) of std_logic_vector(31 downto 0);
  signal ring : ring_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ring : signal is "distributed";

  signal wr_n   : unsigned(23 downto 0) := (others => '0'); -- next write idx

  -- engine <-> ring
  signal mem_addr : unsigned(23 downto 0);
  signal mem_word : std_logic_vector(31 downto 0);
  signal mem_i, mem_q : signed(15 downto 0);
  signal hold     : std_logic;

  -- engine <-> mlse
  signal e_valid  : std_logic;
  signal e_y1r, e_y1i, e_y2r, e_y2i : signed(23 downto 0);
  signal e_sym    : unsigned(23 downto 0);
  signal e_pos    : unsigned(47 downto 0);
  signal e_done   : std_logic;

  signal m_busy   : std_logic;
  signal soft_valid : std_logic;
  signal soft_idx   : unsigned(23 downto 0);
  signal soft_out   : signed(15 downto 0);
  signal th0, th1, th2, th3 : unsigned(15 downto 0);
  signal dbg_best   : unsigned(1 downto 0);

  signal lock_r, ovfl_r, lag_r : std_logic := '0';

begin

  ------------------------------------------------------------------
  -- sample ring
  ------------------------------------------------------------------
  wr: process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        wr_n <= (others => '0');
      elsif rx_enable = '1' and rx_svalid = '1' then
        ring(to_integer(wr_n(5 downto 0))) <= rx_q_samples & rx_i_samples;
        wr_n <= wr_n + 1;
      end if;
    end if;
  end process;

  mem_word <= ring(to_integer(mem_addr(5 downto 0)));
  mem_i    <= signed(mem_word(15 downto 0));
  mem_q    <= signed(mem_word(31 downto 16));

  -- stall the engine while any sample its current symbol could touch
  -- (up to pos+wlen+EL+2 <= pos+16) has not yet been written
  hold <= '1' when resize(e_pos(39 downto 16), 24) + 16 > wr_n else '0';

  ------------------------------------------------------------------
  -- the two verified blocks
  ------------------------------------------------------------------
  engine: entity work.msk_symbol_engine
    generic map (
      G_LUT_FILE => G_LUT_FILE,
      G_NSAMP    => 16777200            -- effectively unbounded (see wrap note)
    )
    port map (
      clk => clk, rst => init, hold => hold,
      mem_addr => mem_addr, mem_i => mem_i, mem_q => mem_q,
      y_valid => e_valid,
      y1_re => e_y1r, y1_im => e_y1i, y2_re => e_y2r, y2_im => e_y2i,
      sym_index => e_sym, pos_q16 => e_pos,
      dbg_mac => open, dbg_a1r => open,
      done => e_done );

  mlse: entity work.msk_mlse4
    generic map ( G_LUT_FILE => G_LUT_FILE )
    port map (
      clk => clk, rst => init,
      y_valid => e_valid,
      y1_re => e_y1r, y1_im => e_y1i, y2_re => e_y2r, y2_im => e_y2i,
      busy => m_busy,
      soft_valid => soft_valid, soft_idx => soft_idx, soft_out => soft_out,
      dbg_best => dbg_best,
      dbg_th0 => th0, dbg_th1 => th1, dbg_th2 => th2, dbg_th3 => th3,
      dbg_step_valid => open,
      dbg_m0 => open, dbg_m1 => open, dbg_m2 => open, dbg_m3 => open );

  ------------------------------------------------------------------
  -- output shim: polarity, hard bit, valid
  ------------------------------------------------------------------
  shim: process(clk)
  begin
    if rising_edge(clk) then
      rx_dvalid <= soft_valid;
      if soft_valid = '1' then
        -- negate with saturation: MLSE positive-is-1 -> fsync
        -- positive-is-0
        if soft_out = to_signed(-32768, 16) then
          rx_data_soft <= to_signed(32767, 16);
        else
          rx_data_soft <= -soft_out;
        end if;
        if soft_out > 0 then
          rx_data <= '1';
        else
          rx_data <= '0';
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- lock + sticky diagnostics
  ------------------------------------------------------------------
  status: process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        lock_r <= '0'; ovfl_r <= '0'; lag_r <= '0';
      else
        if to_integer(e_sym) > G_LOCK_SYM then
          lock_r <= '1';
        end if;
        if e_valid = '1' and m_busy = '1' then
          ovfl_r <= '1';
        end if;
        if wr_n - resize(e_pos(39 downto 16), 24) > 48 then
          lag_r <= '1';
        end if;
      end if;
    end if;
  end process;

  demod_lock <= lock_r;
  ovfl_mlse  <= ovfl_r;
  ring_lag   <= lag_r;
  dbg_pos    <= e_pos;
  dbg_sym    <= e_sym;
  dbg_th0    <= th0;

end architecture;
