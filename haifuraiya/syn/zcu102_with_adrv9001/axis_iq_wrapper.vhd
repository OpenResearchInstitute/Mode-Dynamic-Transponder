--------------------------------------------------------------------------------
-- axis_iq_wrapper.vhd
--------------------------------------------------------------------------------
--
-- Combines parallel 16-bit I and 16-bit Q with a valid signal into a
-- 32-bit AXI4-Stream interface. The downstream consumer
-- (haifuraiya_channelizer_axi v0.1) packs I in tdata[15:0] and Q in
-- tdata[31:16].
--
-- This module is the glue between ADI's axi_adrv9001 RX1 path
-- (parallel adc_1_data_i0/q0 + adc_1_valid_i0) and our packaged
-- channelizer IP's AXIS slave port.
--
-- Backpressure: tready is NOT honored. The downstream channelizer's
-- s_axis_data_tready is hardwired '1' in haifuraiya_channelizer_axi.vhd,
-- so backpressure cannot occur in this configuration. If ever paired
-- with a backpressuring consumer, insert an axis_data_fifo between this
-- wrapper and the consumer.
--
-- Reset polarity: aresetn is active-low (AXIS convention). The
-- haifuraiya_splice.tcl inverts axi_adrv9001/adc_1_rst (which is
-- active-high) before driving aresetn.
--
-- Provenance: written for ORI's Haifuraiya project, modeled on the
-- pluto_msk libre Vivado integration approach (replacement of cpack2
-- + FIFO-mode DMA with an AXIS-direct path).
--
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity axis_iq_wrapper is
    port (
        clk           : in  std_logic;
        aresetn       : in  std_logic;

        i_data        : in  std_logic_vector(15 downto 0);
        q_data        : in  std_logic_vector(15 downto 0);
        in_valid      : in  std_logic;

        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity axis_iq_wrapper;

architecture rtl of axis_iq_wrapper is

    -- Vivado IP-XACT interface annotations so that the AXIS pins are
    -- inferred as a single AXIS master interface bundle named "m_axis".
    -- See PG214 / UG994 for the attribute conventions.

    attribute X_INTERFACE_INFO      : string;
    attribute X_INTERFACE_PARAMETER : string;
    attribute X_INTERFACE_IGNORE    : string;

    attribute X_INTERFACE_INFO      of m_axis_tdata  : signal is
        "xilinx.com:interface:axis:1.0 m_axis TDATA";
    attribute X_INTERFACE_INFO      of m_axis_tvalid : signal is
        "xilinx.com:interface:axis:1.0 m_axis TVALID";
    attribute X_INTERFACE_INFO      of m_axis_tready : signal is
        "xilinx.com:interface:axis:1.0 m_axis TREADY";

    attribute X_INTERFACE_INFO      of clk : signal is
        "xilinx.com:signal:clock:1.0 clk CLK";
    attribute X_INTERFACE_PARAMETER of clk : signal is
        "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET aresetn";

    attribute X_INTERFACE_INFO      of aresetn : signal is
        "xilinx.com:signal:reset:1.0 aresetn RST";
    attribute X_INTERFACE_PARAMETER of aresetn : signal is
        "POLARITY ACTIVE_LOW";

    -- Tell Vivado NOT to auto-infer a phantom AXIS interface from these
    -- scalar pin names. Without these markers, Vivado sees "i_data" and
    -- creates an interface called "i" with TDATA = i_data, etc., which
    -- produces benign-but-noisy [BD 41-1306] warnings when we connect
    -- these pins directly via connect_bd_net.
    attribute X_INTERFACE_IGNORE    of i_data   : signal is "TRUE";
    attribute X_INTERFACE_IGNORE    of q_data   : signal is "TRUE";
    attribute X_INTERFACE_IGNORE    of in_valid : signal is "TRUE";

begin

    -- tdata layout: {Q[15:0], I[15:0]}.
    -- Matches haifuraiya_channelizer_axi expectation:
    --   sample_re_int <= s_axis_data_tdata(DATA_WIDTH - 1 downto 0);            -- I
    --   sample_im_int <= s_axis_data_tdata(31 downto 32 - DATA_WIDTH);          -- Q
    m_axis_tdata  <= q_data & i_data;

    -- Mute tvalid during reset so the channelizer doesn't see spurious
    -- samples while clocks/data are settling.
    m_axis_tvalid <= in_valid and aresetn;

    -- m_axis_tready is intentionally unused; declared so that Vivado's
    -- X_INTERFACE_INFO annotations form a complete AXIS master interface.

end architecture rtl;
