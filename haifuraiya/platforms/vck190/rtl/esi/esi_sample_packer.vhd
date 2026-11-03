------------------------------------------------------------------------------------------------------
-- esi_sample_packer -- AXI-Stream I/Q samples (100 MHz domain) -> ESIstream TX data arrays (link clock)
------------------------------------------------------------------------------------------------------
-- Tier-2 digital loopback, transmit side.  Takes the 32-bit I/Q beats the pacer
-- produces (I in [15:0], Q in [31:16], as everywhere in this design), crosses
-- them into the ESIstream frame-clock domain through the proven
-- axis_async_fifo, and lays each sample into one lane slot (esi_loop_pkg
-- layout) with a running sequence number.  At most one sample per link clock,
-- rotating over the lanes; every other lane gets an idle slot.  The ESIstream
-- TX encodes whatever is on data_in every clock, so idle slots are simply
-- frames with VALID = 0.
--
-- Backpressure: s_axis_tready is low while the link is not ready (the TX
-- ignores data during its sync sequence) and while the FIFO is full.  The
-- pacer/DMA side honours tready, so nothing is lost; the ADC never backpressures
-- anyone, but this is a test fixture and losing the first samples of a run to
-- the link's sync sequence would be an avoidable mystery.
--
-- Clock domains: s_axis_* on aclk; data_out on link_clk.  The FIFO is the only
-- crossing.  No multi-sample-per-clock mode: at 20 MSps against a 156.25 MHz
-- link clock the FIFO never accumulates.
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;
use work.esi_loop_pkg.all;

entity esi_sample_packer is
    generic (
        NB_LANES   : natural := 8;
        FIFO_ADDRW : natural := 6      -- 64 beats of headroom is plenty at 0.13 sample/clock
    );
    port (
        -- sample side (pacer / DMA domain)
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- link side (ESIstream frame clock = transceiver user clock)
        link_clk      : in  std_logic;
        link_rstn     : in  std_logic;
        link_ready    : in  std_logic;                            -- TX+RX synchronized (lanes_ready)
        data_out      : out tx_data_array(NB_LANES-1 downto 0);   -- to tx_esistream.data_in
        seq_out       : out unsigned(ESI_SEQ_BITS-1 downto 0);    -- sequence of the next sample (debug)
        samples_sent  : out unsigned(31 downto 0)                 -- debug counter, link_clk domain
    );
end entity esi_sample_packer;

architecture rtl of esi_sample_packer is
    signal f_tdata   : std_logic_vector(31 downto 0);
    signal f_tvalid  : std_logic;
    signal f_tready  : std_logic;
    signal fifo_in_tready : std_logic;

    signal lane_ptr  : natural range 0 to NB_LANES-1 := 0;
    signal seq       : unsigned(ESI_SEQ_BITS-1 downto 0) := (others => '0');
    signal sent      : unsigned(31 downto 0) := (others => '0');
    signal link_ready_r : std_logic := '0';
begin

    -- accept samples only once the link is up (the TX drops data during sync)
    s_axis_tready <= fifo_in_tready and link_ready_r;

    u_fifo : entity work.axis_async_fifo
        generic map (DATA_WIDTH => 32, ADDR_WIDTH => FIFO_ADDRW, FRAME_SIZE => 8)
        port map (
            wr_aclk        => aclk,
            wr_aresetn     => aresetn,
            s_axis_tdata   => s_axis_tdata,
            s_axis_tvalid  => s_axis_tvalid and link_ready_r,
            s_axis_tready  => fifo_in_tready,
            s_axis_tlast   => '0',
            rd_aclk        => link_clk,
            rd_aresetn     => link_rstn,
            m_axis_tdata   => f_tdata,
            m_axis_tvalid  => f_tvalid,
            m_axis_tready  => f_tready,
            m_axis_tlast   => open,
            prog_full      => open,
            prog_empty     => open,
            status_aclk    => link_clk,
            status_aresetn => link_rstn,
            status_req     => '0',
            status_ack     => open,
            fifo_wr_ptr    => open,
            fifo_rd_ptr    => open
        );

    -- link_ready is a link_clk-domain signal; resynchronise for the aclk side
    -- (two flops; it changes once per run, so a plain synchroniser is enough)
    p_sync_ready : process(aclk)
        variable r1 : std_logic := '0';
    begin
        if rising_edge(aclk) then
            link_ready_r <= r1;
            r1 := link_ready;
        end if;
    end process;

    -- one sample per link clock at most, on lane lane_ptr
    f_tready <= link_ready;

    p_pack : process(link_clk)
        variable slot : esi_slot_t;
    begin
        if rising_edge(link_clk) then
            if link_rstn = '0' then
                lane_ptr <= 0;
                seq      <= (others => '0');
                sent     <= (others => '0');
                for l in 0 to NB_LANES-1 loop
                    data_out(l) <= esi_idle_slot;
                end loop;
            else
                for l in 0 to NB_LANES-1 loop
                    data_out(l) <= esi_idle_slot;
                end loop;
                if f_tvalid = '1' and f_tready = '1' then
                    slot := esi_pack_slot(f_tdata(15 downto 0), f_tdata(31 downto 16), seq);
                    data_out(lane_ptr) <= slot;
                    seq  <= seq + 1;
                    sent <= sent + 1;
                    if lane_ptr = NB_LANES-1 then
                        lane_ptr <= 0;
                    else
                        lane_ptr <= lane_ptr + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    seq_out      <= seq;
    samples_sent <= sent;

end architecture rtl;
