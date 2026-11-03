------------------------------------------------------------------------------------------------------
-- esi_sample_reassembler -- ESIstream RX data arrays (link clock) -> AXI-Stream I/Q samples (100 MHz)
------------------------------------------------------------------------------------------------------
-- Tier-2 digital loopback, receive side.  Every link clock, rx_esistream hands
-- us one slot per lane (4 x 14-bit frames, esi_loop_pkg layout) with a per-lane
-- valid.  We scan the lanes in order, take the one slot whose VALID flag is
-- set, rebuild the 32-bit I/Q beat (I in [15:0], Q in [31:16]) and push it
-- through axis_async_fifo into the receiver's clock domain.  The receiver is
-- consume-on-arrival, so the link's timing is invisible to it; only the
-- sample ORDER matters, and that is what the checks below guard:
--
--   seq_errors    : SEQ of a valid slot != previous SEQ + 1  (lane order /
--                   alignment / lost sample).  First valid slot seeds SEQ.
--   marker_errors : MARKER field wrong (descrambling / framing / garbage from
--                   an empty output buffer).  Such a slot is still forwarded,
--                   so that a receiver-side failure stays visible too.
--   multi_errors  : two or more VALID slots in one clock (the packer never
--                   does this; seeing it means the link duplicated data).
--
-- Counters are in the link clock domain, 32-bit, saturating, cleared by
-- link_rstn or stats_clear.  Read them over AXI-Lite in hardware; the bench
-- reads them directly.
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;
use work.esi_loop_pkg.all;

entity esi_sample_reassembler is
    generic (
        NB_LANES   : natural := 8;
        FIFO_ADDRW : natural := 6
    );
    port (
        -- link side (ESIstream frame clock)
        link_clk      : in  std_logic;
        link_rstn     : in  std_logic;
        link_ready    : in  std_logic;                              -- rx lanes_ready
        data_in       : in  rx_data_array(NB_LANES-1 downto 0);     -- rx_esistream.data_out
        valid_in      : in  std_logic_vector(NB_LANES-1 downto 0);  -- rx_esistream.valid_out
        stats_clear   : in  std_logic := '0';
        seq_errors    : out unsigned(31 downto 0);
        marker_errors : out unsigned(31 downto 0);
        multi_errors  : out unsigned(31 downto 0);
        samples_rcvd  : out unsigned(31 downto 0);

        -- sample side (receiver domain)
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity esi_sample_reassembler;

architecture rtl of esi_sample_reassembler is
    signal beat_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal beat_tvalid : std_logic := '0';
    signal beat_tready : std_logic;

    signal seq_expect  : unsigned(ESI_SEQ_BITS-1 downto 0) := (others => '0');
    signal seq_seeded  : std_logic := '0';
    signal c_seq, c_mark, c_multi, c_rcvd : unsigned(31 downto 0) := (others => '0');

    function sat_inc(c : unsigned(31 downto 0)) return unsigned is
    begin
        if c = x"FFFFFFFF" then return c; else return c + 1; end if;
    end function;
begin

    p_unpack : process(link_clk)
        variable n_valid : natural;
        variable slot    : esi_slot_t;
        variable found   : boolean;
    begin
        if rising_edge(link_clk) then
            beat_tvalid <= '0';
            if link_rstn = '0' or stats_clear = '1' then
                c_seq <= (others => '0'); c_mark <= (others => '0');
                c_multi <= (others => '0'); c_rcvd <= (others => '0');
                seq_seeded <= '0';
            elsif link_ready = '1' then
                n_valid := 0;
                found   := false;
                for l in 0 to NB_LANES-1 loop
                    if valid_in(l) = '1' and esi_slot_valid(data_in(l)) = '1' then
                        n_valid := n_valid + 1;
                        if not found then
                            found := true;
                            slot  := data_in(l);
                        end if;
                    end if;
                end loop;
                if n_valid > 1 then
                    c_multi <= sat_inc(c_multi);
                end if;
                if found then
                    beat_tdata  <= esi_slot_q(slot) & esi_slot_i(slot);
                    beat_tvalid <= '1';
                    c_rcvd <= sat_inc(c_rcvd);
                    if esi_slot_marker_ok(slot) = '0' then
                        c_mark <= sat_inc(c_mark);
                    end if;
                    if seq_seeded = '1' and esi_slot_seq(slot) /= seq_expect then
                        c_seq <= sat_inc(c_seq);
                    end if;
                    seq_expect <= esi_slot_seq(slot) + 1;
                    seq_seeded <= '1';
                end if;
            end if;
        end if;
    end process;

    -- beat_tready is ignored on purpose: a sample is produced at most once
    -- per link clock and the FIFO drains 100 MHz vs 20 MSps, so it cannot
    -- fill.  If it ever did, the FIFO's tready would drop and the beat would
    -- be lost -- the sequence counter on the next run would show it.
    u_fifo : entity work.axis_async_fifo
        generic map (DATA_WIDTH => 32, ADDR_WIDTH => FIFO_ADDRW, FRAME_SIZE => 8)
        port map (
            wr_aclk        => link_clk,
            wr_aresetn     => link_rstn,
            s_axis_tdata   => beat_tdata,
            s_axis_tvalid  => beat_tvalid,
            s_axis_tready  => beat_tready,
            s_axis_tlast   => '0',
            rd_aclk        => aclk,
            rd_aresetn     => aresetn,
            m_axis_tdata   => m_axis_tdata,
            m_axis_tvalid  => m_axis_tvalid,
            m_axis_tready  => m_axis_tready,
            m_axis_tlast   => open,
            prog_full      => open,
            prog_empty     => open,
            status_aclk    => aclk,
            status_aresetn => aresetn,
            status_req     => '0',
            status_ack     => open,
            fifo_wr_ptr    => open,
            fifo_rd_ptr    => open
        );

    seq_errors    <= c_seq;
    marker_errors <= c_mark;
    multi_errors  <= c_multi;
    samples_rcvd  <= c_rcvd;

end architecture rtl;
