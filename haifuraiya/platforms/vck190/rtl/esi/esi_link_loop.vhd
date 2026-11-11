------------------------------------------------------------------------------------------------------
-- esi_link_loop -- I/Q samples in, ESIstream TX -> link -> ESIstream RX, I/Q samples out
------------------------------------------------------------------------------------------------------
-- The tier-2 "digital loopback" element: everything between the pacer and the
-- receiver.
--
--    esi_sample_packer -> tx_esistream -> [link] -> rx_esistream -> esi_sample_reassembler
--
-- plus the link bring-up sequencer (ESIstream needs: transceiver-ready rising
-- edge = RX logic reset; one sync pulse to TX and RX together; then
-- lanes_ready; then release the RX output buffer).
--
-- Two link clock domains (2026-11-09, for hardware).  A real transceiver hands
-- back two 156.25 MHz user clocks, TX and RX, of the same frequency but
-- unrelated phase (in loopback the RX clock is recovered from our own serial
-- bits, so it is frequency-locked to TX -- but that is a property of this test,
-- not something the design should lean on, and with the ADC it is no longer
-- true).  So:
--
--    tx_clk : packer link side, tx_esistream, the bring-up sequencer
--    rx_clk : rx_esistream (rx_usrclk AND rx_frame_clk), reassembler link side
--
-- and the three signals that cross between them -- the sync pulse (TX -> RX),
-- lanes_ready (RX -> TX) and release_data (RX -> TX) -- each go through a
-- two-flop synchronizer (Teledyne's ff_synchronizer_array).  In simulation
-- (IDEAL_LINK) the bench ties tx_clk and rx_clk to the same clock, which is a
-- legal special case of the above.
--
-- The sync pulse is four tx_clk wide, the width Teledyne's own sync_generator
-- uses (SYNCTRIG_PULSE_WIDTH => 4): rx_control stretches whatever it gets to
-- four clocks anyway and tx_scrambling keys on the falling edge, so a 4-wide
-- pulse survives the clock crossing and means the same thing to both ends.
--
-- The [link] is a generic:
--   IDEAL_LINK = true  : TX 64-bit words wired straight to RX.  No transceiver,
--                        no serial bits.  The simulation configuration: it
--                        proves the IP, the packer, the reassembler and the
--                        receiver together, in xsim, with the same stimulus and
--                        grade as tier 1.
--   IDEAL_LINK = false : the words go out on xcvr_tx_data (tx_clk) and come back
--                        on xcvr_rx_data (rx_clk) -- the hardware configuration,
--                        with the Versal GTY quad in the block design between
--                        them and xcvr_ready from it (esi_link_hw.vhd wraps
--                        this entity for the block design).
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

        -- transmit link clock domain (transceiver TX user clock, 156.25 MHz)
        tx_clk        : in  std_logic;
        tx_rstn       : in  std_logic;
        xcvr_tx_data  : out slv_ser_width_array_n(NB_LANES-1 downto 0);   -- to the transceiver (hardware)

        -- receive link clock domain (transceiver RX user clock, 156.25 MHz)
        rx_clk        : in  std_logic;
        rx_rstn       : in  std_logic;
        xcvr_rx_data  : in  slv_deser_width_array_n(NB_LANES-1 downto 0) := (others => (others => '0'));

        -- transceiver status, any clock domain (synchronized inside)
        xcvr_ready    : in  std_logic := '1';                     -- PLL locked + TX and RX reset done

        -- control (any domain, synchronized inside) / status (the domain named)
        sync_req      : in  std_logic := '0';                     -- level: re-issue the sync pulse (auto one after ready)
        stats_clear   : in  std_logic := '0';                     -- level: clear the error counters (rx_clk side)
        link_ready    : out std_logic;                            -- rx_clk: lanes aligned and RX data released
        lanes_ready   : out std_logic;                            -- rx_clk: all lanes aligned
        seq_errors    : out unsigned(31 downto 0);                -- rx_clk
        marker_errors : out unsigned(31 downto 0);                -- rx_clk
        multi_errors  : out unsigned(31 downto 0);                -- rx_clk
        samples_sent  : out unsigned(31 downto 0);                -- tx_clk
        samples_rcvd  : out unsigned(31 downto 0)                 -- rx_clk
    );
end entity esi_link_loop;

architecture rtl of esi_link_loop is
    -- bring-up sequencer (tx_clk)
    type boot_state_t is (WAIT_READY, SYNCING, RUNNING);
    signal boot_state    : boot_state_t := WAIT_READY;
    signal boot_cnt      : unsigned(4 downto 0) := (others => '0');
    signal ready_tx      : std_logic;                 -- xcvr_ready in tx_clk
    signal ready_rx      : std_logic;                 -- xcvr_ready in rx_clk
    signal sync_req_tx   : std_logic;
    signal sync_req_d    : std_logic := '0';
    signal sync_pulse_tx : std_logic := '0';          -- 4 tx_clk wide
    signal sync_pulse_rx : std_logic;                 -- the same, seen from rx_clk
    signal lanes_ready_i : std_logic;                 -- rx_clk, from rx_esistream
    signal lanes_ready_tx: std_logic;                 -- in tx_clk, for the sequencer
    signal release_cnt   : unsigned(3 downto 0) := (others => '0');
    signal release_rx    : std_logic := '0';          -- rx_clk: RX buffer released
    signal release_tx    : std_logic;                 -- in tx_clk, for the packer
    signal stats_clear_rx: std_logic;

    signal tx_words     : slv_ser_width_array_n(NB_LANES-1 downto 0);
    signal rx_words     : slv_deser_width_array_n(NB_LANES-1 downto 0);
    signal tx_data      : tx_data_array(NB_LANES-1 downto 0);
    signal rx_data      : rx_data_array(NB_LANES-1 downto 0);
    signal rx_valid     : std_logic_vector(NB_LANES-1 downto 0);
    signal lfsr_init    : slv_17_array_n(NB_LANES-1 downto 0) := (others => (others => '1'));
    signal lanes_on     : std_logic_vector(NB_LANES-1 downto 0) := (others => '1');
begin

    ---------------------------------------------------------------------------
    -- Clock-domain crossings: single bits, two flops each.
    ---------------------------------------------------------------------------
    u_sync_tx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 4)
        port map (clk => tx_clk,
                  reg_async(0) => xcvr_ready,
                  reg_async(1) => sync_req,
                  reg_async(2) => lanes_ready_i,
                  reg_async(3) => release_rx,
                  reg_sync(0)  => ready_tx,
                  reg_sync(1)  => sync_req_tx,
                  reg_sync(2)  => lanes_ready_tx,
                  reg_sync(3)  => release_tx);

    u_sync_rx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 3)
        port map (clk => rx_clk,
                  reg_async(0) => xcvr_ready,
                  reg_async(1) => sync_pulse_tx,
                  reg_async(2) => stats_clear,
                  reg_sync(0)  => ready_rx,
                  reg_sync(1)  => sync_pulse_rx,
                  reg_sync(2)  => stats_clear_rx);

    ---------------------------------------------------------------------------
    -- Bring-up sequencer (tx_clk).  Wait for the transceiver, give the IP 16
    -- clocks to see ready rise (rx_control resets its lanes on that edge),
    -- send one 4-clock sync pulse, run.  A rising edge of sync_req re-sends
    -- the pulse (both ends, like the examples' SYNCTRIG push-button); ready
    -- dropping starts over.
    ---------------------------------------------------------------------------
    p_boot : process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            sync_req_d <= sync_req_tx;
            if tx_rstn = '0' or ready_tx = '0' then
                boot_state    <= WAIT_READY;
                boot_cnt      <= (others => '0');
                sync_pulse_tx <= '0';
            else
                case boot_state is
                    when WAIT_READY =>
                        sync_pulse_tx <= '0';
                        boot_cnt <= boot_cnt + 1;
                        if boot_cnt = 15 then
                            boot_cnt   <= (others => '0');
                            boot_state <= SYNCING;
                        end if;
                    when SYNCING =>
                        sync_pulse_tx <= '1';
                        boot_cnt <= boot_cnt + 1;
                        if boot_cnt = 3 then
                            boot_cnt   <= (others => '0');
                            boot_state <= RUNNING;
                        end if;
                    when RUNNING =>
                        sync_pulse_tx <= '0';
                        if sync_req_tx = '1' and sync_req_d = '0' then
                            boot_state <= SYNCING;
                        end if;
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Release (rx_clk): 16 clocks after all lanes report ready, open the RX
    -- output buffer and let samples flow.  Drops at once if a lane drops.
    ---------------------------------------------------------------------------
    p_release : process(rx_clk)
    begin
        if rising_edge(rx_clk) then
            if rx_rstn = '0' or ready_rx = '0' or lanes_ready_i = '0' then
                release_cnt <= (others => '0');
                release_rx  <= '0';
            elsif release_cnt /= x"F" then
                release_cnt <= release_cnt + 1;
            else
                release_rx  <= '1';
            end if;
        end if;
    end process;

    link_ready  <= release_rx;
    lanes_ready <= lanes_ready_i;

    ---------------------------------------------------------------------------
    -- Transmit: packer -> ESIstream encoder (tx_clk)
    ---------------------------------------------------------------------------
    u_packer : entity work.esi_sample_packer
        generic map (NB_LANES => NB_LANES)
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready,
            link_clk => tx_clk, link_rstn => tx_rstn, link_ready => release_tx,
            data_out => tx_data, seq_out => open, samples_sent => samples_sent);

    u_tx : entity work.tx_esistream
        generic map (NB_LANES => NB_LANES, COMMA => COMMA)
        port map (
            tx_usrclk     => tx_clk,
            xcvr_ip_ready => ready_tx,
            xcvr_data_tx  => tx_words,
            sync_in       => sync_pulse_tx,
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
    -- Receive: ESIstream decoder -> reassembler (rx_clk)
    ---------------------------------------------------------------------------
    u_rx : entity work.rx_esistream
        generic map (NB_LANES => NB_LANES, COMMA => COMMA)
        port map (
            rx_usrclk     => rx_clk,
            xcvr_ip_ready => ready_rx,
            xcvr_data_rx  => rx_words,
            sync_in       => sync_pulse_rx,
            prbs_en       => '1',
            lanes_on      => lanes_on,
            read_data_en  => release_rx,
            rx_frame_clk  => rx_clk,
            sync_out      => open,
            frame_out     => open,
            data_out      => rx_data,
            valid_out     => rx_valid,
            lanes_ready   => lanes_ready_i);

    u_reasm : entity work.esi_sample_reassembler
        generic map (NB_LANES => NB_LANES)
        port map (
            link_clk => rx_clk, link_rstn => rx_rstn, link_ready => release_rx,
            data_in => rx_data, valid_in => rx_valid, stats_clear => stats_clear_rx,
            seq_errors => seq_errors, marker_errors => marker_errors,
            multi_errors => multi_errors, samples_rcvd => samples_rcvd,
            aclk => aclk, aresetn => aresetn,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready);

end architecture rtl;
