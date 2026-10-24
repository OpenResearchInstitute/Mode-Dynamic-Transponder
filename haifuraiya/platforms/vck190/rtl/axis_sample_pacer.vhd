----------------------------------------------------------------------------
-- axis_sample_pacer.vhd -- VCK190 playback self-test: meter a DMA-fed
-- AXI-Stream down to the ADC sample rate.
--
-- The receiver (haifuraiya_rx_axi) consumes on arrival: its input TREADY
-- is held high and its pipelines assume samples arrive no faster than one
-- beat per PERIOD clocks (the 20 MSps design point is one beat per 5 clocks
-- of the 100 MHz aclk -- the sim runner's SMP_PERIOD=5).  A DMA engine
-- would push beats every clock.  This block sits between the two and
-- forwards exactly one beat per `period` clocks, backpressuring the DMA
-- the rest of the time.  It is the hardware equivalent of the bench's
--     wait for (SMP_PERIOD - 1) * CLK_PERIOD;
-- and nothing else: no buffering, no data change, TLAST passed through.
--
-- `period` is a live input (register-backed in the shell so the sample
-- rate can be changed without a respin); 0 and 1 both mean every clock.
-- When upstream has no data on a slot, the slot is simply missed -- the
-- receiver sees a gap, which is what a dropped ADC sample would be.
--
-- One sentence: pass one sample every `period` clocks, hold the DMA off
-- in between.
----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_sample_pacer is
    generic (
        DATA_WIDTH : positive := 32
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        period        : in  unsigned(7 downto 0);   -- clocks per sample slot

        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of axis_sample_pacer is
    signal cnt  : unsigned(7 downto 0) := (others => '0');
    signal slot : std_logic := '0';   -- this clock is a sample slot
begin
    -- slot opens when the counter reaches period-1 (or always for 0/1)
    slot <= '1' when period <= 1 or cnt = period - 1 else '0';

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                cnt <= (others => '0');
            elsif period <= 1 or cnt = period - 1 then
                cnt <= (others => '0');
            else
                cnt <= cnt + 1;
            end if;
        end if;
    end process;

    -- combinational pass-through, gated by the slot: standard AXIS rules
    -- hold (valid never depends on ready; a beat moves only when both are
    -- high, which can only happen on a slot)
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tlast  <= s_axis_tlast;
    m_axis_tvalid <= s_axis_tvalid and slot;
    s_axis_tready <= m_axis_tready and slot;
end architecture;
