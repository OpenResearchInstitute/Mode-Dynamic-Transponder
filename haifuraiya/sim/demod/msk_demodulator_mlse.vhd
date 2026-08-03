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

    -- symbol lock detector (sym_lock_detector.vhd): register-backed
    -- configuration and live status, map v6 0x0A0-0x0AC.  demod_lock is
    -- driven by the detector's measurement -- windowed mean |TED| with
    -- hysteresis (C++ SymbolLockDetector contract) -- and UNCONDITIONALLY
    -- gates frame-sync hunt downstream.  No bypass exists or may be added.
    -- timing-loop coefficients + integrator status (map v6 0x0C4-0x0CC)
    tim_alpha        : in  unsigned(15 downto 0);  -- Q16, default 328 = 0.005
    tim_beta         : in  unsigned(15 downto 0);  -- Q24, default 168 = 1e-5
    sym_clk_offset   : out signed(31 downto 0);    -- Q24 samples/symbol
    -- AFC (WP2 step 2, cfo_afc.vhd): gears from CFO_CTRL, outputs to the
    -- rotator mux and the CFO status registers (map v6 0x0B0/0x0B4/0x0C0)
    afc_alpha_trk    : in  unsigned(7 downto 0);
    afc_alpha_acq    : in  unsigned(7 downto 0);
    afc_est_hz       : out signed(15 downto 0);
    afc_state        : out unsigned(2 downto 0);
    afc_quality      : out unsigned(15 downto 0);
    afc_locked       : out std_logic;
    sl_pct_lock      : in  unsigned(7 downto 0);   -- percent, default 25 (C++)
    sl_pct_unlock    : in  unsigned(7 downto 0);   -- percent, default 50 (C++)
    sl_window_log2   : in  unsigned(3 downto 0);
    sl_ratio_pct     : out unsigned(7 downto 0);   -- live 100*S|L-E|/S(L+E)
    sl_window_full   : out std_logic;
    demod_lock   : out std_logic;

    -- sticky diagnostics (cleared by init)
    ovfl_mlse    : out std_logic;
    ring_lag     : out std_logic;
    -- fine CFO tracking (reference-law transcription, cfo_fine.vhd):
    -- seeded by rx_top with the coarse word at HELD entry; output drives
    -- the rotator after HELD. y-samples stay internal to the demod.
    fine_seed_hz   : in  signed(15 downto 0);
    fine_seed_load : in  std_logic;
    fine_enable    : in  std_logic;
    fine_hz        : out signed(15 downto 0);

    -- debug taps
    dbg_pos      : out unsigned(47 downto 0);
    dbg_sym      : out unsigned(23 downto 0);
    dbg_th0      : out unsigned(15 downto 0);
    -- burst-birth camera pass-throughs (2026-08-02):
    dbg_ted      : out signed(16 downto 0);
    dbg_freq     : out signed(31 downto 0);
    dbg_trk      : out std_logic;
    dbg_eerr     : out std_logic
  );
end entity;

architecture rtl of msk_demodulator_mlse is

  -- SAMPLE STORE (2026-08-03 PM): the 64-sample LUTRAM ring is RETIRED.
  -- Samples now live in elastic_channel_store: the 64-channel BRAM
  -- geometry of the documented scale-up (SOW_demod_1_to_64_channels),
  -- instantiated here with ONE lane lit (C_CH_INDEX). 1024 samples of
  -- per-channel elasticity replace the ring's 48-sample corridor; the
  -- engine's verified same-cycle two-tap fetch is preserved -- it reads
  -- the store's filled window through the identical addressing contract
  -- the ring provided. The week of guard choreography (skip, hysteresis,
  -- release threshold, the first-flight lap-point bug) treated symptoms
  -- of an undersized buffer; this is the cure. History and the law this
  -- module enforces: see elastic_channel_store.vhd.
  constant C_CH_INDEX : unsigned(5 downto 0) := (others => '0');
    -- lane assignment within the store. Cosmetic at N=1 (rx_top feeds
    -- this wrapper ONE channel's stream); the scale-up interleave
    -- drives the channel index from the interleave tag instead.
  constant C_ST_CH_AW      : natural := 6;     -- 64 channels
  constant C_ST_DEPTH_AW   : natural := 10;    -- 1024 samples/channel
  constant C_ST_DEPTH      : natural := 2**C_ST_DEPTH_AW;
  constant C_ST_FILL_AHEAD : natural := 48;    -- window residency target
  constant C_ST_NEED       : natural := 18;    -- pos..pos+17 resident

  type st_bram_t is array (0 to 2**(C_ST_CH_AW+C_ST_DEPTH_AW)-1)
    of std_logic_vector(31 downto 0);
  signal st_bram : st_bram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of st_bram : signal is "block";
  type st_wptr_t is array (0 to 2**C_ST_CH_AW-1) of unsigned(23 downto 0);
  signal st_wr_ptr    : st_wptr_t := (others => (others => '0'));
  signal st_wr_ptr_rd : unsigned(23 downto 0);
  signal st_rdata     : std_logic_vector(31 downto 0);
  signal st_raddr     : unsigned(C_ST_CH_AW+C_ST_DEPTH_AW-1 downto 0);
  type st_win_t is array (0 to 63) of std_logic_vector(31 downto 0);
  signal st_window : st_win_t := (others => (others => '0'));
  attribute ram_style of st_window : signal is "distributed";
  signal st_fill_ptr    : unsigned(23 downto 0) := (others => '0');
  signal st_fill_pend   : std_logic := '0';
  signal st_fill_addr_q : unsigned(5 downto 0);
  signal st_fill_lead   : unsigned(23 downto 0);
  signal st_occ         : unsigned(23 downto 0);
  signal st_primed      : std_logic := '0';
  signal st_armed       : std_logic := '0';
  signal store_hold     : std_logic;
  signal st_starve      : std_logic;
  signal st_stomp       : std_logic;

  -- engine <-> ring
  signal mem_addr : unsigned(23 downto 0);
  signal mem_word : std_logic_vector(31 downto 0);
  signal mem_word2 : std_logic_vector(31 downto 0);
  signal fetch_frac : signed(16 downto 0);
  signal mem_i, mem_q : signed(15 downto 0);
  signal hold     : std_logic;

  -- engine <-> mlse
  signal e_valid  : std_logic;
  -- AFC estimator: consumes the same per-symbol y's the MLSE does
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

  signal ovfl_r, lag_r : std_logic := '0';
  signal sl_e_early : unsigned(15 downto 0);
  signal sl_e_late  : unsigned(15 downto 0);
  signal sl_e_err_v : std_logic;
  signal sl_locked  : std_logic;
  signal afc_locked_i : std_logic;

begin

  ------------------------------------------------------------------
  -- sample store (design of record; see header note above)
  ------------------------------------------------------------------
  -- ============================================================
  -- ELASTIC SAMPLE STORE (inlined 2026-08-03 PM; no new entity, no
  -- component.xml change -- the IP file list is untouched, exactly as
  -- the guarded-window and cfo fixes shipped). Logic is the 64-channel
  -- store of the documented scale-up with one lane lit; the standalone
  -- entity used for unit test lives ONLY in sim/demod/
  -- elastic_channel_store.vhd (tb_elastic_store DUT) and must be kept
  -- textually identical to these processes -- md5 both when either
  -- changes. The LAW: no unconsumed sample is ever silently
  -- overwritten; both walls are counted sticky faults.
  -- ============================================================

  ------------------------------------------------------------------
  -- store writer: real time, never stalled, per-channel region
  ------------------------------------------------------------------
  st_writer : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        st_wr_ptr <= (others => (others => '0'));
      elsif rx_enable = '1' and rx_svalid = '1' then
        st_bram(to_integer(C_CH_INDEX &
                st_wr_ptr(to_integer(C_CH_INDEX))(C_ST_DEPTH_AW-1 downto 0)))
          <= rx_q_samples & rx_i_samples;
        st_wr_ptr(to_integer(C_CH_INDEX))
          <= st_wr_ptr(to_integer(C_CH_INDEX)) + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- BRAM read port: registered (block-RAM timing)
  ------------------------------------------------------------------
  st_read : process(clk)
  begin
    if rising_edge(clk) then
      st_rdata    <= st_bram(to_integer(st_raddr));
      st_wr_ptr_rd <= st_wr_ptr(to_integer(C_CH_INDEX));
    end if;
  end process;
  st_raddr <= C_CH_INDEX & st_fill_ptr(C_ST_DEPTH_AW-1 downto 0);

  ------------------------------------------------------------------
  -- window filler: keep window[pos .. pos+C_ST_FILL_AHEAD) resident
  ------------------------------------------------------------------
  st_fill_lead <= st_fill_ptr - e_pos(39 downto 16);

  st_filler : process(clk)
    variable want : std_logic;
    variable have : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      if init = '1' then
        st_fill_ptr  <= (others => '0');
        st_fill_pend <= '0';
      else
        if (st_fill_lead(23) = '1') or
           (st_fill_lead < to_unsigned(C_ST_FILL_AHEAD, 24)) then
          want := '1';
        else
          want := '0';
        end if;
        have := st_wr_ptr_rd - st_fill_ptr;
        if st_fill_pend = '0' then
          if want = '1' and have /= 0 and have(23) = '0' then
            st_fill_addr_q <= st_fill_ptr(5 downto 0);
            st_fill_pend   <= '1';
          end if;
        else
          st_window(to_integer(st_fill_addr_q)) <= st_rdata;
          st_fill_ptr  <= st_fill_ptr + 1;
          st_fill_pend <= '0';
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- engine fetch: async LUTRAM window, the ring's exact contract
  ------------------------------------------------------------------
  mem_word  <= st_window(to_integer(mem_addr(5 downto 0)));
  mem_word2 <= st_window(to_integer(mem_addr(5 downto 0) + 1));

  ------------------------------------------------------------------
  -- priming + hold: hold until the store carries DEPTH/2 of
  -- elasticity (0.82 ms, once), then only on window starvation
  ------------------------------------------------------------------
  st_occ <= st_wr_ptr_rd - e_pos(39 downto 16);

  st_priming : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        st_primed <= '0';
      elsif st_occ(23) = '0' and
            st_occ >= to_unsigned(C_ST_DEPTH/2, 24) then
        st_primed <= '1';
      end if;
    end if;
  end process;

  store_hold <= '1' when st_primed = '0' else
                '1' when (st_fill_lead(23) = '1') or
                         (st_fill_lead < to_unsigned(C_ST_NEED, 24))
                    else '0';
  hold <= store_hold;

  ------------------------------------------------------------------
  -- store faults (sticky until init; wired into ovfl/lag below)
  ------------------------------------------------------------------
  st_faults : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        st_starve <= '0'; st_stomp <= '0'; st_armed <= '0';
      else
        if store_hold = '0' then
          st_armed <= '1';
        elsif st_armed = '1' then
          st_starve <= '1';
        end if;
        if st_occ(23) = '0' and st_occ > to_unsigned(C_ST_DEPTH, 24) then
          st_stomp <= '1';
        end if;
      end if;
    end if;
  end process;

  -- FRACTIONAL-DELAY FETCH (2026-08-01). The reference fetches every
  -- correlation sample at the TRUE fractional position:
  --     p_on = pos + i;  s_on = interp(samples, p_on)   (opv_demod.hpp)
  -- The port fetched integer ring addresses and discarded frac(pos) at
  -- the point of use -- benign at fixed offset (quantization settles,
  -- TED nulls it: every 0-ppm gold run), but under sustained clock ppm
  -- frac ramps continuously and the quantization error ramps and snaps
  -- once per accumulated symbol: the measured 0.97 s burst period at
  -- 19 ppm. This is the reference's linear interp() transcribed: a
  -- 2-tap blend weighted by the engine's live fraction. frac is stable
  -- across a symbol's window (pos updates at S_TED_C, after the MACs),
  -- matching the C++'s constant-frac-per-symbol p_on = pos + i. The
  -- +1 tap is covered by the hold guard (reader margin >= 16 samples).
  fetch_frac <= signed(resize(unsigned(e_pos(15 downto 0)), 17));
  mem_i <= signed(mem_word(15 downto 0))
           + resize(shift_right(
               (signed(mem_word2(15 downto 0))
                - signed(mem_word(15 downto 0))) * fetch_frac, 16), 16);
  mem_q <= signed(mem_word(31 downto 16))
           + resize(shift_right(
               (signed(mem_word2(31 downto 16))
                - signed(mem_word(31 downto 16))) * fetch_frac, 16), 16);


  ------------------------------------------------------------------
  -- the two verified blocks
  ------------------------------------------------------------------
  engine: entity work.msk_symbol_engine
    generic map (
      G_NSAMP    => 0                   -- CONTINUOUS: a radio has no end of
                                        -- stimulus. 16777200 here was the
                                        -- 26.84 s bench-freeze fuse (2026-07-28).
    )
    port map (
      trk_enable => sl_locked,   -- reference: set_tracking_enabled(sym_locked) -- opv_demod.hpp:1488. SYMBOL lock, not CFO lock: integrators open only when TED statistics are trustworthy
      clk => clk, rst => init, hold => hold,
      mem_addr => mem_addr, mem_i => mem_i, mem_q => mem_q,
      y_valid => e_valid,
      y1_re => e_y1r, y1_im => e_y1i, y2_re => e_y2r, y2_im => e_y2i,
      sym_index => e_sym, pos_q16 => e_pos,
      e_early => sl_e_early, e_late => sl_e_late, e_err_valid => sl_e_err_v,
      cfg_tim_alpha => tim_alpha, cfg_tim_beta => tim_beta,
      sym_clk_offset => sym_clk_offset,
      dbg_mac => open, dbg_a1r => open,
      dbg_ted => dbg_ted, dbg_freq => dbg_freq,
      dbg_trk => dbg_trk, dbg_eerr => dbg_eerr,
      done => e_done );

  mlse: entity work.msk_mlse4
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
  -- symbol lock detector: the measurement that drives demod_lock
  -- (replaces the retired G_LOCK_SYM elapsed-symbol latch)
  ------------------------------------------------------------------
  u_symlock: entity work.sym_lock_detector
    port map (
      clk           => clk,
      init          => init,
      e_valid       => sl_e_err_v,
      e_early       => sl_e_early,
      e_late        => sl_e_late,
      pct_lock      => sl_pct_lock,
      pct_unlock    => sl_pct_unlock,
      window_log2   => sl_window_log2,
      locked        => sl_locked,
      ratio_pct     => sl_ratio_pct,
      window_full   => sl_window_full );

  u_afc : entity work.cfo_afc
    port map (
      clk        => clk,
      rst        => init,
      y_valid    => e_valid,
      y1_re      => e_y1r, y1_im => e_y1i,
      y2_re      => e_y2r, y2_im => e_y2i,
      alpha_trk  => afc_alpha_trk,
      alpha_acq  => afc_alpha_acq,
      est_hz     => afc_est_hz,
      state_o    => afc_state,
      quality    => afc_quality,
      cfo_locked => afc_locked_i
    );

  -- per-symbol fine tracker: the C++ AFC law (opv_demod.hpp 388-402),
  -- consuming the same per-symbol tone correlations as the coarse AFC.
  -- 24-bit y's -> top 16 bits (the discriminator is ratio-based; scale
  -- is irrelevant, headroom is not).
  u_fine : entity work.cfo_fine
    port map (
      clk       => clk,
      rst       => init,
      y_valid   => e_valid,
      y1_re     => e_y1r(23 downto 8),
      y1_im     => e_y1i(23 downto 8),
      y2_re     => e_y2r(23 downto 8),
      y2_im     => e_y2i(23 downto 8),
      seed_hz   => fine_seed_hz,
      seed_load => fine_seed_load,
      enable    => fine_enable,
      fine_hz   => fine_hz );



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
        ovfl_r <= '0'; lag_r <= '0';
      else
        -- ovfl: engine backpressure (design invariant, never expected)
        -- OR the store's stomp fault (writer lapped unread data --
        -- the old silent-corruption case, now a counted witness).
        if (e_valid = '1' and m_busy = '1') or st_stomp = '1' then
          ovfl_r <= '1';
        end if;
        -- lag: store starvation after first release -- the reader
        -- caught the writer (dead air / TX stop mid-signal).
        if st_starve = '1' then
          lag_r <= '1';
        end if;
      end if;
    end if;
  end process;

  demod_lock <= sl_locked;
  afc_locked <= afc_locked_i;
  ovfl_mlse  <= ovfl_r;
  ring_lag   <= lag_r;
  dbg_pos    <= e_pos;
  dbg_sym    <= e_sym;
  dbg_th0    <= th0;

end architecture;
