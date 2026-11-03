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
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABIqLITY, 
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
-- ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- THIS DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES. 
-------------------------------------------------------------------------------
-- Version      Date            Author       Description
-- 1.1          2019            REFLEXCES    FPGA target migration, 64-bit data path
--------------------------------------------------------------------------------- 
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.esistream_pkg.all;

library unisim;
use unisim.vcomponents.all;


entity tx_rx_xcvr_wrapper is
  generic (
    NB_LANES : natural := 4
    );
  port (
    rst           : in  std_logic;
    --
    rx_frame_clk  : out std_logic                             := '0';
    rx_usrclk     : out std_logic                             := '0';
    rx_ip_ready   : out std_logic := '0';
    --
    tx_frame_clk  : out std_logic                             := '0';
    tx_usrclk     : out std_logic                             := '0';
    tx_ip_ready   : out std_logic := '0';
    --
    sysclk        : in  std_logic;
    refclk_n      : in  std_logic;
    refclk_p      : in  std_logic;
    --
    rxp           : in  std_logic_vector(NB_LANES-1 downto 0);
    rxn           : in  std_logic_vector(NB_LANES-1 downto 0);
    txp           : out std_logic_vector(NB_LANES-1 downto 0);
    txn           : out std_logic_vector(NB_LANES-1 downto 0);
    --
    data_in       : in  slv_ser_width_array_n(NB_LANES-1 downto 0);
    data_out      : out slv_deser_width_array_n(NB_LANES-1 downto 0)
    );
end entity tx_rx_xcvr_wrapper;

architecture rtl of tx_rx_xcvr_wrapper is
  --============================================================================================================================
  -- Function and Procedure declarations
  --============================================================================================================================

  --============================================================================================================================
  -- Constant and Type declarations
  --============================================================================================================================

  --============================================================================================================================
  -- Component declarations
  --============================================================================================================================

  --============================================================================================================================
  -- Signal declarations
  --============================================================================================================================
  -- transceiver signals:
  signal GT_Serial_1_grx_n                      : std_logic_vector (3 downto 0);
  signal GT_Serial_1_grx_p                      : std_logic_vector (3 downto 0);
  signal GT_Serial_1_gtx_n                      : std_logic_vector (3 downto 0);
  signal GT_Serial_1_gtx_p                      : std_logic_vector (3 downto 0);
  signal GT_Serial_grx_n                        : std_logic_vector (3 downto 0);
  signal GT_Serial_grx_p                        : std_logic_vector (3 downto 0);
  signal GT_Serial_gtx_n                        : std_logic_vector (3 downto 0);
  signal GT_Serial_gtx_p                        : std_logic_vector (3 downto 0);
  signal apb3clk_gt_bridge_ip_0                 : std_logic;
  signal apb3clk_quad                           : std_logic;
  signal ch0_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch0_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch1_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch1_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch2_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch2_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch3_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch3_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch4_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch4_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch5_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch5_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch6_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch6_txdata_ext                         : std_logic_vector (127 downto 0);
  signal ch7_rxdata_ext                         : std_logic_vector (127 downto 0);
  signal ch7_txdata_ext                         : std_logic_vector (127 downto 0);
  signal gt_bridge_ip_0_diff_gt_ref_clock_clk_n : std_logic_vector (0 to 0);
  signal gt_bridge_ip_0_diff_gt_ref_clock_clk_p : std_logic_vector (0 to 0);
  signal gt_reset_gt_bridge_ip_0                : std_logic;
  signal hsclk0_lcplllock_0                     : std_logic;
  signal hsclk0_lcplllock_1                     : std_logic;
  signal hsclk0_rplllock_0                      : std_logic;
  signal hsclk0_rplllock_1                      : std_logic;
  signal hsclk1_lcplllock_0                     : std_logic;
  signal hsclk1_lcplllock_1                     : std_logic;
  signal hsclk1_rplllock_0                      : std_logic;
  signal hsclk1_rplllock_1                      : std_logic;
  signal lcpll_lock_gt_bridge_ip_0              : std_logic;
  signal link_status_gt_bridge_ip_0             : std_logic;
  signal rate_sel_gt_bridge_ip_0                : std_logic_vector (3 downto 0);
  signal reset_rx_datapath_in                   : std_logic;
  signal reset_rx_pll_and_datapath_in           : std_logic;
  signal reset_tx_datapath_in                   : std_logic;
  signal reset_tx_pll_and_datapath_in           : std_logic;
  signal rpll_lock_gt_bridge_ip_0               : std_logic;
  signal rx_resetdone_out_gt_bridge_ip_0        : std_logic;
  signal rxusrclk_gt_bridge_ip_0                : std_logic;
  signal tx_resetdone_out_gt_bridge_ip_0        : std_logic;
  signal txusrclk_gt_bridge_ip_0                : std_logic;
  --
  signal lcpll_lock                             : std_logic := '0';
  signal rst_1, rst_2                           : std_logic := '0';
--
begin
  --============================================================================================================================
  --
  rate_sel_gt_bridge_ip_0                   <= "0000";
  --
  --============================================================================================================================
  -- Clock buffer for REFCLK
  --============================================================================================================================
  --
  -- IBUFDS_GTE3 and BUFG_GT already instantiated in gt block design.
  --
  gt_bridge_ip_0_diff_gt_ref_clock_clk_n(0) <= refclk_n;
  gt_bridge_ip_0_diff_gt_ref_clock_clk_p(0) <= refclk_p;
  apb3clk_gt_bridge_ip_0                    <= sysclk;
  apb3clk_quad                              <= sysclk;
  --============================================================================================================================
  -- TX data 
  ch0_txdata_ext(63 downto 0)               <= data_in(0);
  ch1_txdata_ext(63 downto 0)               <= data_in(1);
  ch2_txdata_ext(63 downto 0)               <= data_in(2);
  ch3_txdata_ext(63 downto 0)               <= data_in(3);
  ch4_txdata_ext(63 downto 0)               <= data_in(4);
  ch5_txdata_ext(63 downto 0)               <= data_in(5);
  ch6_txdata_ext(63 downto 0)               <= data_in(6);
  ch7_txdata_ext(63 downto 0)               <= data_in(7);
  --============================================================================================================================
  -- RX data 
  data_out(0)                               <= ch0_rxdata_ext(63 downto 0);
  data_out(1)                               <= ch1_rxdata_ext(63 downto 0);
  data_out(2)                               <= ch2_rxdata_ext(63 downto 0);
  data_out(3)                               <= ch3_rxdata_ext(63 downto 0);
  data_out(4)                               <= ch4_rxdata_ext(63 downto 0);
  data_out(5)                               <= ch5_rxdata_ext(63 downto 0);
  data_out(6)                               <= ch6_rxdata_ext(63 downto 0);
  data_out(7)                               <= ch7_rxdata_ext(63 downto 0);
  --============================================================================================================================
  --
  GT_Serial_1_grx_n                         <= rxn(7 downto 4);
  GT_Serial_1_grx_p                         <= rxp(7 downto 4);
  GT_Serial_grx_n                           <= rxn(3 downto 0);
  GT_Serial_grx_p                           <= rxp(3 downto 0);
  --
  txn(7 downto 4)                           <= GT_Serial_1_gtx_n;
  txp(7 downto 4)                           <= GT_Serial_1_gtx_p;
  txn(3 downto 0)                           <= GT_Serial_gtx_n;
  txp(3 downto 0)                           <= GT_Serial_gtx_p;
  --
  --============================================================================================================================
  --
  process(sysclk)
  begin
    if rising_edge(sysclk) then
      rst_1                   <= rst;
      rst_2                   <= rst_1;
      gt_reset_gt_bridge_ip_0 <= rst or rst_1 or rst_2;
    end if;
  end process;
  --
  --
  --============================================================================================================================
  --
  --============================================================================================================================
  -- XCVR instance
  --============================================================================================================================
  gty_txrx_8lanes_64b_wrapper_1 : entity work.gty_txrx_8lanes_64b_wrapper
    port map (
      GT_Serial_1_grx_n                      => GT_Serial_1_grx_n,
      GT_Serial_1_grx_p                      => GT_Serial_1_grx_p,
      GT_Serial_1_gtx_n                      => GT_Serial_1_gtx_n,
      GT_Serial_1_gtx_p                      => GT_Serial_1_gtx_p,
      GT_Serial_grx_n                        => GT_Serial_grx_n,
      GT_Serial_grx_p                        => GT_Serial_grx_p,
      GT_Serial_gtx_n                        => GT_Serial_gtx_n,
      GT_Serial_gtx_p                        => GT_Serial_gtx_p,
      apb3clk_gt_bridge_ip_0                 => apb3clk_gt_bridge_ip_0,
      apb3clk_quad                           => apb3clk_quad,
      ch0_rxdata_ext                         => ch0_rxdata_ext,
      ch0_txdata_ext                         => ch0_txdata_ext,
      ch1_rxdata_ext                         => ch1_rxdata_ext,
      ch1_txdata_ext                         => ch1_txdata_ext,
      ch2_rxdata_ext                         => ch2_rxdata_ext,
      ch2_txdata_ext                         => ch2_txdata_ext,
      ch3_rxdata_ext                         => ch3_rxdata_ext,
      ch3_txdata_ext                         => ch3_txdata_ext,
      ch4_rxdata_ext                         => ch4_rxdata_ext,
      ch4_txdata_ext                         => ch4_txdata_ext,
      ch5_rxdata_ext                         => ch5_rxdata_ext,
      ch5_txdata_ext                         => ch5_txdata_ext,
      ch6_rxdata_ext                         => ch6_rxdata_ext,
      ch6_txdata_ext                         => ch6_txdata_ext,
      ch7_rxdata_ext                         => ch7_rxdata_ext,
      ch7_txdata_ext                         => ch7_txdata_ext,
      gt_bridge_ip_0_diff_gt_ref_clock_clk_n => gt_bridge_ip_0_diff_gt_ref_clock_clk_n,
      gt_bridge_ip_0_diff_gt_ref_clock_clk_p => gt_bridge_ip_0_diff_gt_ref_clock_clk_p,
      gt_reset_gt_bridge_ip_0                => gt_reset_gt_bridge_ip_0,
      hsclk0_lcplllock_0                     => hsclk0_lcplllock_0,
      hsclk0_lcplllock_1                     => hsclk0_lcplllock_1,
      hsclk0_rplllock_0                      => hsclk0_rplllock_0,
      hsclk0_rplllock_1                      => hsclk0_rplllock_1,
      hsclk1_lcplllock_0                     => hsclk1_lcplllock_0,
      hsclk1_lcplllock_1                     => hsclk1_lcplllock_1,
      hsclk1_rplllock_0                      => hsclk1_rplllock_0,
      hsclk1_rplllock_1                      => hsclk1_rplllock_1,
      lcpll_lock_gt_bridge_ip_0              => lcpll_lock_gt_bridge_ip_0,
      link_status_gt_bridge_ip_0             => link_status_gt_bridge_ip_0,
      rate_sel_gt_bridge_ip_0                => rate_sel_gt_bridge_ip_0,
      reset_rx_datapath_in                   => reset_rx_datapath_in,
      reset_rx_pll_and_datapath_in           => reset_rx_pll_and_datapath_in,
      reset_tx_datapath_in                   => reset_tx_datapath_in,
      reset_tx_pll_and_datapath_in           => reset_tx_pll_and_datapath_in,
      rpll_lock_gt_bridge_ip_0               => rpll_lock_gt_bridge_ip_0,
      rx_resetdone_out_gt_bridge_ip_0        => rx_resetdone_out_gt_bridge_ip_0,
      rxusrclk_gt_bridge_ip_0                => rxusrclk_gt_bridge_ip_0,
      tx_resetdone_out_gt_bridge_ip_0        => tx_resetdone_out_gt_bridge_ip_0,
      txusrclk_gt_bridge_ip_0                => txusrclk_gt_bridge_ip_0);
  -- usrclk(s)
  rx_usrclk    <= rxusrclk_gt_bridge_ip_0;
  tx_usrclk    <= txusrclk_gt_bridge_ip_0;
  -- frame_clk(s)
  rx_frame_clk <= rxusrclk_gt_bridge_ip_0;
  tx_frame_clk <= txusrclk_gt_bridge_ip_0;
  --
  -- GTY transceiver block design is using LCPLL only both for TX and RX
  -- see gt_bridge_ip configuration.
  -- Note: there are two lcpll per quad.
  lcpll_lock                                <= hsclk0_lcplllock_0 and hsclk0_lcplllock_1 and hsclk1_lcplllock_0 and hsclk1_lcplllock_1;
  -- xcvr ip ready:
  tx_ip_ready  <= lcpll_lock and tx_resetdone_out_gt_bridge_ip_0;
  rx_ip_ready  <= lcpll_lock and rx_resetdone_out_gt_bridge_ip_0;
--
end architecture rtl;
