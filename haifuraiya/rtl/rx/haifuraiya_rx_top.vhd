--------------------------------------------------------------------------------
-- haifuraiya_rx_top : single-channel RX bring-up scaffold
--
-- Chain:  haifuraiya_channelizer_axi  (m_axis_chans, complex I/Q per channel, TDEST)
--           -> TDEST demux (pick ONE channel = TARGET_CHANNEL, forward its I)
--           -> msk_demodulator  (real-input, I-only; forms its own I/Q internally)
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
--   * KEY TO LOCK: the demod is real-input. It only locks if the OPV signal sits
--     at a real IF *within* the channel (not at channel center). Place the carrier
--     ~+baud/2 off center and set rx_freq_word_f1/f2 to that IF, or it will not lock.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_rx_top is
    generic (
        TARGET_CHANNEL : natural := 0;     -- 0..63: channel to bring up first
        RX_INVERT      : std_logic := '0'; -- bit polarity (matches msk_top rx_invert)
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

        -- status / telemetry
        frame_sync_locked : out std_logic;
        frames_received   : out std_logic_vector(31 downto 0);
        cst_lock_f1       : out std_logic;
        cst_lock_f2       : out std_logic
    );
end entity haifuraiya_rx_top;

architecture rtl of haifuraiya_rx_top is

    constant SAMPLE_W : natural := 12;  -- keeping channelizer's full 16-bit I width oops didn't work, set to 12

    signal reset_h : std_logic;         -- active-high reset for the modem blocks

    -- channelizer per-channel output bus
    signal chans_tdata  : std_logic_vector(31 downto 0);
    signal chans_tvalid : std_logic;
    signal chans_tready : std_logic;
    signal chans_tdest  : std_logic_vector(7 downto 0);
    signal chans_tlast  : std_logic;

    -- demux'd target channel
    signal chan_i_reg : std_logic_vector(SAMPLE_W-1 downto 0) := (others => '0');
    signal rx_svalid  : std_logic := '0';

    -- demod outputs
    signal rx_data      : std_logic;
    signal rx_data_soft : signed(15 downto 0);
    signal rx_dvalid    : std_logic;
    signal lock_f1, lock_f2 : std_logic;
    signal rx_bit_corr  : std_logic;
    signal demod_lock   : std_logic;

begin

    reset_h <= not aresetn;

    -- accept every channel beat; act only on the target
    chans_tready <= '1';

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
    -- Q is ignored here (channelizer does per-channel power detection itself).
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
                    rx_svalid  <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- MSK demodulator (real-input, I-only). Loopback/decoder-lbk tied off.
    ----------------------------------------------------------------------------
    u_demod : entity work.msk_demodulator
        generic map (
            SAMPLE_W => SAMPLE_W
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

            lpf_accum_f1 => open,
            lpf_accum_f2 => open,
            f1_nco_adjust => open,
            f2_nco_adjust => open,
            f1_error => open,
            f2_error => open,

            rx_dec_lbk_ena  => '0',
            rx_dec_lbk_tclk => '0',
            rx_dec_lbk_f1   => (others => '0'),
            rx_dec_lbk_f2   => (others => '0'),

            rx_enable  => '1',
            rx_svalid  => rx_svalid,
            rx_samples => chan_i_reg(15 downto 4),  -- drop to 12
            --rx_samples => chan_i_reg, -- full 16 beans

            rx_data      => rx_data,
            rx_data_soft => rx_data_soft,
            rx_dvalid    => rx_dvalid,

            symbol_lock_count     => symbol_lock_count,
            symbol_lock_threshold => symbol_lock_threshold,

            cst_lock_f1 => lock_f1,
            cst_lock_f2 => lock_f2,
            cst_lock_time_f1 => open,
            cst_lock_time_f2 => open,
            cst_unlock_f1 => open,
            cst_unlock_f2 => open,

            dbg_acc_i_f1       => open,
            dbg_acc_q_f1       => open,
            dbg_acc_iq_delta_f1 => open
        );

    rx_bit_corr <= rx_data when RX_INVERT = '0' else not rx_data;
    demod_lock  <= lock_f1 and lock_f2;
    cst_lock_f1 <= lock_f1;
    cst_lock_f2 <= lock_f2;

    ----------------------------------------------------------------------------
    -- Frame sync detector: soft-bit stream out to DMA. Byte path unused.
    ----------------------------------------------------------------------------
    u_fsync : entity work.frame_sync_detector_soft
        port map (
            clk   => aclk,
            reset => reset_h,

            rx_bit            => rx_bit_corr,
            rx_bit_valid      => rx_dvalid,
            s_axis_soft_tdata => rx_data_soft,

            m_axis_tdata  => open,
            m_axis_tvalid => open,
            m_axis_tready => '1',         -- byte path unused; let it drain
            m_axis_tlast  => open,

            m_axis_soft_bit_tdata  => m_axis_soft_bit_tdata,
            m_axis_soft_bit_tvalid => m_axis_soft_bit_tvalid,
            m_axis_soft_bit_tready => m_axis_soft_bit_tready,
            m_axis_soft_bit_tlast  => m_axis_soft_bit_tlast,

            frame_sync_locked     => frame_sync_locked,
            frames_received       => frames_received,
            frame_sync_errors     => open,
            frame_buffer_overflow => open,

            demod_sync_lock => demod_lock,

            debug_state            => open,
            debug_correlation      => open,
            debug_corr_peak        => open,
            debug_bit_count        => open,
            debug_missed_syncs     => open,
            debug_consecutive_good => open,
            debug_soft_current     => open,
            debug_soft_quantized   => open,
            debug_byte_v           => open
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
