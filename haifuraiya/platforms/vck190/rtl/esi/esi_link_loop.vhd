------------------------------------------------------------------------------------------------------
-- esi_link_loop -- I/Q samples in, ESIstream TX -> link -> ESIstream RX, I/Q samples out
------------------------------------------------------------------------------------------------------
-- The tier-2 "digital loopback" element: everything between the pacer and the
-- receiver.  Contains, in the link clock domain:
--
--    esi_sample_packer -> tx_esistream -> [link] -> rx_esistream -> esi_sample_reassembler
--
-- plus the link bring-up sequencer (ESIstream needs: transceiver-ready rising
-- edge = RX logic reset; one sync pulse to TX and RX together; then
-- lanes_ready; then release the RX output buffer).
--
-- The [link] is a generic:
--   IDEAL_LINK = true  : TX 64-bit words wired straight to RX, same clock.  No
--                        transceiver, no serial bits.  This is the simulation
--                        configuration: it proves the IP, the packer, the
--                        reassembler and the receiver together, in xsim, with
--                        the same stimulus and grade as tier 1.
--   IDEAL_LINK = false : the words go out on xcvr_tx_data and come back on
--                        xcvr_rx_data -- the hardware configuration, with the
--                        Teledyne transceiver block (gty_txrx_8lanes_64b) in
--                        the block design between them and xcvr_ready from it.
--
-- The receiver on the other side is unchanged and never knows the link exists.
-- Teledyne e2v's tx_esistream / rx_esistream are public domain
-- (haifuraiya/third_party/esistream_vck190/).
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;
use work.esi_loop_pkg.all;

entity esi_link_loop is
    generic (
        NB_LANES   : natural := 8;
        COMMA      : std_logic_vector(31 downto 0) := x"FF0000FF";   -- as both Teledyne examples
        IDEAL_LINK : boolean := true
    );
    port (
        -- sample side, receiver clock domain
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;

        -- link clock domain
        link_clk      : in  std_logic;                            -- ESIstream frame clock (156.25 MHz)
        link_rstn     : in  std_logic;
        xcvr_ready    : in  std_logic := '1';                     -- transceiver PLL locked + reset done (hardware)
        xcvr_tx_data  : out slv_ser_width_array_n(NB_LANES-1 downto 0);   -- to the transceiver (hardware)
        xcvr_rx_data  : in  slv_deser_width_array_n(NB_LANES-1 downto 0) := (others => (others => '0'));

        -- control / status (link clock domain; register them in hardware)
        sync_req      : in  std_logic := '0';                     -- extra sync pulse on demand (auto one after reset)
        link_ready    : out std_logic;                            -- lanes aligned and RX data released
        seq_errors    : out unsigned(31 downto 0);
        marker_errors : out unsigned(31 downto 0);
        multi_errors  : out unsigned(31 downto 0);
        samples_sent  : out unsigned(31 downto 0);
        samples_rcvd  : out unsigned(31 downto 0)
    );
end entity esi_link_loop;

architecture rtl of esi_link_loop is
    -- bring-up sequencer
    signal ip_ready     : std_logic := '0';
    signal sync_pulse   : std_logic := '0';
    signal boot_cnt     : unsigned(7 downto 0) := (others => '0');
    signal lanes_ready  : std_logic;
    signal release_cnt  : unsigned(3 downto 0) := (others => '0');
    signal release_data : std_logic := '0';

    signal tx_words     : slv_ser_width_array_n(NB_LANES-1 downto 0);
    signal rx_words     : slv_deser_width_array_n(NB_LANES-1 downto 0);
    signal tx_data      : tx_data_array(NB_LANES-1 downto 0);
    signal rx_data      : rx_data_array(NB_LANES-1 downto 0);
    signal rx_valid     : std_logic_vector(NB_LANES-1 downto 0);
    signal lfsr_init    : slv_17_array_n(NB_LANES-1 downto 0) := (others => (others => '1'));
    signal lanes_on     : std_logic_vector(NB_LANES-1 downto 0) := (others => '1');
begin

    ---------------------------------------------------------------------------
    -- Bring-up: ip_ready rises 16 clocks after reset (gives rx_control its
    -- rising edge), one sync pulse 16 clocks after that, then wait for
    -- lanes_ready and release the RX output buffer 8 clocks later.  sync_req
    -- re-issues the pulse (both ends, like the examples' SYNCTRIG).
    ---------------------------------------------------------------------------
    p_boot : process(link_clk)
    begin
        if rising_edge(link_clk) then
            sync_pulse <= '0';
            if link_rstn = '0' then
                boot_cnt     <= (others => '0');
                ip_ready     <= '0';
                release_cnt  <= (others => '0');
                release_data <= '0';
            else
                if boot_cnt /= x"FF" then
                    boot_cnt <= boot_cnt + 1;
                end if;
                if boot_cnt = x"10" then
                    ip_ready <= xcvr_ready;
                elsif boot_cnt > x"10" then
                    ip_ready <= xcvr_ready;          -- follows the transceiver afterwards
                end if;
                if boot_cnt = x"20" or sync_req = '1' then
                    sync_pulse <= '1';
                end if;
                if lanes_ready = '1' then
                    if release_cnt /= x"F" then
                        release_cnt <= release_cnt + 1;
                    else
                        release_data <= '1';
                    end if;
                else
                    release_cnt  <= (others => '0');
                    release_data <= '0';
                end if;
            end if;
        end if;
    end process;

    link_ready <= release_data;

    ---------------------------------------------------------------------------
    -- Transmit: packer -> ESIstream encoder
    ---------------------------------------------------------------------------
    u_packer : entity work.esi_sample_packer
        generic map (NB_LANES => NB_LANES)
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready,
            link_clk => link_clk, link_rstn => link_rstn, link_ready => release_data,
            data_out => tx_data, seq_out => open, samples_sent => samples_sent);

    u_tx : entity work.tx_esistream
        generic map (NB_LANES => NB_LANES, COMMA => COMMA)
        port map (
            tx_usrclk     => link_clk,
            xcvr_ip_ready => ip_ready,
            xcvr_data_tx  => tx_words,
            sync_in       => sync_pulse,
            prbs_en       => '1',
            disp_en       => '1',
            lfsr_init     => lfsr_init,
            data_in       => tx_data);

    ---------------------------------------------------------------------------
    -- The link
    ---------------------------------------------------------------------------
    g_ideal : if IDEAL_LINK generate
        -- same width (64/64) but distinct array types in esistream_pkg
        g_lane : for l in 0 to NB_LANES-1 generate
            rx_words(l) <= tx_words(l);
        end generate;
        xcvr_tx_data <= tx_words;
    end generate;
    g_xcvr : if not IDEAL_LINK generate
        xcvr_tx_data <= tx_words;
        rx_words     <= xcvr_rx_data;
    end generate;

    ---------------------------------------------------------------------------
    -- Receive: ESIstream decoder -> reassembler
    ---------------------------------------------------------------------------
    u_rx : entity work.rx_esistream
        generic map (NB_LANES => NB_LANES, COMMA => COMMA)
        port map (
            rx_usrclk     => link_clk,
            xcvr_ip_ready => ip_ready,
            xcvr_data_rx  => rx_words,
            sync_in       => sync_pulse,
            prbs_en       => '1',
            lanes_on      => lanes_on,
            read_data_en  => release_data,
            rx_frame_clk  => link_clk,
            sync_out      => open,
            frame_out     => open,
            data_out      => rx_data,
            valid_out     => rx_valid,
            lanes_ready   => lanes_ready);

    u_reasm : entity work.esi_sample_reassembler
        generic map (NB_LANES => NB_LANES)
        port map (
            link_clk => link_clk, link_rstn => link_rstn, link_ready => release_data,
            data_in => rx_data, valid_in => rx_valid, stats_clear => '0',
            seq_errors => seq_errors, marker_errors => marker_errors,
            multi_errors => multi_errors, samples_rcvd => samples_rcvd,
            aclk => aclk, aresetn => aresetn,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready);

end architecture rtl;
