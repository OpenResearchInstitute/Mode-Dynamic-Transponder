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
--   0x040  DEMOD_STATUS         RO   bit 0: frame_sync_locked
--                                    bit 1: cst_lock_f1
--                                    bit 2: cst_lock_f2
--   0x044  FRAMES_RECEIVED      RO   frames decoded since reset
--
-------------------------------------------------------------------------------
-- IMPLEMENTATION NOTES
-------------------------------------------------------------------------------
-- Standard Xilinx-template-style two-FSM AXI-Lite slave (one FSM for the
-- write path, one for the read path). Always-ready when idle; never
-- reordered; no outstanding transactions. Identical handshake to
-- axi_lite_regs.vhd.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_demod_regs is
    generic (
        ADDR_WIDTH    : positive := 12;   -- 4 KB window
        VERSION_MAJOR : natural  := 0;
        VERSION_MINOR : natural  := 3;
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

        ---------------------------------------------------------------------
        -- Inputs from rx_top (status / telemetry)
        ---------------------------------------------------------------------
        frame_sync_locked : in  std_logic;
        frames_received   : in  std_logic_vector(31 downto 0);
        cst_lock_f1       : in  std_logic;
        cst_lock_f2       : in  std_logic
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
    signal reg_freq_word_f1       : std_logic_vector(31 downto 0)  := x"FA732DF5"; -- complex lower
    signal reg_freq_word_f2       : std_logic_vector(31 downto 0)  := x"058CD20B"; -- complex upper
    signal reg_lpf_p_gain         : std_logic_vector(23 downto 0)  := x"7FFFFF";
    signal reg_lpf_i_gain         : std_logic_vector(23 downto 0)  := x"7FFFFF";
    signal reg_lpf_alpha          : std_logic_vector(23 downto 0)  := x"000000";
    signal reg_lpf_p_shift        : std_logic_vector(7 downto 0)   := x"14";       -- 20
    signal reg_lpf_i_shift        : std_logic_vector(7 downto 0)   := x"1D";       -- 29
    signal reg_sym_lock_count     : std_logic_vector(9 downto 0)   := "0010000000"; -- 128
    signal reg_sym_lock_threshold : std_logic_vector(15 downto 0)  := x"0008";     -- 8

    ---------------------------------------------------------------------------
    -- Address constants
    ---------------------------------------------------------------------------
    constant ADDR_VERSION     : std_logic_vector(11 downto 0) := x"000";
    constant ADDR_CONTROL     : std_logic_vector(11 downto 0) := x"004";
    constant ADDR_FREQ_F1     : std_logic_vector(11 downto 0) := x"008";
    constant ADDR_FREQ_F2     : std_logic_vector(11 downto 0) := x"00C";
    constant ADDR_LPF_P_GAIN  : std_logic_vector(11 downto 0) := x"010";
    constant ADDR_LPF_I_GAIN  : std_logic_vector(11 downto 0) := x"014";
    constant ADDR_LPF_ALPHA   : std_logic_vector(11 downto 0) := x"018";
    constant ADDR_LPF_P_SHIFT : std_logic_vector(11 downto 0) := x"01C";
    constant ADDR_LPF_I_SHIFT : std_logic_vector(11 downto 0) := x"020";
    constant ADDR_SYM_CNT     : std_logic_vector(11 downto 0) := x"024";
    constant ADDR_SYM_THR     : std_logic_vector(11 downto 0) := x"028";
    constant ADDR_STATUS      : std_logic_vector(11 downto 0) := x"040";
    constant ADDR_FRAMES_RX   : std_logic_vector(11 downto 0) := x"044";

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
