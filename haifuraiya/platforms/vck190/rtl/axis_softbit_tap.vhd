------------------------------------------------------------------------------------------------------
-- axis_softbit_tap -- AXI-Stream pass-through with native debug copies (DEBUG BUILD ONLY)
------------------------------------------------------------------------------------------------------
-- Why this exists (2026-10-24, first VCK190 hardware run): the receiver locked
-- and counted 24 frames, but the DMA S2MM channel never saw a byte -- the
-- FIFO -> widen -> DMA handshake did not move, and nothing software-visible
-- says which side.  An ILA on the stream is the measurement.  Vivado 2022.2's
-- AXIS ILA *interface* monitor fails to elaborate on these interfaces (no
-- TKEEP/TDEST: "can't read net_name_int_TD_"), so the ILA takes *native*
-- probes instead -- and native probes need plain nets that are not part of an
-- inferred AXI-Stream interface.  This block is a wire between widen/m_axis and
-- axi_dma/S_AXIS_S2MM that also drives probe_* copies of the four signals.
-- Vivado infers an AXI-Stream interface from any *_tdata/_tvalid/_tready/_tlast port
-- set (it did so for a first attempt named dbg_t*), so the copies are named
-- probe_* -- nothing to infer from, so they stay native pins.
--
-- Purely combinational.  Not in the production build (vck190_playback_bd.tcl
-- inserts it only when VCK190_ILA is set).
------------------------------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

ENTITY axis_softbit_tap IS
    GENERIC (
        DATA_WIDTH : NATURAL := 8
    );
    PORT (
        aclk          : IN  std_logic;
        aresetn       : IN  std_logic;

        -- from axis_softbit_widen
        s_axis_tdata  : IN  std_logic_vector(DATA_WIDTH-1 DOWNTO 0);
        s_axis_tvalid : IN  std_logic;
        s_axis_tready : OUT std_logic;
        s_axis_tlast  : IN  std_logic;

        -- to axi_dma S_AXIS_S2MM
        m_axis_tdata  : OUT std_logic_vector(DATA_WIDTH-1 DOWNTO 0);
        m_axis_tvalid : OUT std_logic;
        m_axis_tready : IN  std_logic;
        m_axis_tlast  : OUT std_logic;

        -- native copies for the ILA (probe_ready is the DMA's tready, as the FIFO sees it)
        probe_data     : OUT std_logic_vector(DATA_WIDTH-1 DOWNTO 0);
        probe_valid    : OUT std_logic;
        probe_ready    : OUT std_logic;
        probe_last     : OUT std_logic
    );
END ENTITY axis_softbit_tap;

ARCHITECTURE rtl OF axis_softbit_tap IS
BEGIN
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid;
    s_axis_tready <= m_axis_tready;
    m_axis_tlast  <= s_axis_tlast;

    probe_data  <= s_axis_tdata;
    probe_valid <= s_axis_tvalid;
    probe_ready <= m_axis_tready;
    probe_last  <= s_axis_tlast;
END ARCHITECTURE rtl;
