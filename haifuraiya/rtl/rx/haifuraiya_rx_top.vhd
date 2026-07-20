--------------------------------------------------------------------------------
-- haifuraiya_rx_top : single-channel RX bring-up scaffold
--
-- Chain:  haifuraiya_channelizer_axi  (m_axis_chans, complex I/Q per channel, TDEST)
--           -> TDEST demux (pick ONE channel = TARGET_CHANNEL, forward its I)
--           -> msk_demodulator  (complex)
--           -> frame_sync_detector_soft
--           -> m_axis_soft_bit  (3-bit soft, 2144/frame, sync stripped)  -> DMA -> opv-decode -3
--
-- This is a BRING-UP scaffold: prove ONE channel locks + decodes before fanning
-- out to all 64. The 64x fanout is a deliberate next step (see note at bottom) --
-- it is where the LUT cost and the parallel-vs-time-shared decision live.
--
-- SET BEFORE BUILD:
--   * TARGET_CHANNEL  : which channelizer channel to bring up first
--   * the demod tuning ports (freq words / gains / shifts / lock thresholds):
--       re-derive for the channel rate (~625 ksps, SPS ~11.53) -- see
--       CHANNELIZER_DEMOD_CONTRACT.md. This is the knob most likely to bite.
--   * KEY TO LOCK: the demod is now complex input.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_rx_top is
    generic (
        TARGET_CHANNEL : natural := 5;     -- 0..63: channel to bring up first
        COMPLEX_INPUT  : boolean := true; -- false = real I-only (today); true = feed channel Q
        --RX_INVERT      : std_logic := '0'; -- bit polarity (matches msk_top rx_invert)

        -- channelizer dims (pass through)
        N_CHANNELS     : positive := 64;
        M_DECIMATION   : positive := 16;
        C_S_AXI_CTRL_ADDR_WIDTH : positive := 12
    );
    port (
        aclk     : in  std_logic;
        aresetn  : in  std_logic;

        -- ADC complex I/Q in -> channelizer  (TDATA[31:16]=Q, [15:0]=I)
        s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid : in  std_logic;
        s_axis_data_tready : out std_logic;

        -- soft-bit out (target channel) -> AXIS FIFO/DMA -> opv-decode -3
        m_axis_soft_bit_tdata  : out std_logic_vector(2 downto 0);
        m_axis_soft_bit_tvalid : out std_logic;
        m_axis_soft_bit_tready : in  std_logic;
        m_axis_soft_bit_tlast  : out std_logic;

        -- channelizer AXI-Lite control (pass through to PS)
        s_axi_ctrl_awaddr  : in  std_logic_vector(C_S_AXI_CTRL_ADDR_WIDTH-1 downto 0);
        s_axi_ctrl_awvalid : in  std_logic;
        s_axi_ctrl_awready : out std_logic;
        s_axi_ctrl_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_ctrl_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_ctrl_wvalid  : in  std_logic;
        s_axi_ctrl_wready  : out std_logic;
        s_axi_ctrl_bresp   : out std_logic_vector(1 downto 0);
        s_axi_ctrl_bvalid  : out std_logic;
        s_axi_ctrl_bready  : in  std_logic;
        s_axi_ctrl_araddr  : in  std_logic_vector(C_S_AXI_CTRL_ADDR_WIDTH-1 downto 0);
        s_axi_ctrl_arvalid : in  std_logic;
        s_axi_ctrl_arready : out std_logic;
        s_axi_ctrl_rdata   : out std_logic_vector(31 downto 0);
        s_axi_ctrl_rresp   : out std_logic_vector(1 downto 0);
        s_axi_ctrl_rvalid  : out std_logic;
        s_axi_ctrl_rready  : in  std_logic;

        -- demod tuning (drive from PS registers; re-derive for the channel rate)
        rx_freq_word_f1       : in  std_logic_vector(31 downto 0);
        rx_freq_word_f2       : in  std_logic_vector(31 downto 0);
        lpf_p_gain            : in  std_logic_vector(23 downto 0);
        lpf_i_gain            : in  std_logic_vector(23 downto 0);
        lpf_alpha             : in  std_logic_vector(23 downto 0);
        lpf_p_shift           : in  std_logic_vector(7 downto 0);
        lpf_i_shift           : in  std_logic_vector(7 downto 0);
        symbol_lock_count     : in  std_logic_vector(9 downto 0);
        symbol_lock_threshold : in  std_logic_vector(15 downto 0);
        rx_invert             : in std_logic;
        
        -- demod control plane (from regs)
        demod_init            : in  std_logic;
        lpf_freeze            : in  std_logic;
        lpf_zero              : in  std_logic;
        rx_enable             : in  std_logic;
        rx_sample_discard     : in  std_logic_vector(7 downto 0);

        -- carrier NCO adjust (drift) -> regs
        f1_nco_adjust         : out std_logic_vector(31 downto 0);
        f2_nco_adjust         : out std_logic_vector(31 downto 0);

        -- status / telemetry
        frame_sync_locked : out std_logic;
        frames_received   : out std_logic_vector(31 downto 0);
        -- map v6 symbol lock detector: config in (from regs), status out
        cfo_ctrl          : in  std_logic_vector(31 downto 0);
        cfo_manual        : in  std_logic_vector(15 downto 0);
        cfo_applied       : out std_logic_vector(15 downto 0);
        tim_alpha         : in  std_logic_vector(15 downto 0);
        tim_beta          : in  std_logic_vector(15 downto 0);
        sym_clk_offset    : out std_logic_vector(31 downto 0);
        sl_pct_lock       : in  std_logic_vector(7 downto 0);
        sl_pct_unlock     : in  std_logic_vector(7 downto 0);
        sl_window_log2    : in  std_logic_vector(3 downto 0);
        sl_ratio_pct      : out std_logic_vector(7 downto 0);
        sl_window_full    : out std_logic;
        cst_lock_f1       : out std_logic;
        cst_lock_f2       : out std_logic;

        -- debug tap: target-channel complex sample + strobe, for the TB's
        -- chan0_iq.txt capture (FFT / centroid spectrum check). Tie to open in
        -- the block design; synthesis trims it.
        dbg_tgt_i         : out std_logic_vector(15 downto 0);
        dbg_tgt_q         : out std_logic_vector(15 downto 0);
        dbg_tgt_valid     : out std_logic;

        -- gain node
        gain_manual       : in  std_logic_vector(15 downto 0);  -- Q6.10, unity 0x0400
        gain_current      : out std_logic_vector(15 downto 0);

        -- frame sync thresholds
        fs_hunt_thresh    : in std_logic_vector(31 downto 0);
        fs_verify_thresh  : in std_logic_vector(31 downto 0);
        quant_thr_1       : in std_logic_vector(15 downto 0);
        quant_thr_2       : in std_logic_vector(15 downto 0);
        quant_thr_3       : in std_logic_vector(15 downto 0);

        -- frame-sync taps
        dbg_fs_state      : out std_logic_vector(2 downto 0);
        dbg_fs_corr       : out std_logic_vector(31 downto 0);
        dbg_fs_corr_peak  : out std_logic_vector(31 downto 0);
        dbg_fs_soft_q     : out std_logic_vector(2 downto 0);
        dbg_soft_corr     : out std_logic_vector(15 downto 0);
        dbg_sym_valid     : out std_logic;

        -- costas taps
        dbg_cst_iq_delta  : out std_logic_vector(31 downto 0);
        dbg_cst_acc_i     : out std_logic_vector(31 downto 0);
        dbg_cst_acc_q     : out std_logic_vector(31 downto 0);
        dbg_f1_err        : out std_logic_vector(31 downto 0);
        dbg_f2_err        : out std_logic_vector(31 downto 0);
        dbg_lpf_acc_f1    : out std_logic_vector(31 downto 0);
        dbg_lpf_acc_f2    : out std_logic_vector(31 downto 0);
        dbg_cst_locktime_f1 : out std_logic_vector(15 downto 0);
        dbg_cst_locktime_f2 : out std_logic_vector(15 downto 0);
        dbg_cst_unlock_f1 : out std_logic;
        dbg_cst_unlock_f2 : out std_logic
    );
end entity haifuraiya_rx_top;

architecture rtl of haifuraiya_rx_top is

    -- Two distinct widths -- conflating them was the SAMPLE_W bug.
    constant CHAN_I_W       : natural := 16;  -- channelizer I capture width (full m_axis_chans I)
    -- DEMOD_SAMPLE_W (12) and RX_SLICE_HI retired with the Costas demod:
    -- the 12-bit slice-as-Kd plan was 9361/Pluto heritage. The MLSE demod
    -- takes the full 16-bit normalized samples; the input-level knob is
    -- now the normalizer gain_target (LEVEL_PLAN rms-9000 operating
    -- point). Seam decision ratified 2026-07-16 (rx_top_patch_notes.md).

    signal reset_h      : std_logic;         -- active-high reset for the modem blocks
    signal demod_init_h : std_logic;

    -- channelizer per-channel output bus
    signal chans_tdata  : std_logic_vector(31 downto 0);
    signal chans_tvalid : std_logic;
    signal chans_tready : std_logic;
    signal chans_tdest  : std_logic_vector(7 downto 0);
    signal chans_tlast  : std_logic;

    -- demux'd target channel
    signal chan_i_reg : std_logic_vector(CHAN_I_W-1 downto 0) := (others => '0');
    signal chan_q_reg : std_logic_vector(15 downto 0)         := (others => '0'); -- debug tap (Q) only
    signal rx_svalid  : std_logic := '0';

    -- intermediate signals for complex modulation
    signal rx_i_to_demod : std_logic_vector(15 downto 0);
    signal rx_q_to_demod : std_logic_vector(15 downto 0);

    -- demod outputs
    signal rx_data      : std_logic;
    signal rx_data_soft : signed(15 downto 0);
    signal rx_data_soft_corr : signed(15 downto 0);
    signal rx_dvalid    : std_logic;
    signal rx_bit_corr  : std_logic;
    signal demod_lock   : std_logic;
    -- map v6 symbol lock detector plumbing (type bridges for the ports)
    signal sl_thl_u : unsigned(7 downto 0);
    signal sl_thu_u : unsigned(7 downto 0);
    signal sl_wl2_u : unsigned(3 downto 0);
    signal sl_pct_u : unsigned(7 downto 0);
    signal tim_a_u  : unsigned(15 downto 0);
    signal tim_b_u  : unsigned(15 downto 0);
    signal clk_off_s: signed(31 downto 0);
    -- CFO correction (WP2 step 1: manual path; step 2 adds the AFC estimate)
    signal cfo_word   : signed(15 downto 0);
    signal rot_valid  : std_logic;
    signal rot_i      : signed(15 downto 0);
    signal rot_q      : signed(15 downto 0);
    
    -- intermediate signal for the signed ports
    signal sig_fs_corr, sig_fs_corr_peak : signed(31 downto 0);

    -- saturating signed resize to 16 bits
    function sat16(x : signed) return signed is
        constant HI : integer := 32767;
        constant LO : integer := -32768;
    begin
        if    x >  HI then return to_signed(HI,16);
        elsif x <  LO then return to_signed(LO,16);
        else  return resize(x,16); end if;
    end function;

    signal gain_u   : unsigned(15 downto 0);
    signal prod_i_g : signed(32 downto 0);
    signal prod_q_g : signed(32 downto 0);
    signal gi, gq   : signed(15 downto 0);

begin

    tim_a_u        <= unsigned(tim_alpha);
    tim_b_u        <= unsigned(tim_beta);
    sym_clk_offset <= std_logic_vector(clk_off_s);
    sl_thl_u     <= unsigned(sl_pct_lock);
    sl_thu_u     <= unsigned(sl_pct_unlock);
    sl_wl2_u     <= unsigned(sl_window_log2);
    sl_ratio_pct <= std_logic_vector(sl_pct_u);

    reset_h <= not aresetn;
    demod_init_h <= reset_h or demod_init;

    -- accept every channel beat; act only on the target
    chans_tready <= '1';

    --rx_data_soft_corr <= rx_data_soft when RX_INVERT = '0' else -rx_data_soft;
    rx_data_soft_corr <= rx_data_soft when rx_invert = '0' else -rx_data_soft;


    gain_u   <= unsigned(gain_manual);
    prod_i_g <= signed(chan_i_reg) * signed('0' & std_logic_vector(gain_u)); -- 16x17
    prod_q_g <= signed(chan_q_reg) * signed('0' & std_logic_vector(gain_u));
    gi <= sat16( shift_right(prod_i_g, 10) );   -- Q6.10 -> drop 10 frac bits
    gq <= sat16( shift_right(prod_q_g, 10) );
    gain_current <= gain_manual;                -- readback seam (auto fills this later)

    ----------------------------------------------------------------------------
    -- Channelizer IP (sealed; do not modify). Debug ports left open.
    ----------------------------------------------------------------------------
    u_chan : entity work.haifuraiya_channelizer_axi
        generic map (
            N_CHANNELS              => N_CHANNELS,
            M_DECIMATION            => M_DECIMATION,
            C_S_AXI_CTRL_ADDR_WIDTH => C_S_AXI_CTRL_ADDR_WIDTH
        )
        port map (
            aclk    => aclk,
            aresetn => aresetn,

            s_axis_data_tdata  => s_axis_data_tdata,
            s_axis_data_tvalid => s_axis_data_tvalid,
            s_axis_data_tready => s_axis_data_tready,

            m_axis_chans_tdata  => chans_tdata,
            m_axis_chans_tvalid => chans_tvalid,
            m_axis_chans_tready => chans_tready,
            m_axis_chans_tdest  => chans_tdest,
            m_axis_chans_tlast  => chans_tlast,

            s_axi_ctrl_awaddr  => s_axi_ctrl_awaddr,
            s_axi_ctrl_awvalid => s_axi_ctrl_awvalid,
            s_axi_ctrl_awready => s_axi_ctrl_awready,
            s_axi_ctrl_wdata   => s_axi_ctrl_wdata,
            s_axi_ctrl_wstrb   => s_axi_ctrl_wstrb,
            s_axi_ctrl_wvalid  => s_axi_ctrl_wvalid,
            s_axi_ctrl_wready  => s_axi_ctrl_wready,
            s_axi_ctrl_bresp   => s_axi_ctrl_bresp,
            s_axi_ctrl_bvalid  => s_axi_ctrl_bvalid,
            s_axi_ctrl_bready  => s_axi_ctrl_bready,
            s_axi_ctrl_araddr  => s_axi_ctrl_araddr,
            s_axi_ctrl_arvalid => s_axi_ctrl_arvalid,
            s_axi_ctrl_arready => s_axi_ctrl_arready,
            s_axi_ctrl_rdata   => s_axi_ctrl_rdata,
            s_axi_ctrl_rresp   => s_axi_ctrl_rresp,
            s_axi_ctrl_rvalid  => s_axi_ctrl_rvalid,
            s_axi_ctrl_rready  => s_axi_ctrl_rready,

            dbg_chan_re_q      => open,
            dbg_chan_im_q      => open,
            dbg_chan_valid_r   => open,
            dbg_chan_idx_int_r => open,
            dbg_chan_valid     => open,
            dbg_chan_idx_int   => open,
            dbg_pd_data_ena    => open,
            dbg_core_reset     => open,
            dbg_core_dropped   => open,
            dbg_chan_last      => open,
            dbg_pd0_dsum       => open,
            dbg_pd0_dsum_e2    => open,
            dbg_pd0_ema_1      => open,
            dbg_pd0_ema_1_ena  => open,
            dbg_pd0_ema_2      => open
        );

    ----------------------------------------------------------------------------
    -- TDEST demux: forward ONLY TARGET_CHANNEL's I to the demod.
    ----------------------------------------------------------------------------
    demux : process(aclk)
    begin
        if rising_edge(aclk) then
            rx_svalid <= '0';                      -- default: no new sample
            if reset_h = '1' then
                rx_svalid  <= '0';
            elsif chans_tvalid = '1' and chans_tready = '1' then
                if to_integer(unsigned(chans_tdest(5 downto 0))) = TARGET_CHANNEL then
                    chan_i_reg <= chans_tdata(15 downto 0);   -- I = TDATA[15:0]
                    chan_q_reg <= chans_tdata(31 downto 16);  -- Q = TDATA[31:16] (debug tap only)
                    rx_svalid  <= '1';
                end if;
            end if;
        end if;
    end process;

    -- conditional signal drivers
    --rx_i_to_demod <= chan_i_reg(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1);
    --rx_q_to_demod <= chan_q_reg(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1)
    --                 when COMPLEX_INPUT else (others => '0');

    -- conditional signal drivers slice gi/gq instead of chan_i_reg/chan_q_reg here:
    --rx_i_to_demod <= std_logic_vector(gi(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1));
    --rx_q_to_demod <= std_logic_vector(gq(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1))
    --                 when COMPLEX_INPUT else (others => '0');

    ----------------------------------------------------------------------------
    -- CFO correction rotator (WP2 step 1 -- WP2_CFO_DESIGN.md section 4/6).
    --
    -- ORDERING IS THE SIGN CONVENTION (reorder ratified 2026-07-20):
    -- the rotator operates FIRST, in the channelizer's true domain
    -- (gi = I, gq = Q), where "remove +f" means exactly what the register
    -- says -- same antenna-frame convention as the C++ set_freq_offset.
    -- The deliberate I/Q swap that made the chain lock (gq -> demod I,
    -- gi -> demod Q; z' = j*conj(z)) is applied AFTER correction, as the
    -- last step before the demod. Conjugation negates frequency, so a
    -- rotator placed after the swap needs a negated command (measured on
    -- the red/green bench: +5000 post-swap doubled the error, -5000
    -- cleaned it). Rotating before the swap keeps every sign natural and
    -- no negation exists anywhere. Debt note: trace the swap to its true
    -- origin (channelizer bin conjugation vs demod expectation).
    --
    -- Applied word: CFO_MANUAL when CFO_CTRL.auto=0; zero when auto=1
    -- until step 2 lands the AFC estimator (which will drive this mux).
    ----------------------------------------------------------------------------
    cfo_word <= signed(cfo_manual) when cfo_ctrl(0) = '0'
                else (others => '0');   -- step 2: AFC estimate here
    cfo_applied <= std_logic_vector(cfo_word);

    u_cfo : entity work.cfo_rotator
        port map (
            clk       => aclk,
            rst       => reset_h,
            en        => rx_svalid,
            i_in      => gi,               -- TRUE domain: no swap yet
            q_in      => gq,
            freq_hz   => cfo_word,         -- natural sign, antenna frame
            out_valid => rot_valid,
            i_out     => rot_i,
            q_out     => rot_q
        );

    -- the deliberate swap, applied to the CORRECTED samples
    rx_i_to_demod <= std_logic_vector(rot_q);
    rx_q_to_demod <= std_logic_vector(rot_i)
                 when COMPLEX_INPUT else (others => '0');

    ----------------------------------------------------------------------------
    -- MSK demodulator: MLSE receiver (msk_symbol_engine + msk_mlse4 behind
    -- a streaming ring buffer). Replaces the dual-Costas msk_demodulator.
    -- No NCO freq words, no loop-filter tuning: the receiver has no Costas
    -- loops. Soft output is already in fsync polarity (positive = confident
    -- '0'), same convention the old demod fed u_fsync; RX_INVERT semantics
    -- unchanged. Verified: sim/demod (10/10 frames, metrics all zero,
    -- 2026-07-16).
    ----------------------------------------------------------------------------
    u_demod : entity work.msk_demodulator_mlse
        port map (
            clk  => aclk,
            init => demod_init_h,

            rx_enable    => rx_enable,
            rx_svalid    => rot_valid,
            rx_i_samples => rx_i_to_demod,
            rx_q_samples => rx_q_to_demod,

            rx_data      => rx_data,
            rx_data_soft => rx_data_soft,
            rx_dvalid    => rx_dvalid,

            demod_lock   => demod_lock,

            tim_alpha        => tim_a_u,
            tim_beta         => tim_b_u,
            sym_clk_offset   => clk_off_s,
            sl_pct_lock      => sl_thl_u,
            sl_pct_unlock    => sl_thu_u,
            sl_window_log2   => sl_wl2_u,
            sl_ratio_pct     => sl_pct_u,
            sl_window_full   => sl_window_full,

            ovfl_mlse    => open,   -- sticky diagnostics: route to demod
            ring_lag     => open,   -- regs status when the map is reworked

            dbg_pos      => open,
            dbg_sym      => open,
            dbg_th0      => open
        );

    rx_bit_corr <= rx_data when RX_INVERT = '0' else not rx_data;
    -- demod_lock now comes directly from the MLSE demod (acquisition
    -- complete). Legacy per-tone lock ports mirror it; Costas telemetry
    -- ports tie to zero (Costas retired; MLSE taps are sim-probeable).
    cst_lock_f1 <= demod_lock;
    cst_lock_f2 <= demod_lock;
    dbg_cst_iq_delta    <= (others => '0');
    dbg_cst_acc_i       <= (others => '0');
    dbg_cst_acc_q       <= (others => '0');
    dbg_f1_err          <= (others => '0');
    dbg_f2_err          <= (others => '0');
    dbg_lpf_acc_f1      <= (others => '0');
    dbg_lpf_acc_f2      <= (others => '0');
    dbg_cst_locktime_f1 <= (others => '0');
    dbg_cst_locktime_f2 <= (others => '0');
    dbg_cst_unlock_f1   <= '0';
    dbg_cst_unlock_f2   <= '0';

    -- debug tap out (aligned: chan_i_reg/chan_q_reg and rx_svalid update on the same edge)
    dbg_tgt_i     <= chan_i_reg;
    dbg_tgt_q     <= chan_q_reg;
    dbg_tgt_valid <= rx_svalid;

    -- concurrent assignments? do they go here?
    dbg_fs_corr      <= std_logic_vector(sig_fs_corr);
    dbg_fs_corr_peak <= std_logic_vector(sig_fs_corr_peak);
    dbg_soft_corr    <= std_logic_vector(rx_data_soft_corr);
    dbg_sym_valid    <= rx_dvalid;

    ----------------------------------------------------------------------------
    -- Frame sync detector: soft-bit stream out to DMA. Byte path unused.
    ----------------------------------------------------------------------------
    u_fsync : entity work.frame_sync_detector_soft
        generic map (
            HUNTING_THRESHOLD => 115000,   -- was 60000 in libreSDR
            LOCKED_THRESHOLD  => 68000    -- was 36000 in libreSDR
        )
        port map (
            clk   => aclk,
            reset => reset_h,

            rx_bit            => rx_bit_corr,
            rx_bit_valid      => rx_dvalid,
            --s_axis_soft_tdata => rx_data_soft,
            s_axis_soft_tdata => rx_data_soft_corr,   -- was rx_data_soft

            m_axis_tdata  => open,
            m_axis_tvalid => open,
            m_axis_tready => '1',         -- byte path unused; let it drain
            m_axis_tlast  => open,

            m_axis_soft_bit_tdata  => m_axis_soft_bit_tdata,
            m_axis_soft_bit_tvalid => m_axis_soft_bit_tvalid,
            m_axis_soft_bit_tready => m_axis_soft_bit_tready,
            m_axis_soft_bit_tlast  => m_axis_soft_bit_tlast,

            hunting_threshold_i    => fs_hunt_thresh,
            locked_threshold_i     => fs_verify_thresh,

            frame_sync_locked      => frame_sync_locked,
            frames_received        => frames_received,
            frame_sync_errors      => open,
            frame_buffer_overflow  => open,
            quant_thr_1_i          => quant_thr_1,
            quant_thr_2_i          => quant_thr_2,
            quant_thr_3_i          => quant_thr_3,

            demod_sync_lock => demod_lock,

            --debug_state          => open, --remapped
            --debug_correlation    => open, --remapped
            --debug_corr_peak      => open, --remapped
            debug_bit_count        => open,
            debug_missed_syncs     => open,
            debug_consecutive_good => open,
            debug_soft_current     => open,
            --debug_soft_quantized   => open, --remapped
            debug_byte_v           => open,

            debug_state          => dbg_fs_state,
            debug_correlation    => sig_fs_corr,
            debug_corr_peak      => sig_fs_corr_peak,
            debug_soft_quantized => dbg_fs_soft_q
        );

end architecture rtl;

--------------------------------------------------------------------------------
-- Scaling to all 64 channels (deliberate next step, after one channel locks):
--
--   Option A -- parallel: 64x (demux + msk_demodulator + frame_sync_detector_soft),
--     one per channel, each demux'ing its own TDEST. Simplest to wire; highest LUT
--     cost (this is the cost the old plan-of-attack worried about -- measure it for
--     just the demod+fsync core, which is far smaller than full pluto_msk).
--
--   Option B -- time-shared / TDM: one (or N) demod datapath(s) processing the TDM
--     channel stream, with per-channel STATE (Costas NCO phase, loop accumulators,
--     lpf_accum_f1/f2, lock) held in channel-indexed memory and swapped each TDM slot.
--     Resource-efficient but requires reworking the demod state to be channel-indexed
--     -- a real change to msk_demodulator, not just instantiation.
--
--   Decide A vs B from the single-channel LUT measurement x64 vs the TDM rework cost.
--   Either way: prove ONE channel end-to-end (this scaffold) first.
--------------------------------------------------------------------------------
