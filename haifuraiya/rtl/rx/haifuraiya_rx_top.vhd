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

        -- status / telemetry
        frame_sync_locked : out std_logic;
        frames_received   : out std_logic_vector(31 downto 0);
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
    constant DEMOD_SAMPLE_W : natural := 12;  -- demod sample width (PROVEN tuning; do NOT set to 16)
    -- Top bit of the 12-bit slice handed to the demod = the Kd / input-level knob.
    --   15 -> chan_i_reg(15 downto 4) : top 12 bits, no clipping (safe default)
    --   13 -> chan_i_reg(13 downto 2) : +12 dB into the loop, clips above 2^13
    -- Confirm by measuring the channel-0 I amplitude with the real 20 Msps stimulus.
    constant RX_SLICE_HI    : natural := 13; -- was 15, now 13 to fix alignment issue

    signal reset_h : std_logic;         -- active-high reset for the modem blocks

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
    signal rx_i_to_demod : std_logic_vector(DEMOD_SAMPLE_W-1 downto 0);
    signal rx_q_to_demod : std_logic_vector(DEMOD_SAMPLE_W-1 downto 0);

    -- demod outputs
    signal rx_data      : std_logic;
    signal rx_data_soft : signed(15 downto 0);
    signal rx_data_soft_corr : signed(15 downto 0);
    signal rx_dvalid    : std_logic;
    signal lock_f1, lock_f2 : std_logic;
    signal rx_bit_corr  : std_logic;
    signal demod_lock   : std_logic;
    
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

    reset_h <= not aresetn;

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

    rx_i_to_demod <= std_logic_vector(gq(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1));
    rx_q_to_demod <= std_logic_vector(gi(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1))
                 when COMPLEX_INPUT else (others => '0');

    ----------------------------------------------------------------------------
    -- MSK demodulator (complex). Loopback/decoder-lbk tied off.
    ----------------------------------------------------------------------------
    u_demod : entity work.msk_demodulator
        generic map (
            SAMPLE_W => DEMOD_SAMPLE_W,
            -- clk here is the 100 MHz fabric clock, NOT the sample rate; channel samples
            -- arrive on rx_svalid (~625 ksps). Gate the carrier NCO per sample so it does
            -- not free-run at the fabric rate. (Pluto/LibreSDR run clk == fs and leave this
            -- at its default False.)
            SAMPLE_GATED_NCO => true
        )
        port map (
            clk  => aclk,
            init => reset_h,

            rx_freq_word_f1 => rx_freq_word_f1,
            rx_freq_word_f2 => rx_freq_word_f2,
            discard_rxnco   => (others => '0'),

            lpf_p_gain  => lpf_p_gain,
            lpf_i_gain  => lpf_i_gain,
            lpf_p_shift => lpf_p_shift,
            lpf_i_shift => lpf_i_shift,
            lpf_freeze  => '0',
            lpf_zero    => '0',
            lpf_alpha   => lpf_alpha,

            --lpf_accum_f1 => open,
            --lpf_accum_f2 => open,
            f1_nco_adjust => open,
            f2_nco_adjust => open,
            --f1_error => open,
            --f2_error => open,

            rx_dec_lbk_ena  => '0',
            rx_dec_lbk_tclk => '0',
            rx_dec_lbk_f1   => (others => '0'),
            rx_dec_lbk_f2   => (others => '0'),

            rx_enable  => '1',
            rx_svalid  => rx_svalid,
            --rx_samples => chan_i_reg(RX_SLICE_HI downto RX_SLICE_HI - DEMOD_SAMPLE_W + 1),
            rx_i_samples => rx_i_to_demod,
            rx_q_samples => rx_q_to_demod,

            rx_data      => rx_data,
            rx_data_soft => rx_data_soft,
            rx_dvalid    => rx_dvalid,

            symbol_lock_count     => symbol_lock_count,
            symbol_lock_threshold => symbol_lock_threshold,

            cst_lock_f1 => lock_f1,
            cst_lock_f2 => lock_f2,
            --cst_lock_time_f1 => open,
            --cst_lock_time_f2 => open,
            --cst_unlock_f1 => open,
            --cst_unlock_f2 => open,

            --dbg_acc_i_f1       => open,
            --dbg_acc_q_f1       => open,
            --dbg_acc_iq_delta_f1 => open,

            dbg_acc_iq_delta_f1 => dbg_cst_iq_delta, --remapped
            dbg_acc_i_f1        => dbg_cst_acc_i, --remapped
            dbg_acc_q_f1        => dbg_cst_acc_q, --remapped
            f1_error            => dbg_f1_err, --remapped
            f2_error            => dbg_f2_err, --remapped
            lpf_accum_f1        => dbg_lpf_acc_f1, --remapped
            lpf_accum_f2        => dbg_lpf_acc_f2, --remapped
            cst_lock_time_f1    => dbg_cst_locktime_f1, --remapped
            cst_lock_time_f2    => dbg_cst_locktime_f2, --remapped
            cst_unlock_f1       => dbg_cst_unlock_f1, --remapped
            cst_unlock_f2       => dbg_cst_unlock_f2 --remapped
        );

    rx_bit_corr <= rx_data when RX_INVERT = '0' else not rx_data;
    demod_lock  <= lock_f1 and lock_f2;
    cst_lock_f1 <= lock_f1;
    cst_lock_f2 <= lock_f2;

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
            HUNTING_THRESHOLD => 38000,   -- was 60000 in libreSDR
            LOCKED_THRESHOLD  => 24000    -- was 36000 in libreSDR
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
