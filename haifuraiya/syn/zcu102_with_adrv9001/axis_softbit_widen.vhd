------------------------------------------------------------------------------------------------------
-- AXIS Soft-Bit Width Adapter  (3-bit -> 8-bit, RECEIVE direction)
------------------------------------------------------------------------------------------------------
-- Role in the Receive Chain:
--   Sits between the rx_axi core's m_axis_soft_bit output and the byte-wide S2MM
--   DMA (axi_adrv9001_rx1_dma in AXIS mode, DMA_DATA_WIDTH_SRC = 8).
--
--   frame_sync_detector_soft emits one 3-bit soft decision (value 0..7) per
--   encoded bit, with TLAST marking the end of each 2144-value frame. The DMA
--   writes a byte stream to memory. This adapter zero-extends each 3-bit value
--   into the low bits of a byte, so the DMA writes exactly ONE BYTE PER SOFT BIT
--   -- the back-to-back-frames-of-ENCODED_BITS-bytes layout that opv-decode -3
--   reads back (values 0..7, on-air interleaved order).
--
--   DIRECTION NOTE: this is the OPPOSITE of axis_dma_adapter.vhd, which narrows a
--   32-bit DMA word down to a byte for the TRANSMIT pipeline (DMA -> stream).
--   Here we widen a sub-byte RECEIVE stream up to a byte (stream -> DMA). They are
--   not interchangeable.
--
-- Implementation:
--   Purely combinational passthrough. No registers, no state machine. aclk/aresetn
--   are present for interface consistency but unused. Zero-clock latency;
--   backpressure (tready) propagates directly.
------------------------------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY axis_softbit_widen IS
    GENERIC (
        SOFT_WIDTH : NATURAL := 3;
        BYTE_WIDTH : NATURAL := 8
    );
    PORT (
        aclk          : IN  std_logic;
        aresetn       : IN  std_logic;

        -- AXIS slave  (from rx_axi m_axis_soft_bit)
        s_axis_tdata  : IN  std_logic_vector(SOFT_WIDTH-1 DOWNTO 0);
        s_axis_tvalid : IN  std_logic;
        s_axis_tready : OUT std_logic;
        s_axis_tlast  : IN  std_logic;

        -- AXIS master (to byte-wide S2MM DMA)
        m_axis_tdata  : OUT std_logic_vector(BYTE_WIDTH-1 DOWNTO 0);
        m_axis_tvalid : OUT std_logic;
        m_axis_tready : IN  std_logic;
        m_axis_tlast  : OUT std_logic
    );
END ENTITY axis_softbit_widen;

ARCHITECTURE rtl OF axis_softbit_widen IS
BEGIN
    -- Zero-extend the 3-bit soft value into a byte (value stays 0..7).
    m_axis_tdata  <= std_logic_vector(resize(unsigned(s_axis_tdata), BYTE_WIDTH));

    m_axis_tvalid <= s_axis_tvalid;
    s_axis_tready <= m_axis_tready;
    m_axis_tlast  <= s_axis_tlast;
END ARCHITECTURE rtl;
