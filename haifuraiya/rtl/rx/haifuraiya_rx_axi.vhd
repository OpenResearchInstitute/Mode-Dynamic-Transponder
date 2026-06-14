-------------------------------------------------------------------------------
-- haifuraiya_rx_axi.vhd
-- IP-top wrapper: OPV MSK receiver + AXI-Lite demod control plane
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: OPV MSK Receiver (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- The PS-facing skin packaged as the Haifuraiya receiver IP (v0.4). Pure
-- structural stitching -- no logic, no registers, no FSMs of its own:
--
--   haifuraiya_rx_axi            <- this file: the IP boundary
--   |- haifuraiya_rx_top         <- the receiver (channelizer + demod + sync)
--   \- haifuraiya_demod_regs     <- AXI-Lite tuning/status register file
--
-- The two AXI-Lite slaves are independent:
--   * s_axi_ctrl  -> rx_top -> channelizer (sealed), base 0x84A70000
--   * s_axi_demod -> demod register file,           base 0x84A80000
--
-- Demod tuning that used to be raw rx_top input ports is now sourced from
-- the register file's outputs (reset to the proven sim config); rx_top's
-- status is fed back into the register file's read-only registers.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_rx_axi is
    generic (
        TARGET_CHANNEL           : natural  := 0;
        COMPLEX_INPUT            : boolean  := true;   -- proven path feeds channel Q
        N_CHANNELS               : positive := 64;
        M_DECIMATION             : positive := 16;
        C_S_AXI_CTRL_ADDR_WIDTH  : positive := 12;     -- channelizer passthrough
        C_S_AXI_DEMOD_ADDR_WIDTH : positive := 12      -- demod control regs
    );
    port (
        aclk    : in std_logic;
        aresetn : in std_logic;

        -----------------------------------------------------------------------
        -- ADC complex I/Q in  (TDATA[31:16]=Q, [15:0]=I)
        -----------------------------------------------------------------------
        s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid : in  std_logic;
        s_axis_data_tready : out std_logic;

        -----------------------------------------------------------------------
        -- soft-bit out -> AXIS FIFO/DMA -> opv-decode -3
        -----------------------------------------------------------------------
        m_axis_soft_bit_tdata  : out std_logic_vector(2 downto 0);
        m_axis_soft_bit_tvalid : out std_logic;
        m_axis_soft_bit_tready : in  std_logic;
        m_axis_soft_bit_tlast  : out std_logic;

        -----------------------------------------------------------------------
        -- Channelizer control AXI-Lite (passthrough, base 0x84A70000)
        -----------------------------------------------------------------------
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

        -----------------------------------------------------------------------
        -- Demod control AXI-Lite (base 0x84A80000)
        -----------------------------------------------------------------------
        s_axi_demod_awaddr  : in  std_logic_vector(C_S_AXI_DEMOD_ADDR_WIDTH-1 downto 0);
        s_axi_demod_awvalid : in  std_logic;
        s_axi_demod_awready : out std_logic;
        s_axi_demod_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_demod_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_demod_wvalid  : in  std_logic;
        s_axi_demod_wready  : out std_logic;
        s_axi_demod_bresp   : out std_logic_vector(1 downto 0);
        s_axi_demod_bvalid  : out std_logic;
        s_axi_demod_bready  : in  std_logic;
        s_axi_demod_araddr  : in  std_logic_vector(C_S_AXI_DEMOD_ADDR_WIDTH-1 downto 0);
        s_axi_demod_arvalid : in  std_logic;
        s_axi_demod_arready : out std_logic;
        s_axi_demod_rdata   : out std_logic_vector(31 downto 0);
        s_axi_demod_rresp   : out std_logic_vector(1 downto 0);
        s_axi_demod_rvalid  : out std_logic;
        s_axi_demod_rready  : in  std_logic;

        -----------------------------------------------------------------------
        -- Demod status taps (also in DEMOD_STATUS reg; exposed for ILA / TB)
        -----------------------------------------------------------------------
        frame_sync_locked : out std_logic;
        frames_received   : out std_logic_vector(31 downto 0);
        cst_lock_f1       : out std_logic;
        cst_lock_f2       : out std_logic;

        -----------------------------------------------------------------------
        -- Debug taps -> ILA
        -----------------------------------------------------------------------
        dbg_tgt_i     : out std_logic_vector(15 downto 0);
        dbg_tgt_q     : out std_logic_vector(15 downto 0);
        dbg_tgt_valid : out std_logic;

        -- frame-sync taps for ILA
        dbg_fs_state      : out std_logic_vector(2 downto 0);
        dbg_fs_corr       : out std_logic_vector(31 downto 0);
        dbg_fs_corr_peak  : out std_logic_vector(31 downto 0);
        dbg_fs_soft_q     : out std_logic_vector(2 downto 0);
        dbg_soft_corr     : out std_logic_vector(15 downto 0);
        dbg_sym_valid     : out std_logic;

        -- costas taps for ILA
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
end entity haifuraiya_rx_axi;

architecture rtl of haifuraiya_rx_axi is

    -- demod_regs config-out -> rx_top tuning-in
    signal cfg_rx_invert          : std_logic;
    signal cfg_freq_word_f1       : std_logic_vector(31 downto 0);
    signal cfg_freq_word_f2       : std_logic_vector(31 downto 0);
    signal cfg_lpf_p_gain         : std_logic_vector(23 downto 0);
    signal cfg_lpf_i_gain         : std_logic_vector(23 downto 0);
    signal cfg_lpf_alpha          : std_logic_vector(23 downto 0);
    signal cfg_lpf_p_shift        : std_logic_vector(7 downto 0);
    signal cfg_lpf_i_shift        : std_logic_vector(7 downto 0);
    signal cfg_sym_lock_count     : std_logic_vector(9 downto 0);
    signal cfg_sym_lock_threshold : std_logic_vector(15 downto 0);

    -- rx_top status-out -> demod_regs status-in
    signal sts_frame_sync_locked  : std_logic;
    signal sts_frames_received    : std_logic_vector(31 downto 0);
    signal sts_cst_lock_f1        : std_logic;
    signal sts_cst_lock_f2        : std_logic;

    -- frame sync thresholds
    signal cfg_fs_hunt_thresh     : std_logic_vector(31 downto 0);
    signal cfg_fs_verify_thresh   : std_logic_vector(31 downto 0);

    signal cfg_gain_manual        : std_logic_vector(15 downto 0);
    signal sts_gain_current       : std_logic_vector(15 downto 0);

begin



    -- Status to boundary (for ILA / TB); same signals also feed demod_regs
    frame_sync_locked <= sts_frame_sync_locked;
    frames_received   <= sts_frames_received;
    cst_lock_f1       <= sts_cst_lock_f1;
    cst_lock_f2       <= sts_cst_lock_f2;

    ---------------------------------------------------------------------------
    -- Demod control / status register file (AXI-Lite slave: s_axi_demod)
    ---------------------------------------------------------------------------
    u_regs : entity work.haifuraiya_demod_regs
        generic map (
            ADDR_WIDTH    => C_S_AXI_DEMOD_ADDR_WIDTH,
            VERSION_MAJOR => 0,
            VERSION_MINOR => 4,
            VERSION_PATCH => 0
        )
        port map (
            aclk    => aclk,
            aresetn => aresetn,

            s_axi_awaddr  => s_axi_demod_awaddr,
            s_axi_awvalid => s_axi_demod_awvalid,
            s_axi_awready => s_axi_demod_awready,
            s_axi_wdata   => s_axi_demod_wdata,
            s_axi_wstrb   => s_axi_demod_wstrb,
            s_axi_wvalid  => s_axi_demod_wvalid,
            s_axi_wready  => s_axi_demod_wready,
            s_axi_bresp   => s_axi_demod_bresp,
            s_axi_bvalid  => s_axi_demod_bvalid,
            s_axi_bready  => s_axi_demod_bready,
            s_axi_araddr  => s_axi_demod_araddr,
            s_axi_arvalid => s_axi_demod_arvalid,
            s_axi_arready => s_axi_demod_arready,
            s_axi_rdata   => s_axi_demod_rdata,
            s_axi_rresp   => s_axi_demod_rresp,
            s_axi_rvalid  => s_axi_demod_rvalid,
            s_axi_rready  => s_axi_demod_rready,

            rx_invert             => cfg_rx_invert,
            rx_freq_word_f1       => cfg_freq_word_f1,
            rx_freq_word_f2       => cfg_freq_word_f2,
            lpf_p_gain            => cfg_lpf_p_gain,
            lpf_i_gain            => cfg_lpf_i_gain,
            lpf_alpha             => cfg_lpf_alpha,
            lpf_p_shift           => cfg_lpf_p_shift,
            lpf_i_shift           => cfg_lpf_i_shift,
            symbol_lock_count     => cfg_sym_lock_count,
            symbol_lock_threshold => cfg_sym_lock_threshold,

            frame_sync_locked     => sts_frame_sync_locked,
            frames_received       => sts_frames_received,
            cst_lock_f1           => sts_cst_lock_f1,
            cst_lock_f2           => sts_cst_lock_f2,
            fs_hunt_thresh        => cfg_fs_hunt_thresh,
            fs_verify_thresh      => cfg_fs_verify_thresh,
            quant_thr_1           => open,
            quant_thr_2           => open,
            quant_thr_3           => open,

            gain_manual           => cfg_gain_manual,
            gain_current          => sts_gain_current
        );

    ---------------------------------------------------------------------------
    -- The receiver: channelizer + demod + frame sync
    ---------------------------------------------------------------------------
    u_rx : entity work.haifuraiya_rx_top
        generic map (
            TARGET_CHANNEL          => TARGET_CHANNEL,
            COMPLEX_INPUT           => COMPLEX_INPUT,
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

            m_axis_soft_bit_tdata  => m_axis_soft_bit_tdata,
            m_axis_soft_bit_tvalid => m_axis_soft_bit_tvalid,
            m_axis_soft_bit_tready => m_axis_soft_bit_tready,
            m_axis_soft_bit_tlast  => m_axis_soft_bit_tlast,

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

            rx_freq_word_f1       => cfg_freq_word_f1,
            rx_freq_word_f2       => cfg_freq_word_f2,
            lpf_p_gain            => cfg_lpf_p_gain,
            lpf_i_gain            => cfg_lpf_i_gain,
            lpf_alpha             => cfg_lpf_alpha,
            lpf_p_shift           => cfg_lpf_p_shift,
            lpf_i_shift           => cfg_lpf_i_shift,
            symbol_lock_count     => cfg_sym_lock_count,
            symbol_lock_threshold => cfg_sym_lock_threshold,
            rx_invert             => cfg_rx_invert,

            frame_sync_locked => sts_frame_sync_locked,
            frames_received   => sts_frames_received,
            cst_lock_f1       => sts_cst_lock_f1,
            cst_lock_f2       => sts_cst_lock_f2,
            fs_hunt_thresh    => cfg_fs_hunt_thresh,
            fs_verify_thresh  => cfg_fs_verify_thresh,

            dbg_tgt_i     => dbg_tgt_i,
            dbg_tgt_q     => dbg_tgt_q,
            dbg_tgt_valid => dbg_tgt_valid,

            dbg_fs_state      => dbg_fs_state,
            dbg_fs_corr       => dbg_fs_corr,
            dbg_fs_corr_peak  => dbg_fs_corr_peak,
            dbg_fs_soft_q     => dbg_fs_soft_q,
            dbg_soft_corr     => dbg_soft_corr,
            dbg_sym_valid     => dbg_sym_valid,

            dbg_cst_iq_delta    => dbg_cst_iq_delta,
            dbg_cst_acc_i       => dbg_cst_acc_i,
            dbg_cst_acc_q       => dbg_cst_acc_q,
            dbg_f1_err          => dbg_f1_err,
            dbg_f2_err          => dbg_f2_err,
            dbg_lpf_acc_f1      => dbg_lpf_acc_f1,
            dbg_lpf_acc_f2      => dbg_lpf_acc_f2,
            dbg_cst_locktime_f1 => dbg_cst_locktime_f1,
            dbg_cst_locktime_f2 => dbg_cst_locktime_f2,
            dbg_cst_unlock_f1   => dbg_cst_unlock_f1,
            dbg_cst_unlock_f2   => dbg_cst_unlock_f2,

            gain_manual         => cfg_gain_manual,
            gain_current        => sts_gain_current
        );

end architecture rtl;
