-------------------------------------------------------------------------------
-- This is free and unencumbered software released into the public domain.
--
-- Anyone is free to copy, modify, publish, use, compile, sell, or distribute
-- this software, either in source code form or as a compiled bitstream, for 
-- any purpose, commercial or non-commercial, and by any means.
--
-- In jurisdictions that recognize copyright laws, the author or authors of 
-- this software dedicate any and all copyright interest in the software to 
-- the public domain. We make this dedication for the benefit of the public at
-- large and to the detriment of our heirs and successors. We intend this 
-- dedication to be an overt act of relinquishment in perpetuity of all present
-- and future rights to this software under copyright law.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
-- ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- THIS DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES. 
-------------------------------------------------------------------------------
-- Version      Date            Author       Description
-- 1.0          2019            Teledyne e2v Creation
-- 1.1          2019            REFLEXCES    FPGA target migration, 64-bit data path
-------------------------------------------------------------------------------

library work;
use work.esistream_pkg.all;

library IEEE;
use ieee.std_logic_1164.all;
use IEEE.numeric_std.all;
use ieee.math_real.all;

library UNISIM;
use UNISIM.VComponents.all;

entity tx_rx_esistream_top is
  generic(
    GEN_ESISTREAM          : boolean                       := true;
    GEN_GPIO               : boolean                       := false;
    NB_LANES               : integer                       := 8;
    RST_CNTR_INIT          : std_logic_vector(11 downto 0) := x"FFF";
    NB_CLK_CYC             : std_logic_vector(31 downto 0) := x"00FFFFFF";
    CLK_MHz                : real                          := 100.0;
    SPI_CLK_MHz            : real                          := 5.0;
    SYNCTRIG_PULSE_WIDTH   : integer                       := 7;
    SYNCTRIG_MAX_DELAY     : integer                       := 16;
    SYNCTRIG_COUNTER_WIDTH : integer                       := 8;
    FIFO_DATA_WIDTH        : integer                       := 24;
    FIFO_DEPTH             : integer                       := 8
    );
  port (
    --
    HSDP_SI570_CLK_C_P     : in  std_logic;                     -- J39 156.25 MHz
    HSDP_SI570_CLK_C_N     : in  std_logic;                     -- J40
    --
    GPIO_LED               : out std_logic_vector(3 downto 0);  -- Bank 306 1.8V, L35, K36, J33, H34 
    GPIO_SW                : in  std_logic_vector(3 downto 0);  -- Bank 306 1.8V, H36, H37, J34, J35
    GPIO_PB                : in  std_logic_vector(1 downto 0);  -- Bank 306 1.8V, G36, G37
    UART1_TXD_HDIO_UART_RX : in  std_logic;                     -- Bank 306 1.8V, K33
    UART1_RXD_HDIO_UART_TX : out std_logic;                     -- Bank 306 1.8V, L33
    --
    sso_n                  : in  std_logic;                     -- FMCP1 J51D GBTCLK0_M2C_P - GTY_REFCLKP1_201_M15
    sso_p                  : in  std_logic;                     -- FMCP1 J51D GBTCLK0_M2C_N - GTY_REFCLKN1_201_M14
    rxp                    : in  std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
    rxn                    : in  std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
    txp                    : out std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
    txn                    : out std_logic_vector(NB_LANES-1 downto 0) := (others => '0')
    );
end entity tx_rx_esistream_top;

architecture rtl of tx_rx_esistream_top is
  --------------------------------------------
  -- TX 
  --------------------------------------------
  -- --
  -- FMCP1_DP0_C2M_P - GTY_TXP0_201_AB7 
  -- FMCP1_DP0_C2M_N - GTY_TXP0_201_AB6
  -- --      
  -- FMCP1_DP1_C2M_P - GTY_TXP1_201_AA9 
  -- FMCP1_DP1_C2M_N - GTY_TXP1_201_AA8
  -- --        
  -- FMCP1_DP2_C2M_P - GTY_TXP2_201_Y7
  -- FMCP1_DP2_C2M_N - GTY_TXP2_201_Y6
  -- --        
  -- FMCP1_DP3_C2M_P - GTY_TXP3_201_W9 
  -- FMCP1_DP3_C2M_N - GTY_TXP3_201_W8
  -- -- --    
  -- FMCP1_DP4_C2M_P - GTY_TXP4_201_V7 
  -- FMCP1_DP4_C2M_N - GTY_TXP4_201_V6
  -- --       
  -- FMCP1_DP5_C2M_P - GTY_TXP5_201_U9 
  -- FMCP1_DP5_C2M_N - GTY_TXP5_201_U8
  -- --     
  -- FMCP1_DP6_C2M_P - GTY_TXP6_201_T7 
  -- FMCP1_DP6_C2M_N - GTY_TXP6_201_T6
  -- --                   
  -- FMCP1_DP7_C2M_P - GTY_TXP7_201_R9 
  -- FMCP1_DP7_C2M_N - GTY_TXP7_201_R8
  --------------------------------------------
  -- RX 
  --------------------------------------------
  -- --
  -- FMCP1_DP0_M2C_P - GTY_RXP0_201_AB2 
  -- FMCP1_DP0_M2C_N - GTY_RXP0_201_AB1
  -- --                        
  -- FMCP1_DP1_M2C_P - GTY_RXP1_201_AA4 
  -- FMCP1_DP1_M2C_N - GTY_RXP1_201_AA3
  -- --                        
  -- FMCP1_DP2_M2C_P - GTY_RXP2_201_Y2 
  -- FMCP1_DP2_M2C_N - GTY_RXP2_201_Y1
  -- --                        
  -- FMCP1_DP3_M2C_P - GTY_RXP3_201_W4 
  -- FMCP1_DP3_M2C_N - GTY_RXP3_201_W3
  -- -- --                     
  -- FMCP1_DP4_M2C_P - GTY_RXP4_201_V2 
  -- FMCP1_DP4_M2C_N - GTY_RXP4_201_V1
  -- --                        
  -- FMCP1_DP5_M2C_P - GTY_RXP5_201_U4 
  -- FMCP1_DP5_M2C_N - GTY_RXP5_201_U3
  -- --                        
  -- FMCP1_DP6_M2C_P - GTY_RXP6_201_T2 
  -- FMCP1_DP6_M2C_N - GTY_RXP6_201_T1
  -- --                        
  -- FMCP1_DP7_M2C_P - GTY_RXP7_201_R4 
  -- FMCP1_DP7_M2C_N - GTY_RXP7_201_R3
  -- --
  --------------------------------------------------------------------------------------------------------------------
  --! signal name description:
  -- _sr = _shift_register
  -- _re = _rising_edge (one clk period pulse generated on the rising edge of the initial signal)
  -- _fe = _falling_edge (one clk period pulse generated on the falling edge of the initial signal)
  -- _d  = _delay
  -- _2d = _delay x2
  -- _ba = _bitwise_and
  -- _sw = _slide_window
  -- _o  = _output
  -- _i  = _input
  -- _t  = _temporary or _tristate pin (OBUFT)
  -- _a  = _asychronous (fsm output decode signal)
  -- _s  = _synchronous (fsm synchronous output signal)
  -- _rs = _resynchronized (when there is a clock domain crossing)
  --------------------------------------------------------------------------------------------------------------------
  attribute keep                         : string;
  --constant NB_LANES             : natural                               := 8;
  constant ALL_LANES_ON                  : std_logic_vector(NB_LANES-1 downto 0) := (others => '1');
  constant ALL_LANES_OFF                 : std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
  signal sysclk                          : std_logic                             := '0';
  signal sysclk_odiv2                    : std_logic                             := '0';
  signal sysclk_100                      : std_logic                             := '0';
  signal sysclk_200                      : std_logic                             := '0';
  signal syslock                         : std_logic                             := '0';
  signal pcie_clk0                       : std_logic;
  signal pcie_clk0_odiv2                 : std_logic;
  signal rx_clk                          : std_logic                             := '0';
  attribute keep of rx_clk               : signal is "true";
  signal tx_clk                          : std_logic                             := '0';
  attribute keep of tx_clk               : signal is "true";
  signal reg_rst                         : std_logic                             := '0';
  signal reg_rst_check                   : std_logic                             := '0';
  signal pb_rst                          : std_logic                             := '0';
  signal rst                             : std_logic                             := '0';
  signal rst_re                          : std_logic                             := '0';
  signal rst_check                       : std_logic                             := '0';
  signal rst_check_rs                    : std_logic                             := '0';
  signal rst_check_re                    : std_logic                             := '0';
  signal sync_in                         : std_logic                             := '0';
  signal sync_in_rs                      : std_logic                             := '0';
  signal sync_in_re                      : std_logic                             := '0';
  signal synctrig                        : std_logic                             := '0';
  signal synctrig_odelay                 : std_logic                             := '0';
  signal synctrig_re                     : std_logic                             := '0';
  signal rx_sync_in                      : std_logic                             := '0';
  signal rx_ip_ready                     : std_logic                             := '0';
  signal rx_lanes_on                     : std_logic_vector(NB_LANES-1 downto 0) := (others => '1');
  signal rx_lanes_ready                  : std_logic                             := '0';
  signal rx_release_data                 : std_logic                             := '0';
  signal rx_prbs_en                      : std_logic                             := '1';
  signal tx_sync_in                      : std_logic                             := '0';
  signal tx_prbs_en                      : std_logic                             := '1';
  signal tx_disp_en                      : std_logic                             := '1';
  signal tx_lfsr_init                    : slv_17_array_n(NB_LANES-1 downto 0)   := (others => (others => '1'));
  signal tx_data_in                      : tx_data_array(NB_LANES-1 downto 0)    := (others => (others => (others => '0')));
  signal tx_ip_ready                     : std_logic                             := '0';
  signal tx_emu_d_ctrl                   : std_logic_vector(1 downto 0)          := "00";
  signal dsw_tx_emu_d_ctrl               : std_logic_vector(1 downto 0)          := "00";
  signal dsw_prbs_en                     : std_logic                             := '1';
  signal dsw_disp_en                     : std_logic                             := '1';
  --
  signal sync_set_odelay                 : std_logic                             := '0';
  signal sync_odelay_i                   : std_logic_vector(8 downto 0)          := (others => '0');
  signal sync_get_odelay                 : std_logic                             := '0';
  signal sync_odelay_o                   : std_logic_vector(8 downto 0)          := (others => '0');
  --
  signal fifo_dout                       : data_array(NB_LANES-1 downto 0);
  signal fifo_rd_en                      : std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
  signal fifo_empty                      : std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
  --
  signal be_status                       : std_logic                             := '0';
  signal cb_status                       : std_logic                             := '0';
  signal valid_status                    : std_logic                             := '0';
  --
  signal aq600_prbs_en                   : std_logic                             := '1';
  signal s_reset_i                       : std_logic                             := '0';
  signal s_resetn_i                      : std_logic                             := '0';
  signal s_resetn_re                     : std_logic                             := '0';
  signal rx_rst                          : std_logic                             := '0';
  signal rx_nrst                         : std_logic                             := '1';
  signal rx_sync_rst                     : std_logic                             := '0';
  signal rx_sync_rst_rs                  : std_logic                             := '0';
  signal rx_sync_rst_re                  : std_logic                             := '0';
  signal reg_aq600_rstn                  : std_logic;
  --
  signal data_out_12b                    : rx_data_array_12b(NB_LANES-1 downto 0);
  --
  signal frame_out                       : rx_frame_array(NB_LANES-1 downto 0);
  signal frame_out_d                     : rx_frame_array(NB_LANES-1 downto 0);
  signal valid_out                       : std_logic_vector(NB_LANES-1 downto 0) := (others => '0');
  --
  signal m_axi_addr                      : std_logic_vector(3 downto 0)          := (others => '0');
  signal m_axi_strb                      : std_logic_vector(3 downto 0)          := (others => '0');
  signal m_axi_wdata                     : std_logic_vector(31 downto 0)         := (others => '0');
  signal m_axi_rdata                     : std_logic_vector(31 downto 0)         := (others => '0');
  signal m_axi_wen                       : std_logic                             := '0';
  signal m_axi_ren                       : std_logic                             := '0';
  signal m_axi_busy                      : std_logic                             := '0';
  signal s_interrupt                     : std_logic                             := '0';
  --
  signal reg_0                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_1                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_2                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_3                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_4                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_5                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_6                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_7                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_8                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_9                           : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_10                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_11                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_12                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_13                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_14                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_15                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_16                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_17                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_18                          : std_logic_vector(31 downto 0)         := (others => '0');
  signal reg_19                          : std_logic_vector(31 downto 0)         := (others => '0');
  --
  signal spi_ss                          : std_logic;
  signal spi_start                       : std_logic;
  signal spi_start_re                    : std_logic;
  signal fifo_in_wr_en                   : std_logic;
  signal fifo_in_din                     : std_logic_vector(FIFO_DATA_WIDTH-1 downto 0);
  signal fifo_in_full                    : std_logic;
  signal fifo_out_rd_en                  : std_logic;
  signal fifo_out_dout                   : std_logic_vector(FIFO_DATA_WIDTH-1 downto 0);
  signal fifo_out_empty                  : std_logic;
--
  signal sync_rst                        : std_logic                             := '0';
  signal sync_delay                      : std_logic_vector(integer(floor(log2(real(SYNCTRIG_MAX_DELAY-1)))) downto 0);
  signal sync_mode                       : std_logic;
  signal sync_en                         : std_logic;
  signal sync_wr_en                      : std_logic;
  signal sync_wr_counter                 : std_logic_vector(SYNCTRIG_COUNTER_WIDTH-1 downto 0);
  signal sync_rd_counter                 : std_logic_vector(SYNCTRIG_COUNTER_WIDTH-1 downto 0);
  signal sync_counter_busy               : std_logic;
  signal sync_counter_busy_rs            : std_logic;
  signal send_sync                       : std_logic;
  signal send_sync_rs                    : std_logic;
  signal sync_wr_en_rs                   : std_logic;
  signal manual_mode                     : std_logic;
  signal manual_mode_rs                  : std_logic;
  --
  signal uart_ready                      : std_logic                             := '0';
  --
  signal reg_4_os                        : std_logic                             := '0';
  signal reg_5_os                        : std_logic                             := '0';
  signal reg_6_os                        : std_logic                             := '0';
  signal reg_7_os                        : std_logic                             := '0';
  signal reg_10_os                       : std_logic                             := '0';
  signal reg_12_os                       : std_logic                             := '0';
--
  attribute MARK_DEBUG                   : string;
  attribute MARK_DEBUG of rx_sync_in     : signal is "true";
  attribute MARK_DEBUG of rx_ip_ready    : signal is "true";
  attribute MARK_DEBUG of rx_lanes_ready : signal is "true";
  attribute MARK_DEBUG of cb_status      : signal is "true";
  attribute MARK_DEBUG of be_status      : signal is "true";
  attribute MARK_DEBUG of data_out_12b   : signal is "true";
  attribute MARK_DEBUG of valid_out      : signal is "true";
--
begin
  --
  --------------------------------------------------------------------------------------------
  -- Versal CIPS
  --------------------------------------------------------------------------------------------
  -- Versal designs must contain a CIPS IP in the netlist hierarchy to function properly.
  edt_versal_wrapper_1: entity work.edt_versal_wrapper;
  --------------------------------------------------------------------------------------------
  -- User interface:
  --------------------------------------------------------------------------------------------
  --------------------------------------------------------------------------------------------
  --  clk_out1 : 100.0MHz (must be consistent with C_SYS_CLK_PERIOD)
  --------------------------------------------------------------------------------------------
  -----------
  --
  IBUFDS_GTE3_1 : IBUFDS_GTE5
    generic map(
      REFCLK_EN_TX_PATH  => '0',  -- Reserved. This attribute must always be set to "00".
      REFCLK_HROW_CK_SEL => 0,    -- "00" : f_ODIV2 = f_O ; "01" : f_ODIV2 = f_O/2 ; "10" : ODIV2 = 0 ; "11" : reserved. 
      REFCLK_ICNTL_RX    => 0     -- Reserved. Use the recommended value from the Wizard "00".
      )
    port map(
      I     => HSDP_SI570_CLK_C_P,
      IB    => HSDP_SI570_CLK_C_N,
      CEB   => '0',
      O     => open,
      ODIV2 => sysclk_odiv2
      );
  -- @details: DIV input:
  -- Specifies the value to divide the clock. Divide value is value
  -- provided plus 1. For instance, setting "0000" will provide a divide
  -- value of 1 and "1111" will be a divide value of 8.
  BUFG_GT_1 : BUFG_GT
    generic map(
      SIM_DEVICE => "VERSAL_AI_CORE")
    port map (
      O       => sysclk,          -- 1-bit output: Buffer
      CE      => '1',             -- 1-bit input: Buffer enable
      CEMASK  => '0',             -- 1-bit input: CE Mask
      CLR     => '0',             -- 1-bit input: Asynchronous clear
      CLRMASK => '0',             -- 1-bit input: CLR Mask
      DIV     => "000",           -- 3-bit input: Dynamic divide Value
      I       => sysclk_odiv2     -- 1-bit input: Buffer
      );
  --
  i_pll_sys : entity work.clk_wizard_0
    port map (
      -- Clock out ports  
      clk_out1 => sysclk_100,
      clk_out2 => sysclk_200,
      -- Status and control signals                
      reset    => '0',
      locked   => syslock,
      -- Clock in ports
      clk_in1  => sysclk
      );

  sysreset_1 : entity work.sysreset
    generic map (
      RST_CNTR_INIT => RST_CNTR_INIT)
    port map (
      syslock => syslock,
      sysclk  => sysclk_100,
      reset   => s_reset_i,
      resetn  => s_resetn_i);

  -------------------------
  -- reset
  -------------------------
  rst       <= reg_rst or pb_rst;
  rx_rst    <= rst_re or s_reset_i;
  rx_nrst   <= not rx_rst;
  rst_check <= reg_rst_check;

  -------------------------
  -- Push buttons
  -------------------------
  sync_in              <= GPIO_PB(0);      -- '1' when pushing button else '0'.
  pb_rst               <= GPIO_PB(1);      -- '1' when pushing button else '0'.
  --                     
  -------------------------
  -- SW2 switch
  -------------------------
  dsw_tx_emu_d_ctrl(1) <= GPIO_SW(0);
  dsw_tx_emu_d_ctrl(0) <= GPIO_SW(1);
  dsw_prbs_en          <= GPIO_SW(2);
  dsw_disp_en          <= GPIO_SW(3);
  -------------------------
  -- GPIO LED
  -------------------------
  GPIO_LED(0)          <= uart_ready;
  GPIO_LED(1)          <= rx_ip_ready and tx_ip_ready;
  GPIO_LED(2)          <= rx_lanes_ready and valid_status;
  GPIO_LED(3)          <= be_status or cb_status;
  --------------------------------------------------------------------------------------------
  -- sysclk rising edge:
  --------------------------------------------------------------------------------------------
  risingedge_array_1 : entity work.risingedge_array
    generic map (
      D_WIDTH => 3)
    port map (
      rst   => s_reset_i,
      clk   => sysclk_100,
      d(0)  => rst,
      d(1)  => s_resetn_i,
      d(2)  => spi_start,
      re(0) => rst_re,
      re(1) => s_resetn_re,
      re(2) => spi_start_re);
  --------------------------------------------------------------------------------------------
  -- rx_clk rising edge from sysclk:
  --------------------------------------------------------------------------------------------
  ff_synchronizer_array_1 : entity work.ff_synchronizer_array
    generic map (
      REG_WIDTH => 6)
    port map (
      clk          => rx_clk,
      reg_async(0) => sync_in,
      reg_async(1) => rst_check,
      reg_async(2) => rx_sync_rst,
      reg_async(3) => send_sync,
      reg_async(4) => sync_wr_en,
      reg_async(5) => manual_mode,
      reg_sync(0)  => sync_in_rs,
      reg_sync(1)  => rst_check_rs,
      reg_sync(2)  => rx_sync_rst_rs,
      reg_sync(3)  => send_sync_rs,
      reg_sync(4)  => sync_wr_en_rs,
      reg_sync(5)  => manual_mode_rs);

  risingedge_array_2 : entity work.risingedge_array
    generic map (
      D_WIDTH => 3)
    port map (
      rst   => '0',
      clk   => rx_clk,
      d(0)  => sync_in_rs,
      d(1)  => rst_check_rs,
      d(2)  => rx_sync_rst_rs,
      re(0) => sync_in_re,
      re(1) => rst_check_re,
      re(2) => rx_sync_rst_re);
  --
  --------------------------------------------------------------------------------------------
  -- ESIstream RX IP
  --------------------------------------------------------------------------------------------
  gen_esistream_hdl : if GEN_ESISTREAM = true generate
    tx_rx_esistream_with_xcvr_1 : entity work.tx_rx_esistream_with_xcvr
      generic map (
        NB_LANES => NB_LANES,
        COMMA    => x"FF0000FF")
      port map (
        rst            => rx_rst,
        sysclk         => sysclk_100,
        refclk_n       => sso_n,
        refclk_p       => sso_p,
        -- TX port
        txp            => txp,
        txn            => txn,
        tx_sync_in     => tx_sync_in,
        tx_prbs_en     => tx_prbs_en,
        tx_disp_en     => tx_disp_en,
        tx_lfsr_init   => tx_lfsr_init,
        data_in        => tx_data_in,
        tx_ip_ready    => tx_ip_ready,
        tx_frame_clk   => tx_clk,
        -- RX port
        rxp            => rxp,
        rxn            => rxn,
        rx_sync_in     => rx_sync_in,
        rx_prbs_en     => rx_prbs_en,
        rx_lanes_on    => rx_lanes_on,
        rx_data_en     => rx_release_data,
        rx_frame_clk   => rx_clk,
        rx_sync_out    => open,
        frame_out      => frame_out,
        valid_out      => valid_out,
        rx_ip_ready    => rx_ip_ready,
        rx_lanes_ready => rx_lanes_ready);
  end generate gen_esistream_hdl;
  --------------------------------------------------------------------------------------------
  -- Received data check 
  --------------------------------------------------------------------------------------------
  tx_emu_data_gen_top_1 : entity work.tx_emu_data_gen_top
    generic map (
      NB_LANES => NB_LANES)
    port map (
      nrst    => rx_nrst,
      clk     => tx_clk,
      d_ctrl  => tx_emu_d_ctrl,                                  -- "00" all 0; "11" all 1; else ramp+
      tx_data => tx_data_in);
  --------------------------------------------------------------------------------------------
  -- Received data check 
  --------------------------------------------------------------------------------------------
  -- Used for ILA only to display the ramp waveform using analog view in vivado simulator:
  lanes_assign : for i in 0 to NB_LANES-1 generate
    channel_assign : for j in 0 to DESER_WIDTH/16-1 generate
      process(rx_clk)
      begin
        if rising_edge(rx_clk) then
          -- to Integrated Logic Analyzer (ILA)
          data_out_12b(i)(j) <= frame_out(i)(j)(12-1 downto 0);  -- add pipeline to meet timing constraints
          -- to txrx_frame_checking
          frame_out_d(i)(j)  <= frame_out(i)(j);                 -- add pipeline to meet timing constraints
        end if;
      end process;
    end generate channel_assign;
  end generate lanes_assign;

  txrx_frame_checking_1 : entity work.txrx_frame_checking
    generic map (
      NB_LANES => NB_LANES)
    port map (
      rst          => rst_check_rs,
      clk          => rx_clk,
      d_ctrl       => tx_emu_d_ctrl,
      lanes_on     => rx_lanes_on,
      frame_out    => frame_out,
      valid_out    => valid_out,
      be_status    => be_status,
      cb_status    => cb_status,
      valid_status => valid_status);

  --------------------------------------------------------------------------------------------
  -- SYNC generator and SYNC counter
  --------------------------------------------------------------------------------------------
  sync_generator_1 : entity work.sync_generator
    generic map (
      SYNCTRIG_PULSE_WIDTH   => SYNCTRIG_PULSE_WIDTH,
      SYNCTRIG_MAX_DELAY     => SYNCTRIG_MAX_DELAY,
      SYNCTRIG_COUNTER_WIDTH => SYNCTRIG_COUNTER_WIDTH)
    port map (
      clk          => rx_clk,
      rst          => rx_sync_rst_rs,
      sync_delay   => sync_delay,
      mode         => sync_mode,
      sync_en      => sync_en,
      lanes_ready  => rx_lanes_ready,
      release_data => rx_release_data,
      wr_en        => sync_wr_en,
      wr_counter   => sync_wr_counter,
      rd_counter   => sync_rd_counter,
      counter_busy => sync_counter_busy,
      manual_mode  => manual_mode_rs,
      send_sync    => send_sync,
      sw_sync      => sync_in_re,
      synctrig     => synctrig,
      synctrig_re  => synctrig_re);
  rx_sync_in <= synctrig_re;
  tx_sync_in <= synctrig_re;

  --------------------------------------------------------------------------------------------
  -- UART 8 bit 115200 and Register map
  --------------------------------------------------------------------------------------------
  uart_wrapper_1 : entity work.uart_wrapper
    port map (
      clk         => sysclk_100,
      rstn        => s_resetn_i,
      m_axi_addr  => m_axi_addr,
      m_axi_strb  => m_axi_strb,
      m_axi_wdata => m_axi_wdata,
      m_axi_rdata => m_axi_rdata,
      m_axi_wen   => m_axi_wen,
      m_axi_ren   => m_axi_ren,
      m_axi_busy  => m_axi_busy,
      interrupt   => s_interrupt,
      tx          => UART1_RXD_HDIO_UART_TX,
      rx          => UART1_TXD_HDIO_UART_RX);

  register_map_1 : entity work.register_map
    generic map (
      CLK_FREQUENCY_HZ => 100000000,
      TIME_US          => 1000000)
    port map (
      clk          => sysclk_100,
      rstn         => s_resetn_i,
      interrupt_en => s_resetn_re,
      m_axi_addr   => m_axi_addr,
      m_axi_strb   => m_axi_strb,
      m_axi_wdata  => m_axi_wdata,
      m_axi_rdata  => m_axi_rdata,
      m_axi_wen    => m_axi_wen,
      m_axi_ren    => m_axi_ren,
      m_axi_busy   => m_axi_busy,
      interrupt    => s_interrupt,
      uart_ready   => uart_ready,
      reg_0        => reg_0,
      reg_1        => reg_1,
      reg_2        => reg_2,
      reg_3        => reg_3,
      reg_4        => reg_4,
      reg_5        => reg_5,
      reg_6        => reg_6,
      reg_7        => reg_7,
      reg_8        => reg_8,
      reg_9        => reg_9,
      reg_10       => reg_10,
      reg_11       => reg_11,
      reg_12       => reg_12,
      reg_13       => reg_13,
      reg_14       => reg_14,
      reg_15       => reg_15,
      reg_16       => reg_16,
      reg_17       => reg_17,
      reg_18       => reg_18,
      reg_19       => reg_19,
      reg_4_os     => reg_4_os,
      reg_5_os     => reg_5_os,
      reg_6_os     => reg_6_os,
      reg_7_os     => reg_7_os,
      reg_10_os    => reg_10_os,
      reg_12_os    => reg_12_os);

  tx_emu_d_ctrl(0) <= reg_0(0) or dsw_tx_emu_d_ctrl(0);
  tx_emu_d_ctrl(1) <= reg_0(1) or dsw_tx_emu_d_ctrl(1);
  --
  rx_prbs_en       <= reg_1(0) or dsw_prbs_en;
  tx_prbs_en       <= reg_1(1) or dsw_prbs_en;
  tx_disp_en       <= reg_1(2) or dsw_disp_en;
  --
  reg_rst          <= reg_2(0);
  reg_rst_check    <= reg_2(1);
  reg_aq600_rstn   <= reg_2(2);
  rx_sync_rst      <= reg_2(3);
  --
  spi_ss           <= reg_3(0);
  spi_start        <= reg_3(1);
  --
  fifo_in_din      <= reg_4(23 downto 0);
  --
  sync_mode        <= reg_5(0);
  sync_delay       <= reg_5(7 downto 4);
  sync_en          <= reg_5_os;

  send_sync            <= reg_6(0);
  --manual_mode         <= reg_6(1);
  manual_mode          <= reg_6(1);  -- or dbg_sim;
  --
  sync_wr_counter      <= reg_7(7 downto 0);
  sync_wr_en           <= reg_7(8);
  -- firmware version --
  reg_8                <= x"00000310";
  --
  reg_9(0)             <= fifo_in_full;
  reg_9(1)             <= fifo_out_empty;
  --
  reg_10(23 downto 0)  <= fifo_out_dout;
  --
  reg_11(7 downto 0)   <= sync_rd_counter;
  reg_11(8)            <= sync_counter_busy;
  reg_11(24 downto 16) <= sync_odelay_o;
  --
  sync_get_odelay      <= reg_12(15);
  sync_odelay_i        <= reg_12(8 downto 0);
  --
  fifo_in_wr_en        <= reg_4_os;
  fifo_out_rd_en       <= reg_10_os;
  sync_set_odelay      <= reg_12_os;
  ---------------------------------
  -- Integrated Logic Analyzer:
  ---------------------------------
  axis_ila_wrapper_1: entity work.axis_ila_wrapper
    generic map (
      NB_LANES => NB_LANES)
    port map (
      clk          => rx_clk,
      data_out_12b => data_out_12b);
end architecture rtl;
