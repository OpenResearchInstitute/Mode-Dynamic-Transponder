------------------------------------------------------------------------------------------------------
-- AXIS Soft-Bit Width Adapter  (3-bit -> 16-bit, RECEIVE direction)
------------------------------------------------------------------------------------------------------
-- Role in the Receive Chain:
--   Sits between the rx_axi core's m_axis_soft_bit output and the S2MM DMA
--   (axi_adrv9001_rx1_dma in AXIS mode).
--
--   frame_sync_detector_soft emits one 3-bit soft decision (value 0..7) per
--   encoded bit, with TLAST marking the end of each 2144-value frame. The ADI
--   axi_dmac source width floors at 16 bits (valid widths: 16/32/64/...), so a
--   byte-per-value layout is not reachable. We therefore carry each 3-bit value
--   zero-extended into a 16-bit word: the DMA writes one int16 per soft value
--   (value 0..7 in the low 3 bits, high bits zero).
--
--   The consumer (opv-decode -3, and the dogu A53 integration) reads the capture
--   as int16 and narrows each to its low 3 bits before FrameDecoder::decode_soft3
--   -- int16 is already the soft type opv-decode's default and -m paths use.
--
--   DIRECTION NOTE: opposite of axis_dma_adapter.vhd, which NARROWS a 32-bit DMA
--   word to a byte for the TRANSMIT pipeline. Here we WIDEN a sub-byte receive
--   stream up for the DMA. Not interchangeable.
--
-- Implementation:
--   Purely combinational passthrough. No registers, no state machine. aclk/aresetn
--   present for interface consistency but unused. Zero-clock latency; backpressure
--   (tready) propagates directly.
------------------------------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY axis_softbit_widen IS
    GENERIC (
        SOFT_WIDTH : NATURAL := 3;
        OUT_WIDTH  : NATURAL := 16   -- DMA source width (axi_dmac floor)
    );
    PORT (
        aclk          : IN  std_logic;
        aresetn       : IN  std_logic;

        -- AXIS slave  (from rx_axi m_axis_soft_bit, 3-bit)
        s_axis_tdata  : IN  std_logic_vector(SOFT_WIDTH-1 DOWNTO 0);
        s_axis_tvalid : IN  std_logic;
        s_axis_tready : OUT std_logic;
        s_axis_tlast  : IN  std_logic;

        -- AXIS master (to the S2MM DMA, OUT_WIDTH-bit)
        m_axis_tdata  : OUT std_logic_vector(OUT_WIDTH-1 DOWNTO 0);
        m_axis_tvalid : OUT std_logic;
        m_axis_tready : IN  std_logic;
        m_axis_tlast  : OUT std_logic
    );
END ENTITY axis_softbit_widen;

ARCHITECTURE rtl OF axis_softbit_widen IS
BEGIN
    -- Zero-extend the unsigned 3-bit soft value (0..7) into the output word.
    m_axis_tdata  <= std_logic_vector(resize(unsigned(s_axis_tdata), OUT_WIDTH));

    m_axis_tvalid <= s_axis_tvalid;
    s_axis_tready <= m_axis_tready;
    m_axis_tlast  <= s_axis_tlast;
END ARCHITECTURE rtl;
