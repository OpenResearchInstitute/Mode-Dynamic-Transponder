-------------------------------------------------------------------------------
-- haifuraiya_demod_regs.vhd
-- AXI-Lite Demod Control / Status Register Block for Haifuraiya
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: OPV MSK Receiver (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-- Adapted from axi_lite_regs.vhd (the channelizer's register block): the
-- two-FSM AXI-Lite machinery is unchanged; only the register set differs.
-- Channelizer registers (CHANNEL_POWER, EMA alphas, OUTPUT_SHIFT) are
-- removed; the msk_demodulator tuning + frame-sync status take their place.
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- AXI4-Lite slave exposing the demodulator's tuning and status to PS
-- software, separate from the channelizer's own s_axi_ctrl. The demod
-- owns its own control plane; the channelizer does not carry it.
--
-- Reset values ARE the configuration the receiver decoded with in
-- simulation (corr_peak +50001), so the block powers up in the proven
-- config before the PS writes anything. Every RW register is live-tunable
-- over AXI for bring-up against real RF -- no rebuild to retune.
--
-- Register map (4 KB window, byte addresses):
--
--   0x000  DEMOD_VERSION        RO   {major[15:8], minor[7:0], patch[7:0], 0}
--   0x004  DEMOD_CONTROL        RW   bit 0: rx_invert (soft-bit polarity)
--   0x008  FREQ_WORD_F1         RW   complex lower tone phase increment
--   0x00C  FREQ_WORD_F2         RW   complex upper tone phase increment
--   0x010  LPF_P_GAIN           RW   loop-filter proportional gain  [23:0]
--   0x014  LPF_I_GAIN           RW   loop-filter integral gain      [23:0]
--   0x018  LPF_ALPHA            RW   loop-filter alpha              [23:0]
--   0x01C  LPF_P_SHIFT          RW   proportional shift             [7:0]
--   0x020  LPF_I_SHIFT          RW   integral shift                 [7:0]
--   0x024  SYM_LOCK_COUNT       RW   symbol lock count              [9:0]
--   0x028  SYM_LOCK_THRESHOLD   RW   symbol lock threshold          [15:0]
--   0x030  GAIN_MANUAL          RW   manual gain (Q6.10)            [15:0]
--   0x038  GAIN_CURRENT         RO   current gain (Q6.10)           [15:0]
--   0x040  DEMOD_STATUS         RO   bit 0: frame_sync_locked
--                                    bit 1: cst_lock_f1
--                                    bit 2: cst_lock_f2
--   0x044  FRAMES_RECEIVED      RO   frames decoded since reset
--   0x048  FS_HUNT_THRESH       RW   frame-sync hunt threshold
--   0x04C  FS_VERIFY_THRESH     RW   frame-sync verify threshold
--   0x050  QUANT_THR_1          RW   soft-bit quantizer threshold 1 [15:0]
--   0x054  QUANT_THR_2          RW   soft-bit quantizer threshold 2 [15:0]
--   0x058  QUANT_THR_3          RW   soft-bit quantizer threshold 3 [15:0]
--
--   --- demod control plane added (mirrors pluto_msk msk_demodulator ports) -
--   0x05C  DEMOD_INIT           RW   bit 0: rx_init (write 1 then 0 = re-init)
--   0x060  LOOP_CTRL            RW   bit 0: lpf_freeze
--                                    bit 1: lpf_zero
--                                    bit 2: rx_enable (reset 1)
--   0x064  RX_SAMPLE_DISCARD    RW   discard_rxnco                  [7:0]
--
--   --- demod loop telemetry added (read-only, live) ----------------------
--   0x068  F1_NCO_ADJUST        RO   f1 carrier NCO adjust (drift)  [31:0]
--   0x06C  F2_NCO_ADJUST        RO   f2 carrier NCO adjust (drift)  [31:0]
--   0x070  F1_ERROR             RO   f1 Costas loop error           [31:0]
--   0x074  F2_ERROR             RO   f2 Costas loop error           [31:0]
--   0x078  LPF_ACCUM_F1         RO   f1 loop-filter accumulator     [31:0]
--   0x07C  LPF_ACCUM_F2         RO   f2 loop-filter accumulator     [31:0]
--   0x080  CST_LOCKTIME_F1      RO   f1 symbols-held counter        [15:0]
--   0x084  CST_LOCKTIME_F2      RO   f2 symbols-held counter        [15:0]
--   0x088  LOCK_STATUS          RO   bit 0: cst_lock_f1
--                                    bit 1: cst_lock_f2
--                                    bit 2: cst_unlock_f1 (sticky in core)
--                                    bit 3: cst_unlock_f2 (sticky in core)
--   0x08C  CST_ACC_I_F1         RO   f1 symbol-lock cal tap (acc I) [31:0]
--   0x090  CST_ACC_Q_F1         RO   f1 symbol-lock cal tap (acc Q) [31:0]
--   0x094  CST_IQ_DELTA_F1      RO   f1 symbol-lock cal tap (delta) [31:0]
--
-------------------------------------------------------------------------------
-- IMPLEMENTATION NOTES
-------------------------------------------------------------------------------
-- Standard Xilinx-template-style two-FSM AXI-Lite slave (one FSM for the
-- write path, one for the read path). Always-ready when idle; never
-- reordered; no outstanding transactions. Identical handshake to
-- axi_lite_regs.vhd.
--
-- The control-plane outputs (DEMOD_INIT, LOOP_CTRL, RX_SAMPLE_DISCARD) carry
-- the msk_demodulator ports that rx_top previously tied off as constants.
-- The telemetry inputs are the demod's live loop signals -- most are already
-- routed to rx_top's dbg_* outputs for the ILA; this just also makes them
-- devmem-readable. f1/f2_nco_adjust are new rx_top outputs (were => open).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_demod_regs is
    generic (
        ADDR_WIDTH    : positive := 12;   -- 4 KB window
        VERSION_MAJOR : natural  := 0;
        VERSION_MINOR : natural  := 5;    -- bumped: expanded demod control plane
        VERSION_PATCH : natural  := 0
    );
    port (
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        ---------------------------------------------------------------------
        -- AXI-Lite slave port (s_axi_demod)
        ---------------------------------------------------------------------
        s_axi_awaddr    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(31 downto 0);
        s_axi_wstrb     : in  std_logic_vector(3 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(31 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        ---------------------------------------------------------------------
        -- Outputs to rx_top (demod tuning) -- reset to proven sim values
        ---------------------------------------------------------------------
        rx_invert             : out std_logic;
        rx_freq_word_f1       : out std_logic_vector(31 downto 0);
        rx_freq_word_f2       : out std_logic_vector(31 downto 0);
        lpf_p_gain            : out std_logic_vector(23 downto 0);
        lpf_i_gain            : out std_logic_vector(23 downto 0);
        lpf_alpha             : out std_logic_vector(23 downto 0);
        lpf_p_shift           : out std_logic_vector(7 downto 0);
        lpf_i_shift           : out std_logic_vector(7 downto 0);
        symbol_lock_count     : out std_logic_vector(9 downto 0);
        symbol_lock_threshold : out std_logic_vector(15 downto 0);
        gain_manual           : out std_logic_vector(15 downto 0);
        fs_hunt_thresh        : out std_logic_vector(31 downto 0);
        fs_verify_thresh      : out std_logic_vector(31 downto 0);
        quant_thr_1           : out std_logic_vector(15 downto 0);
        quant_thr_2           : out std_logic_vector(15 downto 0);
        quant_thr_3           : out std_logic_vector(15 downto 0);

        ---------------------------------------------------------------------
        -- NEW: demod control outputs (rx_top -> msk_demodulator)
        -- These carry ports rx_top previously tied off as constants.
        ---------------------------------------------------------------------
        demod_init            : out std_logic;
        lpf_freeze            : out std_logic;
        lpf_zero              : out std_logic;
        rx_enable             : out std_logic;
        rx_sample_discard     : out std_logic_vector(7 downto 0);

        ---------------------------------------------------------------------
        -- Inputs from rx_top (status / telemetry)
        ---------------------------------------------------------------------
        frame_sync_locked : in  std_logic;
        frames_received   : in  std_logic_vector(31 downto 0);
        cst_lock_f1       : in  std_logic;
        cst_lock_f2       : in  std_logic;
        gain_current      : in  std_logic_vector(15 downto 0);

        ---------------------------------------------------------------------
        -- NEW: demod loop telemetry inputs (rx_top <- msk_demodulator)
        ---------------------------------------------------------------------
        f1_nco_adjust     : in  std_logic_vector(31 downto 0);
        f2_nco_adjust     : in  std_logic_vector(31 downto 0);
        f1_error          : in  std_logic_vector(31 downto 0);
        f2_error          : in  std_logic_vector(31 downto 0);
        lpf_accum_f1      : in  std_logic_vector(31 downto 0);
        lpf_accum_f2      : in  std_logic_vector(31 downto 0);
        cst_lock_time_f1  : in  std_logic_vector(15 downto 0);
        cst_lock_time_f2  : in  std_logic_vector(15 downto 0);
        cst_unlock_f1     : in  std_logic;
        cst_unlock_f2     : in  std_logic;
        cst_acc_i_f1      : in  std_logic_vector(31 downto 0);
        cst_acc_q_f1      : in  std_logic_vector(31 downto 0);
        cst_iq_delta_f1   : in  std_logic_vector(31 downto 0)
    );
end entity haifuraiya_demod_regs;

architecture rtl of haifuraiya_demod_regs is

    ---------------------------------------------------------------------------
    -- Internal mirrors of AXI handshake out-ports (read back within the
    -- architecture; the 'out' ports are driven from these below).
    ---------------------------------------------------------------------------
    signal s_axi_awready_int : std_logic;
    signal s_axi_wready_int  : std_logic;
    signal s_axi_arready_int : std_logic;

    ---------------------------------------------------------------------------
    -- Register storage -- reset values are the proven sim config
    ---------------------------------------------------------------------------
    signal reg_rx_invert          : std_logic                     := '1';
    signal reg_freq_word_f1       : std_logic_vector(31 downto 0)  := x"FA732DF5";  -- complex lower
    signal reg_freq_word_f2       : std_logic_vector(31 downto 0)  := x"058CD20B";  -- complex upper
    signal reg_lpf_p_gain         : std_logic_vector(23 downto 0)  := x"7FFFFF";
    signal reg_lpf_i_gain         : std_logic_vector(23 downto 0)  := x"7FFFFF";
    signal reg_lpf_alpha          : std_logic_vector(23 downto 0)  := x"000000";
    signal reg_lpf_p_shift        : std_logic_vector(7 downto 0)   := x"14";        -- 20
    signal reg_lpf_i_shift        : std_logic_vector(7 downto 0)   := x"1D";        -- 29
    signal reg_sym_lock_count     : std_logic_vector(9 downto 0)   := "0010000000"; -- 128
    signal reg_sym_lock_threshold : std_logic_vector(15 downto 0)  := x"0008";      -- 8
    signal reg_gain_manual        : std_logic_vector(15 downto 0)  := x"0400";      -- 1024
    signal reg_fs_hunt_thresh     : std_logic_vector(31 downto 0) := x"00009470";   -- 38000
    signal reg_fs_verify_thresh   : std_logic_vector(31 downto 0) := x"00005DC0";   -- 24000
    signal reg_quant_thr_1        : std_logic_vector(15 downto 0) := x"01F4";       -- 500
    signal reg_quant_thr_2        : std_logic_vector(15 downto 0) := x"0578";       -- 1400
    signal reg_quant_thr_3        : std_logic_vector(15 downto 0) := x"0AF8";       -- 2800

    -- NEW: demod control-plane storage
    signal reg_demod_init         : std_logic                    := '0';
    signal reg_lpf_freeze         : std_logic                    := '0';
    signal reg_lpf_zero           : std_logic                    := '0';
    signal reg_rx_enable          : std_logic                    := '1';  -- run by default
    signal reg_rx_sample_discard  : std_logic_vector(7 downto 0) := x"00";

    ---------------------------------------------------------------------------
    -- Address constants
    ---------------------------------------------------------------------------
    constant ADDR_VERSION          : std_logic_vector(11 downto 0) := x"000";
    constant ADDR_CONTROL          : std_logic_vector(11 downto 0) := x"004";
    constant ADDR_FREQ_F1          : std_logic_vector(11 downto 0) := x"008";
    constant ADDR_FREQ_F2          : std_logic_vector(11 downto 0) := x"00C";
    constant ADDR_LPF_P_GAIN       : std_logic_vector(11 downto 0) := x"010";
    constant ADDR_LPF_I_GAIN       : std_logic_vector(11 downto 0) := x"014";
    constant ADDR_LPF_ALPHA        : std_logic_vector(11 downto 0) := x"018";
    constant ADDR_LPF_P_SHIFT      : std_logic_vector(11 downto 0) := x"01C";
    constant ADDR_LPF_I_SHIFT      : std_logic_vector(11 downto 0) := x"020";
    constant ADDR_SYM_CNT          : std_logic_vector(11 downto 0) := x"024";
    constant ADDR_SYM_THR          : std_logic_vector(11 downto 0) := x"028";
    constant ADDR_GAIN_MANUAL      : std_logic_vector(11 downto 0) := x"030";
    constant ADDR_GAIN_CURRENT     : std_logic_vector(11 downto 0) := x"038";
    constant ADDR_STATUS           : std_logic_vector(11 downto 0) := x"040";
    constant ADDR_FRAMES_RX        : std_logic_vector(11 downto 0) := x"044";
    constant ADDR_FS_HUNT_THRESH   : std_logic_vector(11 downto 0) := x"048";
    constant ADDR_FS_VERIFY_THRESH : std_logic_vector(11 downto 0) := x"04C";
    constant ADDR_QUANT_THR_1      : std_logic_vector(11 downto 0) := x"050";
    constant ADDR_QUANT_THR_2      : std_logic_vector(11 downto 0) := x"054";
    constant ADDR_QUANT_THR_3      : std_logic_vector(11 downto 0) := x"058";
    -- NEW: demod control
    constant ADDR_DEMOD_INIT       : std_logic_vector(11 downto 0) := x"05C";
    constant ADDR_LOOP_CTRL        : std_logic_vector(11 downto 0) := x"060";
    constant ADDR_RX_SAMPLE_DISCARD: std_logic_vector(11 downto 0) := x"064";
    -- NEW: demod telemetry (read-only)
    constant ADDR_F1_NCO_ADJUST    : std_logic_vector(11 downto 0) := x"068";
    constant ADDR_F2_NCO_ADJUST    : std_logic_vector(11 downto 0) := x"06C";
    constant ADDR_F1_ERROR         : std_logic_vector(11 downto 0) := x"070";
    constant ADDR_F2_ERROR         : std_logic_vector(11 downto 0) := x"074";
    constant ADDR_LPF_ACCUM_F1     : std_logic_vector(11 downto 0) := x"078";
    constant ADDR_LPF_ACCUM_F2     : std_logic_vector(11 downto 0) := x"07C";
    constant ADDR_CST_LOCKTIME_F1  : std_logic_vector(11 downto 0) := x"080";
    constant ADDR_CST_LOCKTIME_F2  : std_logic_vector(11 downto 0) := x"084";
    constant ADDR_LOCK_STATUS      : std_logic_vector(11 downto 0) := x"088";
    constant ADDR_CST_ACC_I_F1     : std_logic_vector(11 downto 0) := x"08C";
    constant ADDR_CST_ACC_Q_F1     : std_logic_vector(11 downto 0) := x"090";
    constant ADDR_CST_IQ_DELTA_F1  : std_logic_vector(11 downto 0) := x"094";

    -- VERSION fixed value: {major, minor, patch, 0x00}
    constant VERSION_WORD : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(VERSION_MAJOR, 8)) &
        std_logic_vector(to_unsigned(VERSION_MINOR, 8)) &
        std_logic_vector(to_unsigned(VERSION_PATCH, 8)) &
        x"00";

    ---------------------------------------------------------------------------
    -- AXI write FSM
    ---------------------------------------------------------------------------
    type write_state_t is (W_IDLE, W_RESP);
    signal w_state        : write_state_t := W_IDLE;
    signal latched_awaddr : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal aw_handshake   : std_logic;
    signal w_handshake    : std_logic;

    ---------------------------------------------------------------------------
    -- AXI read FSM
    ---------------------------------------------------------------------------
    type read_state_t is (R_IDLE, R_RESP);
    signal r_state        : read_state_t := R_IDLE;
    signal latched_araddr : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal r_data_int     : std_logic_vector(31 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Drive control outputs
    ---------------------------------------------------------------------------
    rx_invert             <= reg_rx_invert;
    rx_freq_word_f1       <= reg_freq_word_f1;
    rx_freq_word_f2       <= reg_freq_word_f2;
    lpf_p_gain            <= reg_lpf_p_gain;
    lpf_i_gain            <= reg_lpf_i_gain;
    lpf_alpha             <= reg_lpf_alpha;
    lpf_p_shift           <= reg_lpf_p_shift;
    lpf_i_shift           <= reg_lpf_i_shift;
    symbol_lock_count     <= reg_sym_lock_count;
    symbol_lock_threshold <= reg_sym_lock_threshold;
    gain_manual           <= reg_gain_manual;
    fs_hunt_thresh        <= reg_fs_hunt_thresh;
    fs_verify_thresh      <= reg_fs_verify_thresh;
    quant_thr_1           <= reg_quant_thr_1;
    quant_thr_2           <= reg_quant_thr_2;
    quant_thr_3           <= reg_quant_thr_3;

    -- NEW: demod control-plane outputs
    demod_init            <= reg_demod_init;
    lpf_freeze            <= reg_lpf_freeze;
    lpf_zero              <= reg_lpf_zero;
    rx_enable             <= reg_rx_enable;
    rx_sample_discard     <= reg_rx_sample_discard;

    ---------------------------------------------------------------------------
    -- WRITE PATH
    ---------------------------------------------------------------------------
    s_axi_awready <= s_axi_awready_int;
    s_axi_wready  <= s_axi_wready_int;
    s_axi_arready <= s_axi_arready_int;

    aw_handshake <= s_axi_awvalid and s_axi_awready_int;
    w_handshake  <= s_axi_wvalid  and s_axi_wready_int;

    p_write : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                w_state                <= W_IDLE;
                latched_awaddr         <= (others => '0');
                s_axi_awready_int      <= '0';
                s_axi_wready_int       <= '0';
                s_axi_bvalid           <= '0';
                s_axi_bresp            <= "00";
                reg_rx_invert          <= '1';
                reg_freq_word_f1       <= x"FA732DF5";
                reg_freq_word_f2       <= x"058CD20B";
                reg_lpf_p_gain         <= x"7FFFFF";
                reg_lpf_i_gain         <= x"7FFFFF";
                reg_lpf_alpha          <= x"000000";
                reg_lpf_p_shift        <= x"14";
                reg_lpf_i_shift        <= x"1D";
                reg_sym_lock_count     <= "0010000000";
                reg_sym_lock_threshold <= x"0008";
                reg_gain_manual        <= x"0C00";
                reg_fs_hunt_thresh     <= x"00009470";
                reg_fs_verify_thresh   <= x"00005DC0";   -- 24000
                reg_quant_thr_1        <= x"01F4";       -- 500
                reg_quant_thr_2        <= x"0578";       -- 1400
                reg_quant_thr_3        <= x"0AF8";       -- 2800
                -- NEW: demod control plane resets
                reg_demod_init         <= '0';
                reg_lpf_freeze         <= '0';
                reg_lpf_zero           <= '0';
                reg_rx_enable          <= '1';
                reg_rx_sample_discard  <= x"00";

            else
                case w_state is
                when W_IDLE =>
                    s_axi_awready_int <= '1';
                    s_axi_wready_int  <= '1';
                    s_axi_bvalid      <= '0';

                    if aw_handshake = '1' then
                        latched_awaddr <= s_axi_awaddr;
                    end if;

                    -- Commit when both AW and W are valid this cycle (PS
                    -- gives both simultaneously; same simplification as the
                    -- channelizer's slave).
                    if aw_handshake = '1' and w_handshake = '1' then
                        case s_axi_awaddr is
                            when ADDR_CONTROL =>
                                reg_rx_invert <= s_axi_wdata(0);
                            when ADDR_FREQ_F1 =>
                                reg_freq_word_f1 <= s_axi_wdata;
                            when ADDR_FREQ_F2 =>
                                reg_freq_word_f2 <= s_axi_wdata;
                            when ADDR_LPF_P_GAIN =>
                                reg_lpf_p_gain <= s_axi_wdata(23 downto 0);
                            when ADDR_LPF_I_GAIN =>
                                reg_lpf_i_gain <= s_axi_wdata(23 downto 0);
                            when ADDR_LPF_ALPHA =>
                                reg_lpf_alpha <= s_axi_wdata(23 downto 0);
                            when ADDR_LPF_P_SHIFT =>
                                reg_lpf_p_shift <= s_axi_wdata(7 downto 0);
                            when ADDR_LPF_I_SHIFT =>
                                reg_lpf_i_shift <= s_axi_wdata(7 downto 0);
                            when ADDR_SYM_CNT =>
                                reg_sym_lock_count <= s_axi_wdata(9 downto 0);
                            when ADDR_SYM_THR =>
                                reg_sym_lock_threshold <= s_axi_wdata(15 downto 0);
                            when ADDR_GAIN_MANUAL =>
                                reg_gain_manual <= s_axi_wdata(15 downto 0);
                            when ADDR_FS_HUNT_THRESH =>
                                reg_fs_hunt_thresh <= s_axi_wdata(31 downto 0);
                            when ADDR_FS_VERIFY_THRESH =>
                                reg_fs_verify_thresh <= s_axi_wdata(31 downto 0);
                            when ADDR_QUANT_THR_1 =>
                                reg_quant_thr_1 <= s_axi_wdata(15 downto 0);
                            when ADDR_QUANT_THR_2 =>
                                reg_quant_thr_2 <= s_axi_wdata(15 downto 0);
                            when ADDR_QUANT_THR_3 =>
                                reg_quant_thr_3 <= s_axi_wdata(15 downto 0);
                            -- NEW: demod control plane writes
                            when ADDR_DEMOD_INIT =>
                                reg_demod_init <= s_axi_wdata(0);
                            when ADDR_LOOP_CTRL =>
                                reg_lpf_freeze <= s_axi_wdata(0);
                                reg_lpf_zero   <= s_axi_wdata(1);
                                reg_rx_enable  <= s_axi_wdata(2);
                            when ADDR_RX_SAMPLE_DISCARD =>
                                reg_rx_sample_discard <= s_axi_wdata(7 downto 0);
                            when others =>
                                null;  -- writes to RO addresses ignored
                        end case;

                        s_axi_awready_int <= '0';
                        s_axi_wready_int  <= '0';
                        s_axi_bresp       <= "00";  -- OKAY
                        s_axi_bvalid      <= '1';
                        w_state           <= W_RESP;
                    end if;

                when W_RESP =>
                    if s_axi_bready = '1' then
                        s_axi_bvalid      <= '0';
                        s_axi_awready_int <= '1';
                        s_axi_wready_int  <= '1';
                        w_state           <= W_IDLE;
                    end if;

                end case;
            end if;
        end if;
    end process p_write;

    ---------------------------------------------------------------------------
    -- READ PATH
    ---------------------------------------------------------------------------
    p_read : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                r_state           <= R_IDLE;
                s_axi_arready_int <= '0';
                s_axi_rvalid      <= '0';
                s_axi_rresp       <= "00";
                r_data_int        <= (others => '0');
                latched_araddr    <= (others => '0');
            else
                case r_state is
                when R_IDLE =>
                    s_axi_arready_int <= '1';
                    s_axi_rvalid      <= '0';

                    if s_axi_arvalid = '1' and s_axi_arready_int = '1' then
                        latched_araddr    <= s_axi_araddr;
                        s_axi_arready_int <= '0';

                        case s_axi_araddr is
                            when ADDR_VERSION =>
                                r_data_int <= VERSION_WORD;
                            when ADDR_CONTROL =>
                                r_data_int    <= (others => '0');
                                r_data_int(0) <= reg_rx_invert;
                            when ADDR_FREQ_F1 =>
                                r_data_int <= reg_freq_word_f1;
                            when ADDR_FREQ_F2 =>
                                r_data_int <= reg_freq_word_f2;
                            when ADDR_LPF_P_GAIN =>
                                r_data_int <= (others => '0');
                                r_data_int(23 downto 0) <= reg_lpf_p_gain;
                            when ADDR_LPF_I_GAIN =>
                                r_data_int <= (others => '0');
                                r_data_int(23 downto 0) <= reg_lpf_i_gain;
                            when ADDR_LPF_ALPHA =>
                                r_data_int <= (others => '0');
                                r_data_int(23 downto 0) <= reg_lpf_alpha;
                            when ADDR_LPF_P_SHIFT =>
                                r_data_int <= (others => '0');
                                r_data_int(7 downto 0) <= reg_lpf_p_shift;
                            when ADDR_LPF_I_SHIFT =>
                                r_data_int <= (others => '0');
                                r_data_int(7 downto 0) <= reg_lpf_i_shift;
                            when ADDR_SYM_CNT =>
                                r_data_int <= (others => '0');
                                r_data_int(9 downto 0) <= reg_sym_lock_count;
                            when ADDR_SYM_THR =>
                                r_data_int <= (others => '0');
                                r_data_int(15 downto 0) <= reg_sym_lock_threshold;
                            when ADDR_STATUS =>
                                r_data_int    <= (others => '0');
                                r_data_int(0) <= frame_sync_locked;
                                r_data_int(1) <= cst_lock_f1;
                                r_data_int(2) <= cst_lock_f2;
                            when ADDR_FRAMES_RX =>
                                r_data_int <= frames_received;
                            when ADDR_GAIN_MANUAL =>
                                r_data_int <= x"0000" & reg_gain_manual;
                            when ADDR_GAIN_CURRENT =>
                                r_data_int <= x"0000" & gain_current;
                            when ADDR_FS_HUNT_THRESH =>
                                r_data_int <= reg_fs_hunt_thresh;
                            when ADDR_FS_VERIFY_THRESH =>
                                r_data_int <= reg_fs_verify_thresh;
                            when ADDR_QUANT_THR_1 =>
                                r_data_int <= x"0000" & reg_quant_thr_1;
                            when ADDR_QUANT_THR_2 =>
                                r_data_int <= x"0000" & reg_quant_thr_2;
                            when ADDR_QUANT_THR_3 =>
                                r_data_int <= x"0000" & reg_quant_thr_3;
                            -- NEW: demod control-plane readback
                            when ADDR_DEMOD_INIT =>
                                r_data_int    <= (others => '0');
                                r_data_int(0) <= reg_demod_init;
                            when ADDR_LOOP_CTRL =>
                                r_data_int    <= (others => '0');
                                r_data_int(0) <= reg_lpf_freeze;
                                r_data_int(1) <= reg_lpf_zero;
                                r_data_int(2) <= reg_rx_enable;
                            when ADDR_RX_SAMPLE_DISCARD =>
                                r_data_int <= (others => '0');
                                r_data_int(7 downto 0) <= reg_rx_sample_discard;
                            -- NEW: demod telemetry (live, read-only)
                            when ADDR_F1_NCO_ADJUST =>
                                r_data_int <= f1_nco_adjust;
                            when ADDR_F2_NCO_ADJUST =>
                                r_data_int <= f2_nco_adjust;
                            when ADDR_F1_ERROR =>
                                r_data_int <= f1_error;
                            when ADDR_F2_ERROR =>
                                r_data_int <= f2_error;
                            when ADDR_LPF_ACCUM_F1 =>
                                r_data_int <= lpf_accum_f1;
                            when ADDR_LPF_ACCUM_F2 =>
                                r_data_int <= lpf_accum_f2;
                            when ADDR_CST_LOCKTIME_F1 =>
                                r_data_int <= x"0000" & cst_lock_time_f1;
                            when ADDR_CST_LOCKTIME_F2 =>
                                r_data_int <= x"0000" & cst_lock_time_f2;
                            when ADDR_LOCK_STATUS =>
                                r_data_int    <= (others => '0');
                                r_data_int(0) <= cst_lock_f1;
                                r_data_int(1) <= cst_lock_f2;
                                r_data_int(2) <= cst_unlock_f1;
                                r_data_int(3) <= cst_unlock_f2;
                            when ADDR_CST_ACC_I_F1 =>
                                r_data_int <= cst_acc_i_f1;
                            when ADDR_CST_ACC_Q_F1 =>
                                r_data_int <= cst_acc_q_f1;
                            when ADDR_CST_IQ_DELTA_F1 =>
                                r_data_int <= cst_iq_delta_f1;
                            when others =>
                                r_data_int <= (others => '0');
                        end case;

                        s_axi_rvalid <= '1';
                        s_axi_rresp  <= "00";
                        r_state      <= R_RESP;
                    end if;

                when R_RESP =>
                    if s_axi_rready = '1' then
                        s_axi_rvalid      <= '0';
                        s_axi_arready_int <= '1';
                        r_state           <= R_IDLE;
                    end if;

                end case;
            end if;
        end if;
    end process p_read;

    s_axi_rdata <= r_data_int;

end architecture rtl;
