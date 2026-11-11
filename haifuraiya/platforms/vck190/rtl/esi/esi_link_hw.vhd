------------------------------------------------------------------------------------------------------
-- esi_link_hw -- esi_link_loop for the block design: GTY glue, AXI-Lite registers, two lanes
------------------------------------------------------------------------------------------------------
-- The tier-2 hardware element.  Sits between the pacer and the receiver in
-- vck190_playback_bd.tcl (hierarchy esi_link), next to the Versal GTY quad:
--
--   pacer --s_axis--> [esi_link_loop(IDEAL_LINK=false, 2 lanes)] --m_axis--> receiver
--                        |  64-bit words per lane, tx_clk      ^  64-bit words per lane, rx_clk
--                        v                                     |
--               gt_bridge_ip (bypass mode) <-> gt_quad_base (GTY, 10.0 Gb/s, 156.25 MHz refclk)
--                                                 ch0/ch1 loopback = near-end PMA (register, default)
--
-- Why a wrapper and not esi_link_loop itself: the block design's module
-- reference needs flat std_logic_vector ports (no record/array types), the
-- bridge's data ports are 128 bits per channel of which 64 are used (as in
-- Teledyne's tx_rx_xcvr_wrapper_64b: chN_txdata_ext(63 downto 0) <= data_in(N)),
-- and the A72s need registers to see the link and read the scoreboard.
--
-- Clock domains: aclk (100 MHz, the receiver's clock, also the bridge/quad
-- apb3clk), tx_clk and rx_clk (the quad's ch0 txoutclk/rxoutclk through
-- BUFG_GTs, 156.25 MHz each, unrelated phase), and gt_refclk_mon, a fabric
-- copy of the transceiver's reference clock (IBUFDS_GTE5 ODIV2 through a
-- BUFG_GT; ODIV2 = O with the primitive's default REFCLK_HROW_CK_SEL = 0,
-- AM002).  Everything that crosses goes through a two-flop synchronizer or
-- the toggle handshake below; the counters are read by SNAPSHOT so software
-- never sees a torn word.
--
-- When the transceiver is reset (2026-11-11).  The bridge's reset sequence
-- only completes if the reference clock is right while it runs, and on the
-- VCK190 the reference (the user SI570) is 100 MHz at power-up and becomes
-- 156.25 MHz only when Linux programs it -- long after the PL came out of
-- reset.  So the block does not reset the transceiver at a fixed time; it
-- resets it when the reference clock is GOOD: a monitor counts
-- gt_refclk_mon against aclk in windows of REFCLK_WINDOW reference cycles,
-- refclk_valid asserts after 8 consecutive windows within +/-2.5 % of the
-- expected ratio (and clears on 2 bad windows or a dead clock), and one
-- gtreset_in pulse is issued on each rising edge of refclk_valid.  One reset
-- per "clock became good" event, none if it never does, no retry timer.
-- Software can still pulse GT_RESET by hand; REFCLK_GOOD_EVENTS counts the
-- automatic ones (1 after a normal boot).
--
-- Register map (4 KB, byte offsets; 0xA403_0000 in the playback design):
--
--   0x00  ID            RO  0x45534931 "ESI1"
--   0x04  CONTROL       RW  bit 0    LINK_RESET   1 = hold the TX/RX link logic in reset (default 0)
--                           bit 1    SYNC_REQ     write 1: one more sync pulse to TX and RX (reads 0)
--                           bit 2    STATS_CLEAR  write 1: clear the error counters (reads 0)
--                           bit 3    GT_RESET     write 1: 8-clock pulse on the bridge's gtreset_in (reads 0)
--                           bits 6:4 LOOPBACK     to the quad's ch0/ch1 loopback: 010 near-end PMA (default),
--                                                 001 near-end PCS, 000 normal (tier 3: the ADC drives RX)
--                           bit 7    SNAPSHOT     write 1: latch the link-domain counters (reads 0)
--   0x08  STATUS        RO  bit 0  gt_powergood        bit 1  lcpll_lock      bit 2  tx_resetdone
--                           bit 3  rx_resetdone        bit 4  gt_link_status  bit 5  xcvr_ready (= 1 and 2 and 3)
--                           bit 6  lanes_ready         bit 7  link_ready      bit 8  snapshot busy
--                           bit 9  tx_clk alive        bit 10 rx_clk alive    (toggled within the last 2.5 us)
--                           bit 11 refclk_valid        (reference clock at the expected frequency, see above)
--   0x0C  SAMPLES_SENT  RO  snapshot  I/Q samples handed to the ESIstream TX  (tx_clk counter)
--   0x10  SAMPLES_RCVD  RO  snapshot  I/Q samples out of the ESIstream RX      (rx_clk counter)
--   0x14  SEQ_ERRORS    RO  snapshot  sequence-number breaks                  (rx_clk)
--   0x18  MARKER_ERRORS RO  snapshot  slot-marker mismatches                  (rx_clk)
--   0x1C  MULTI_ERRORS  RO  snapshot  lanes disagreeing on one sample         (rx_clk)
--   0x20  TX_CLK_COUNT  RO  snapshot  free-running tx_clk cycle counter
--   0x24  RX_CLK_COUNT  RO  snapshot  free-running rx_clk cycle counter
--   0x28  ACLK_COUNT    RO  snapshot  free-running aclk cycle counter, latched with the request
--   0x2C  LINK_DROPS    RO  times link_ready fell since reset (aclk view)
--   0x30  REFCLK_PERIOD RO  aclk cycles in the last REFCLK_WINDOW-cycle window of the reference
--                           clock: 655 at 156.25 MHz (1024 x 100/156.25), 1024 at 100 MHz, 4095 = dead
--   0x34  REFCLK_GOOD_EVENTS RO  rising edges of refclk_valid = automatic transceiver resets issued
--
--   Two snapshots some time apart give the clock ratios: (TX_CLK_COUNT delta) /
--   (ACLK_COUNT delta) should be 1.5625 if the GT user clock really is
--   156.25 MHz against the 100 MHz PL clock -- the first thing to read after
--   programming the SI570.  Pass for tier 2 = the receiver's 24/24 as in tier 1,
--   SAMPLES_SENT = SAMPLES_RCVD = the stimulus length, all three error counters 0.
--
-- Software: the block is /dev/uio1 (generic-uio, petalinux/system-user.dtsi);
-- dogu's opv_play reads it -- refuses to play until link_ready, prints the
-- scoreboard with -q, and reads the link alone with -l.  No other tool
-- touches these registers.
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;

entity esi_link_hw is
    generic (
        ACLK_HZ       : natural := 100_000_000;
        REFCLK_HZ     : natural := 156_250_000;   -- what the monitor expects on gt_refclk_mon
        REFCLK_WINDOW : natural := 1024           -- reference cycles per measurement window
    );
    port (
        -- receiver clock domain (100 MHz PL clock; also the quad/bridge apb3clk)
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        -- I/Q samples in (from the pacer) and out (to the receiver), 32-bit {Q,I} beats
        s_axis_tdata    : in  std_logic_vector(31 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;

        -- AXI-Lite registers (aclk)
        s_axi_awaddr    : in  std_logic_vector(11 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(31 downto 0);
        s_axi_wstrb     : in  std_logic_vector(3 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(11 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(31 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        -- transceiver side (gt_bridge_ip in bypass mode, gt_quad_base)
        tx_clk          : in  std_logic;                          -- bufg_gt(ch0_txoutclk), 156.25 MHz
        rx_clk          : in  std_logic;                          -- bufg_gt(ch0_rxoutclk), 156.25 MHz
        gt_tx_data_ch0  : out std_logic_vector(127 downto 0);     -- -> gt_bridge_ip ch0_txdata_ext (63:0 used)
        gt_tx_data_ch1  : out std_logic_vector(127 downto 0);     -- -> ch1_txdata_ext
        gt_rx_data_ch0  : in  std_logic_vector(127 downto 0);     -- <- ch0_rxdata_ext (63:0 used)
        gt_rx_data_ch1  : in  std_logic_vector(127 downto 0);     -- <- ch1_rxdata_ext
        gt_powergood    : in  std_logic;                          -- gt_quad_base gtpowergood
        gt_lcpll_lock   : in  std_logic;                          -- gt_quad_base hsclk0_lcplllock (not the bridge's lcpll_lock_out: never asserts in bypass mode)
        gt_tx_resetdone : in  std_logic;                          -- gt_bridge_ip tx_resetdone_out
        gt_rx_resetdone : in  std_logic;                          -- gt_bridge_ip rx_resetdone_out
        gt_link_status  : in  std_logic;                          -- gt_bridge_ip link_status_out
        gt_refclk_mon   : in  std_logic;                          -- gt_refclk_buf IBUF_DS_ODIV2 via bufg_gt_ref: the reference clock itself
        gt_reset        : out std_logic;                          -- -> gt_bridge_ip gtreset_in (aclk = apb3clk)
        gt_loopback     : out std_logic_vector(2 downto 0);       -- -> gt_quad_base ch0_loopback and ch1_loopback

        -- for an LED or an ILA
        link_ready      : out std_logic
    );
end entity esi_link_hw;

architecture rtl of esi_link_hw is
    constant NB_LANES : natural := 2;
    constant ID_WORD  : std_logic_vector(31 downto 0) := x"45534931";   -- "ESI1"

    -- registers (aclk)
    signal reg_link_reset : std_logic := '0';
    signal reg_loopback   : std_logic_vector(2 downto 0) := "010";
    signal sync_req_r     : std_logic := '0';                 -- held 16 aclk so the tx_clk side sees the edge
    signal sync_req_cnt   : unsigned(4 downto 0) := (others => '0');
    signal stats_clear_r  : std_logic := '0';
    signal stats_clr_cnt  : unsigned(4 downto 0) := (others => '0');
    signal gt_reset_r     : std_logic := '0';
    signal gt_reset_cnt   : unsigned(3 downto 0) := (others => '0');

    -- reference-clock monitor
    constant REF_EXPECT   : natural := (REFCLK_WINDOW * (ACLK_HZ / 1000)) / (REFCLK_HZ / 1000);   -- 655
    constant REF_TOL      : natural := REF_EXPECT / 40 + 1;                                       -- +/-2.5 %
    signal ref_cnt        : unsigned(15 downto 0) := (others => '0');  -- gt_refclk_mon domain
    signal ref_tog        : std_logic := '0';                          -- toggles every REFCLK_WINDOW ref cycles
    signal ref_tog_a      : std_logic;
    signal ref_tog_d      : std_logic := '0';
    signal win_cnt        : unsigned(11 downto 0) := (others => '0');  -- aclk cycles since the last toggle
    signal ref_period     : unsigned(11 downto 0) := (others => '1');  -- last window, aclk cycles (4095 = dead)
    signal good_streak    : unsigned(3 downto 0) := (others => '0');
    signal bad_streak     : unsigned(1 downto 0) := (others => '0');
    signal refclk_valid   : std_logic := '0';
    signal refclk_valid_d : std_logic := '0';
    signal ref_good_events: unsigned(31 downto 0) := (others => '0');

    -- link status into aclk
    signal xcvr_ready     : std_logic;
    signal lanes_ready_l  : std_logic;                        -- rx_clk
    signal link_ready_l   : std_logic;                        -- rx_clk
    signal lanes_ready_a  : std_logic;
    signal link_ready_a   : std_logic;
    signal link_ready_d   : std_logic := '0';
    signal link_drops     : unsigned(31 downto 0) := (others => '0');

    -- link resets (synchronized 'run' level per domain)
    signal link_run       : std_logic;
    signal tx_rstn, rx_rstn : std_logic;

    -- link-domain counters
    signal samples_sent   : unsigned(31 downto 0);            -- tx_clk
    signal samples_rcvd   : unsigned(31 downto 0);            -- rx_clk
    signal seq_errors     : unsigned(31 downto 0);
    signal marker_errors  : unsigned(31 downto 0);
    signal multi_errors   : unsigned(31 downto 0);
    signal tx_clk_count   : unsigned(31 downto 0) := (others => '0');
    signal rx_clk_count   : unsigned(31 downto 0) := (others => '0');
    signal aclk_count     : unsigned(31 downto 0) := (others => '0');

    -- snapshot handshake: aclk toggles req; each link domain latches its
    -- counters on the (synchronized) edge and toggles its ack back
    signal snap_req_t     : std_logic := '0';
    signal snap_req_tx    : std_logic;  signal snap_req_tx_d : std_logic := '0';
    signal snap_req_rx    : std_logic;  signal snap_req_rx_d : std_logic := '0';
    signal snap_ack_tx_t  : std_logic := '0';
    signal snap_ack_rx_t  : std_logic := '0';
    signal snap_ack_tx_a  : std_logic;
    signal snap_ack_rx_a  : std_logic;
    signal snap_busy      : std_logic;
    signal snap_busy_d    : std_logic := '0';
    signal snap_sent, snap_txclk                                  : unsigned(31 downto 0) := (others => '0');
    signal snap_rcvd, snap_seq, snap_marker, snap_multi, snap_rxclk : unsigned(31 downto 0) := (others => '0');
    signal reg_sent, reg_rcvd, reg_seq, reg_marker, reg_multi, reg_txclk, reg_rxclk, reg_aclk
                          : unsigned(31 downto 0) := (others => '0');

    -- clock-alive detectors
    signal tx_tog         : std_logic := '0';
    signal rx_tog         : std_logic := '0';
    signal tx_tog_a, rx_tog_a : std_logic;
    signal tx_tog_d, rx_tog_d : std_logic := '0';
    signal tx_alive_cnt   : unsigned(7 downto 0) := (others => '1');
    signal rx_alive_cnt   : unsigned(7 downto 0) := (others => '1');
    signal tx_alive, rx_alive : std_logic;

    -- lane data
    signal xcvr_tx        : slv_ser_width_array_n(NB_LANES-1 downto 0);
    signal xcvr_rx        : slv_deser_width_array_n(NB_LANES-1 downto 0);

    -- AXI-Lite
    signal awready_i, wready_i, arready_i : std_logic := '0';
    signal aw_got, w_got  : std_logic := '0';
    signal aw_addr        : std_logic_vector(11 downto 0) := (others => '0');
    signal w_data         : std_logic_vector(31 downto 0) := (others => '0');
    signal bvalid_i       : std_logic := '0';
    signal rvalid_i       : std_logic := '0';
    signal rdata_i        : std_logic_vector(31 downto 0) := (others => '0');
    signal status_word    : std_logic_vector(31 downto 0);
begin

    ---------------------------------------------------------------------------
    -- The link
    ---------------------------------------------------------------------------
    xcvr_ready <= gt_lcpll_lock and gt_tx_resetdone and gt_rx_resetdone;   -- Teledyne's ip_ready
    link_run   <= aresetn and not reg_link_reset;

    u_run_tx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 1)
        port map (clk => tx_clk, reg_async(0) => link_run, reg_sync(0) => tx_rstn);
    u_run_rx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 1)
        port map (clk => rx_clk, reg_async(0) => link_run, reg_sync(0) => rx_rstn);

    u_loop : entity work.esi_link_loop
        generic map (NB_LANES => NB_LANES, IDEAL_LINK => false)
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready,
            tx_clk => tx_clk, tx_rstn => tx_rstn, xcvr_tx_data => xcvr_tx,
            rx_clk => rx_clk, rx_rstn => rx_rstn, xcvr_rx_data => xcvr_rx,
            xcvr_ready => xcvr_ready,
            sync_req => sync_req_r, stats_clear => stats_clear_r,
            link_ready => link_ready_l, lanes_ready => lanes_ready_l,
            seq_errors => seq_errors, marker_errors => marker_errors, multi_errors => multi_errors,
            samples_sent => samples_sent, samples_rcvd => samples_rcvd);

    -- 64 of the bridge's 128 bits per channel, as Teledyne's wrapper does
    gt_tx_data_ch0 <= (127 downto 64 => '0') & xcvr_tx(0);
    gt_tx_data_ch1 <= (127 downto 64 => '0') & xcvr_tx(1);
    xcvr_rx(0)     <= gt_rx_data_ch0(63 downto 0);
    xcvr_rx(1)     <= gt_rx_data_ch1(63 downto 0);

    gt_loopback <= reg_loopback;
    gt_reset    <= gt_reset_r;
    link_ready  <= link_ready_a;

    ---------------------------------------------------------------------------
    -- Link-domain side: free-running clock counters, alive toggles, snapshot
    ---------------------------------------------------------------------------
    p_tx : process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            tx_clk_count  <= tx_clk_count + 1;
            tx_tog        <= not tx_tog;
            snap_req_tx_d <= snap_req_tx;
            if snap_req_tx /= snap_req_tx_d then
                snap_sent     <= samples_sent;
                snap_txclk    <= tx_clk_count;
                snap_ack_tx_t <= not snap_ack_tx_t;
            end if;
        end if;
    end process;

    p_rx : process(rx_clk)
    begin
        if rising_edge(rx_clk) then
            rx_clk_count  <= rx_clk_count + 1;
            rx_tog        <= not rx_tog;
            snap_req_rx_d <= snap_req_rx;
            if snap_req_rx /= snap_req_rx_d then
                snap_rcvd     <= samples_rcvd;
                snap_seq      <= seq_errors;
                snap_marker   <= marker_errors;
                snap_multi    <= multi_errors;
                snap_rxclk    <= rx_clk_count;
                snap_ack_rx_t <= not snap_ack_rx_t;
            end if;
        end if;
    end process;

    u_to_tx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 1)
        port map (clk => tx_clk, reg_async(0) => snap_req_t, reg_sync(0) => snap_req_tx);
    u_to_rx : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 1)
        port map (clk => rx_clk, reg_async(0) => snap_req_t, reg_sync(0) => snap_req_rx);

    u_to_aclk : entity work.ff_synchronizer_array
        generic map (REG_WIDTH => 7)
        port map (clk => aclk,
                  reg_async(0) => snap_ack_tx_t,
                  reg_async(1) => snap_ack_rx_t,
                  reg_async(2) => tx_tog,
                  reg_async(3) => rx_tog,
                  reg_async(4) => lanes_ready_l,
                  reg_async(5) => link_ready_l,
                  reg_async(6) => ref_tog,
                  reg_sync(0)  => snap_ack_tx_a,
                  reg_sync(1)  => snap_ack_rx_a,
                  reg_sync(2)  => tx_tog_a,
                  reg_sync(3)  => rx_tog_a,
                  reg_sync(4)  => lanes_ready_a,
                  reg_sync(5)  => link_ready_a,
                  reg_sync(6)  => ref_tog_a);

    ---------------------------------------------------------------------------
    -- Reference-clock monitor.  In the reference domain: a toggle every
    -- REFCLK_WINDOW cycles.  In aclk: the number of aclk between toggles is
    -- the window's length; REF_EXPECT +/- REF_TOL means the reference is at
    -- REFCLK_HZ.  No toggle for 4096 aclk means no clock at all.
    ---------------------------------------------------------------------------
    p_ref : process(gt_refclk_mon)
    begin
        if rising_edge(gt_refclk_mon) then
            if ref_cnt = REFCLK_WINDOW - 1 then
                ref_cnt <= (others => '0');
                ref_tog <= not ref_tog;
            else
                ref_cnt <= ref_cnt + 1;
            end if;
        end if;
    end process;

    snap_busy <= (snap_req_t xor snap_ack_tx_a) or (snap_req_t xor snap_ack_rx_a);
    tx_alive  <= '0' when tx_alive_cnt = x"FF" else '1';
    rx_alive  <= '0' when rx_alive_cnt = x"FF" else '1';

    ---------------------------------------------------------------------------
    -- aclk housekeeping: counters, alive detectors, snapshot completion, the
    -- control pulses, and one gt_reset after reset so the bridge starts its
    -- sequence without software (Teledyne's wrapper does the same from its
    -- power-on reset).
    ---------------------------------------------------------------------------
    p_aclk : process(aclk)
    begin
        if rising_edge(aclk) then
            aclk_count  <= aclk_count + 1;
            snap_busy_d <= snap_busy;
            tx_tog_d    <= tx_tog_a;
            rx_tog_d    <= rx_tog_a;
            link_ready_d <= link_ready_a;

            ref_tog_d      <= ref_tog_a;
            refclk_valid_d <= refclk_valid;

            if aresetn = '0' then
                win_cnt        <= (others => '0');
                ref_period     <= (others => '1');
                good_streak    <= (others => '0');
                bad_streak     <= (others => '0');
                refclk_valid   <= '0';
                ref_good_events <= (others => '0');
                gt_reset_r    <= '0';
                gt_reset_cnt  <= (others => '0');
                sync_req_r    <= '0';
                sync_req_cnt  <= (others => '0');
                stats_clear_r <= '0';
                stats_clr_cnt <= (others => '0');
                link_drops    <= (others => '0');
                tx_alive_cnt  <= (others => '1');
                rx_alive_cnt  <= (others => '1');
                reg_link_reset <= '0';
                reg_loopback   <= "010";
            else
                -- clock-alive: a toggle seen within the last 255 aclk (2.55 us)
                if tx_tog_a /= tx_tog_d then
                    tx_alive_cnt <= (others => '0');
                elsif tx_alive_cnt /= x"FF" then
                    tx_alive_cnt <= tx_alive_cnt + 1;
                end if;
                if rx_tog_a /= rx_tog_d then
                    rx_alive_cnt <= (others => '0');
                elsif rx_alive_cnt /= x"FF" then
                    rx_alive_cnt <= rx_alive_cnt + 1;
                end if;

                -- link drops
                if link_ready_d = '1' and link_ready_a = '0' then
                    link_drops <= link_drops + 1;
                end if;

                -- snapshot: when both acks have come back, the snap_* registers
                -- have been still for several clocks; copy them
                if snap_busy = '0' and snap_busy_d = '1' then
                    reg_sent   <= snap_sent;   reg_txclk <= snap_txclk;
                    reg_rcvd   <= snap_rcvd;   reg_rxclk <= snap_rxclk;
                    reg_seq    <= snap_seq;    reg_marker <= snap_marker;  reg_multi <= snap_multi;
                end if;

                -- pulses: stretched so the slower-sampling side cannot miss them
                if gt_reset_cnt /= 0 then
                    gt_reset_cnt <= gt_reset_cnt - 1;
                    gt_reset_r   <= '1';
                else
                    gt_reset_r   <= '0';
                end if;
                if sync_req_cnt /= 0 then
                    sync_req_cnt <= sync_req_cnt - 1;
                    sync_req_r   <= '1';
                else
                    sync_req_r   <= '0';
                end if;
                if stats_clr_cnt /= 0 then
                    stats_clr_cnt <= stats_clr_cnt - 1;
                    stats_clear_r <= '1';
                else
                    stats_clear_r <= '0';
                end if;

                -- reference-clock monitor: window length, streaks, validity
                if ref_tog_a /= ref_tog_d then
                    ref_period <= win_cnt + 1;
                    win_cnt    <= (others => '0');
                    if win_cnt + 1 >= REF_EXPECT - REF_TOL and win_cnt + 1 <= REF_EXPECT + REF_TOL then
                        bad_streak <= (others => '0');
                        if good_streak /= 8 then good_streak <= good_streak + 1; end if;
                        if good_streak = 7 then refclk_valid <= '1'; end if;
                    else
                        good_streak <= (others => '0');
                        if bad_streak /= 3 then bad_streak <= bad_streak + 1; end if;
                        if bad_streak >= 1 then refclk_valid <= '0'; end if;
                    end if;
                elsif win_cnt = x"FFF" then                 -- no toggle in 4096 aclk: no clock
                    ref_period   <= (others => '1');
                    good_streak  <= (others => '0');
                    refclk_valid <= '0';
                else
                    win_cnt <= win_cnt + 1;
                end if;

                -- the qualified reset: once, when the reference clock has become good
                if refclk_valid = '1' and refclk_valid_d = '0' then
                    gt_reset_cnt    <= x"8";
                    ref_good_events <= ref_good_events + 1;
                end if;

                -- register writes (both channels captured)
                if aw_got = '1' and w_got = '1' then
                    case aw_addr(7 downto 2) is
                        when "000001" =>                                    -- 0x04 CONTROL
                            reg_link_reset <= w_data(0);
                            if w_data(1) = '1' then sync_req_cnt  <= "10000"; end if;
                            if w_data(2) = '1' then stats_clr_cnt <= "10000"; end if;
                            if w_data(3) = '1' then gt_reset_cnt  <= x"8";   end if;
                            reg_loopback   <= w_data(6 downto 4);
                            if w_data(7) = '1' and snap_busy = '0' then
                                snap_req_t <= not snap_req_t;
                                reg_aclk   <= aclk_count;
                            end if;
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite slave.  Write: accept AW and W independently (either order),
    -- commit when both are in, respond, then re-arm -- the same-cycle-only
    -- shortcut in the older register blocks is what left demod 0x0AC without
    -- a bvalid in the bench (tracker issue, 2026-11-06).  Read: one cycle.
    ---------------------------------------------------------------------------
    s_axi_awready <= awready_i;
    s_axi_wready  <= wready_i;
    s_axi_arready <= arready_i;
    s_axi_bvalid  <= bvalid_i;
    s_axi_bresp   <= "00";
    s_axi_rvalid  <= rvalid_i;
    s_axi_rresp   <= "00";
    s_axi_rdata   <= rdata_i;

    p_axi_w : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                awready_i <= '0'; wready_i <= '0'; aw_got <= '0'; w_got <= '0'; bvalid_i <= '0';
            else
                -- ready while nothing is pending on that channel and no response waits
                awready_i <= not aw_got and not bvalid_i and not (aw_got and w_got);
                wready_i  <= not w_got  and not bvalid_i and not (aw_got and w_got);
                if awready_i = '1' and s_axi_awvalid = '1' then
                    aw_got  <= '1';
                    aw_addr <= s_axi_awaddr;
                    awready_i <= '0';
                end if;
                if wready_i = '1' and s_axi_wvalid = '1' then
                    w_got  <= '1';
                    w_data <= s_axi_wdata;
                    wready_i <= '0';
                end if;
                if aw_got = '1' and w_got = '1' then          -- commit happens in p_aclk this cycle
                    aw_got   <= '0';
                    w_got    <= '0';
                    bvalid_i <= '1';
                end if;
                if bvalid_i = '1' and s_axi_bready = '1' then
                    bvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

    status_word <= (0 => gt_powergood, 1 => gt_lcpll_lock, 2 => gt_tx_resetdone, 3 => gt_rx_resetdone,
                    4 => gt_link_status, 5 => xcvr_ready, 6 => lanes_ready_a, 7 => link_ready_a,
                    8 => snap_busy, 9 => tx_alive, 10 => rx_alive, 11 => refclk_valid, others => '0');

    p_axi_r : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                arready_i <= '0'; rvalid_i <= '0';
            else
                arready_i <= not rvalid_i and not arready_i;
                if arready_i = '1' and s_axi_arvalid = '1' then
                    arready_i <= '0';
                    rvalid_i  <= '1';
                    case s_axi_araddr(7 downto 2) is
                        when "000000" => rdata_i <= ID_WORD;                                   -- 0x00
                        when "000001" => rdata_i <= (0 => reg_link_reset, 4 => reg_loopback(0),   -- 0x04
                                                     5 => reg_loopback(1), 6 => reg_loopback(2), others => '0');
                        when "000010" => rdata_i <= status_word;                               -- 0x08
                        when "000011" => rdata_i <= std_logic_vector(reg_sent);                -- 0x0C
                        when "000100" => rdata_i <= std_logic_vector(reg_rcvd);                -- 0x10
                        when "000101" => rdata_i <= std_logic_vector(reg_seq);                 -- 0x14
                        when "000110" => rdata_i <= std_logic_vector(reg_marker);              -- 0x18
                        when "000111" => rdata_i <= std_logic_vector(reg_multi);               -- 0x1C
                        when "001000" => rdata_i <= std_logic_vector(reg_txclk);               -- 0x20
                        when "001001" => rdata_i <= std_logic_vector(reg_rxclk);               -- 0x24
                        when "001010" => rdata_i <= std_logic_vector(reg_aclk);                -- 0x28
                        when "001011" => rdata_i <= std_logic_vector(link_drops);              -- 0x2C
                        when "001100" => rdata_i <= x"00000" & std_logic_vector(ref_period);            -- 0x30
                        when "001101" => rdata_i <= std_logic_vector(ref_good_events);         -- 0x34
                        when others   => rdata_i <= (others => '0');
                    end case;
                end if;
                if rvalid_i = '1' and s_axi_rready = '1' then
                    rvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
