-------------------------------------------------------------------------------
-- tb_haifuraiya_channelizer_axi.vhd
-- Phase 1 Smoke-Test Testbench for the AXI-Wrapped Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-------------------------------------------------------------------------------
-- SCOPE
-------------------------------------------------------------------------------
-- This testbench validates the AXI-Stream + AXI-Lite WRAPPER on top of
-- haifuraiya_channelizer_top. It does NOT re-run the full
-- 6-test channelizer regression — that's already validated against the
-- bare channelizer entity. Here we test the wrapper-specific behaviors:
--
--   1. AXI-Lite read of VERSION returns 0x00010000 (v0.1.0)
--   2. AXI-Lite write to CONTROL registers reads back correctly
--   3. AXIS input samples flow into the channelizer
--   4. AXIS output produces 64 beats per frame with TDEST=0..63,
--      TLAST asserted exactly on TDEST=63
--   5. FRAME_COUNT increments monotonically
--   6. CHANNEL_POWER[k] reads back non-zero values after data flows,
--      with the active channel showing higher power than inactive ones
--      (DC test puts energy in channel 0; tone test puts it in channel
--      matching the tone bin)
--   7. OUTPUT_SHIFT register affects the output amplitude
--
-- Test pass/fail is reported via NOTE/ERROR severity. Run from Vivado
-- xsim via run_haifuraiya_channelizer_axi_test.tcl.
-------------------------------------------------------------------------------


library std;
use std.textio.all;

library ieee;
use ieee.std_logic_textio.all;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_haifuraiya_channelizer_axi is
    generic (
        -- Clocks between input samples at the channelizer's 100 MHz aclk.
        -- This sets the modeled input sample rate:
        --   SMP_PERIOD = 10  ->  10 MSps  (original design point)
        --   SMP_PERIOD = 5   ->  20 MSps  (LVDS production target)
        -- Override at elaboration without editing source, e.g. in xsim:
        --   set_property -name {xsim.elaborate.xelab.more_options} \
        --       -value {-generic_top "SMP_PERIOD=5"} \
        --       -objects [get_filesets sim_1]
        SMP_PERIOD : integer := 10
    );
end entity tb_haifuraiya_channelizer_axi;

architecture sim of tb_haifuraiya_channelizer_axi is

    ---------------------------------------------------------------------------
    -- Parameters
    ---------------------------------------------------------------------------
    constant CLK_PERIOD       : time     := 10 ns;   -- 100 MHz
    constant N_CHANNELS       : positive := 64;
    constant M_DECIMATION     : positive := 16;      -- production Haifuraiya
    constant DATA_WIDTH       : positive := 16;
    constant ACCUM_WIDTH      : positive := 40;
    constant ADDR_WIDTH       : positive := 12;

    -- Register offsets (must match axi_lite_regs.vhd)
    constant ADDR_VERSION       : integer := 16#000#;
    constant ADDR_CONTROL       : integer := 16#004#;
    constant ADDR_STATUS        : integer := 16#008#;
    constant ADDR_FRAME_COUNT   : integer := 16#00C#;
    constant ADDR_DROPPED       : integer := 16#010#;
    constant ADDR_OUTPUT_SHIFT  : integer := 16#014#;
    constant ADDR_ALPHA1        : integer := 16#018#;
    constant ADDR_ALPHA2        : integer := 16#01C#;
    constant ADDR_POWER_BASE    : integer := 16#100#;

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';

    -- Input AXIS
    signal s_axis_data_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axis_data_tvalid : std_logic := '0';
    signal s_axis_data_tready : std_logic;

    -- Output AXIS
    signal m_axis_chans_tdata  : std_logic_vector(31 downto 0);
    signal m_axis_chans_tvalid : std_logic;
    signal m_axis_chans_tready : std_logic := '1';
    signal m_axis_chans_tdest  : std_logic_vector(7 downto 0);
    signal m_axis_chans_tlast  : std_logic;

    -- AXI-Lite control
    signal s_axi_ctrl_awaddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_axi_ctrl_awvalid : std_logic := '0';
    signal s_axi_ctrl_awready : std_logic;
    signal s_axi_ctrl_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_ctrl_wstrb   : std_logic_vector(3 downto 0)  := "1111";
    signal s_axi_ctrl_wvalid  : std_logic := '0';
    signal s_axi_ctrl_wready  : std_logic;
    signal s_axi_ctrl_bresp   : std_logic_vector(1 downto 0);
    signal s_axi_ctrl_bvalid  : std_logic;
    signal s_axi_ctrl_bready  : std_logic := '0';
    signal s_axi_ctrl_araddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_axi_ctrl_arvalid : std_logic := '0';
    signal s_axi_ctrl_arready : std_logic;
    signal s_axi_ctrl_rdata   : std_logic_vector(31 downto 0);
    signal s_axi_ctrl_rresp   : std_logic_vector(1 downto 0);
    signal s_axi_ctrl_rvalid  : std_logic;
    signal s_axi_ctrl_rready  : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Stimulus / capture state
    ---------------------------------------------------------------------------
    -- Latest sample seen per channel (overwritten as new samples arrive)
    type capture_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(31 downto 0);
    signal chan_capture : capture_array_t := (others => (others => '0'));

    -- Frame structure check
    signal beats_in_frame  : integer := 0;
    signal seen_tdest      : integer := -1;
    signal frame_seq_ok    : boolean := true;
    signal frames_observed : integer := 0;

    -- Test pass/fail counters
    -- Before:
    --signal tests_pass : integer := 0;
    --signal tests_fail : integer := 0;

    -- After (if declared in architecture):
    shared variable tests_pass : integer := 0;
    shared variable tests_fail : integer := 0;

    -- Simulation done flag (lets capture process stop)
    signal running : std_logic := '1';

    -- frue = full regression, false = jump to OPV injection for tuning
    constant RUN_CHANNELIZER_TESTS : boolean := false;

    -- ===== Demod-path integration (added) =====
    constant TARGET_CHANNEL : natural := 0;   -- channel to listen to first

    -- Demod tuning. TODO: re-derive for the channel rate (~625 ksps, SPS ~11.53)
    -- per CHANNELIZER_DEMOD_CONTRACT.md. These placeholders let it elaborate and
    -- exercise the wiring; they will NOT produce lock until set correctly.

    --constant FREQ_WORD_F1  : std_logic_vector(31 downto 0) := x"10000000";  -- TODO
    --constant FREQ_WORD_F2  : std_logic_vector(31 downto 0) := x"30000000";  -- TODO
    --rx_freq_word_f1 = 0x058CD20B   (lower tone, +13550 Hz)
    --rx_freq_word_f2 = 0x10A67621   (upper tone, +40650 Hz)
    --rx_freq_word_f1 = 0x13333333    (0.0750 = centroid − half the offset)
    --rx_freq_word_f2 = 0x39999999    (0.2250 = centroid + half the offset)
    constant FREQ_WORD_F1  : std_logic_vector(31 downto 0) := x"13333333";
    constant FREQ_WORD_F2  : std_logic_vector(31 downto 0) := x"39999999";


    --constant LPF_P_GAIN    : std_logic_vector(23 downto 0) := x"000100";    -- TODO
    --constant LPF_I_GAIN    : std_logic_vector(23 downto 0) := x"000010";    -- TODO
    --constant LPF_ALPHA     : std_logic_vector(23 downto 0) := x"000080";    -- TODO
    --constant LPF_P_SHIFT   : std_logic_vector(7 downto 0)  := x"08";        -- TODO
    --constant LPF_I_SHIFT   : std_logic_vector(7 downto 0)  := x"0C";        -- TODO
    --constant SYM_LOCK_CNT  : std_logic_vector(9 downto 0)  := "0100000000"; -- TODO (256)
    --constant SYM_LOCK_THR  : std_logic_vector(15 downto 0) := x"0400";      -- TODO


    constant LPF_P_GAIN  : std_logic_vector(23 downto 0) := x"7FFFFF";   -- max
    constant LPF_I_GAIN  : std_logic_vector(23 downto 0) := x"7FFFFF";   -- max
    constant LPF_ALPHA   : std_logic_vector(23 downto 0) := x"000000";
    constant LPF_P_SHIFT : std_logic_vector(7 downto 0)  := x"14";       -- 20
    constant LPF_I_SHIFT : std_logic_vector(7 downto 0)  := x"1D";       -- 29
    constant SYM_LOCK_CNT : std_logic_vector(9 downto 0)  := "0010000000"; -- 128 (RDL default)
    constant SYM_LOCK_THR : std_logic_vector(15 downto 0) := x"2710";      -- 10000 (RDL default)


    signal chan_i_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal chan_q_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal rx_svalid   : std_logic := '0';
    signal rx_data     : std_logic;
    signal rx_data_soft: signed(15 downto 0);
    signal rx_dvalid   : std_logic;
    signal lock_f1, lock_f2 : std_logic;
    signal rx_bit_corr : std_logic;
    signal demod_lock  : std_logic;

    signal sb_tdata  : std_logic_vector(2 downto 0);
    signal sb_tvalid : std_logic;
    signal sb_tlast  : std_logic;

    -- integration counters (visible at end-of-sim)
    signal n_target_samps : integer := 0;  -- samples handed to the demod
    signal n_soft_beats   : integer := 0;  -- soft bits emitted
    signal n_soft_frames  : integer := 0;  -- frame_sync frames





begin

    ---------------------------------------------------------------------------
    -- Clock generation
    ---------------------------------------------------------------------------
    p_clk : process
    begin
        while running = '1' loop
            aclk <= '0';
            wait for CLK_PERIOD / 2;
            aclk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- DUT instance
    ---------------------------------------------------------------------------
    u_dut : entity work.haifuraiya_channelizer_axi
        generic map (
            N_CHANNELS              => N_CHANNELS,
            M_DECIMATION            => M_DECIMATION,
            TAPS_PER_BRANCH         => 24,
            DATA_WIDTH              => DATA_WIDTH,
            COEFF_WIDTH             => 16,
            ACCUM_WIDTH             => ACCUM_WIDTH,
            POWER_ALPHA_W           => 18,
            C_S_AXI_CTRL_ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            aclk    => aclk,
            aresetn => aresetn,

            s_axis_data_tdata   => s_axis_data_tdata,
            s_axis_data_tvalid  => s_axis_data_tvalid,
            s_axis_data_tready  => s_axis_data_tready,

            m_axis_chans_tdata  => m_axis_chans_tdata,
            m_axis_chans_tvalid => m_axis_chans_tvalid,
            m_axis_chans_tready => m_axis_chans_tready,
            m_axis_chans_tdest  => m_axis_chans_tdest,
            m_axis_chans_tlast  => m_axis_chans_tlast,

            s_axi_ctrl_awaddr   => s_axi_ctrl_awaddr,
            s_axi_ctrl_awvalid  => s_axi_ctrl_awvalid,
            s_axi_ctrl_awready  => s_axi_ctrl_awready,
            s_axi_ctrl_wdata    => s_axi_ctrl_wdata,
            s_axi_ctrl_wstrb    => s_axi_ctrl_wstrb,
            s_axi_ctrl_wvalid   => s_axi_ctrl_wvalid,
            s_axi_ctrl_wready   => s_axi_ctrl_wready,
            s_axi_ctrl_bresp    => s_axi_ctrl_bresp,
            s_axi_ctrl_bvalid   => s_axi_ctrl_bvalid,
            s_axi_ctrl_bready   => s_axi_ctrl_bready,
            s_axi_ctrl_araddr   => s_axi_ctrl_araddr,
            s_axi_ctrl_arvalid  => s_axi_ctrl_arvalid,
            s_axi_ctrl_arready  => s_axi_ctrl_arready,
            s_axi_ctrl_rdata    => s_axi_ctrl_rdata,
            s_axi_ctrl_rresp    => s_axi_ctrl_rresp,
            s_axi_ctrl_rvalid   => s_axi_ctrl_rvalid,
            s_axi_ctrl_rready   => s_axi_ctrl_rready
        );



    -- TDEST demux: forward ONLY the target channel's I to the demod.
    p_demux : process(aclk)
    begin
        if rising_edge(aclk) then
            rx_svalid <= '0';
            if aresetn = '0' then
                rx_svalid <= '0';
            elsif m_axis_chans_tvalid = '1' and m_axis_chans_tready = '1' then
                if to_integer(unsigned(m_axis_chans_tdest(5 downto 0))) = TARGET_CHANNEL then
                    chan_i_reg     <= m_axis_chans_tdata(15 downto 0);  -- I = TDATA[15:0]
                    chan_q_reg     <= m_axis_chans_tdata(31 downto 16); -- Q = TDATA[31:16]
                    rx_svalid      <= '1';
                    n_target_samps <= n_target_samps + 1;
                end if;
            end if;
        end if;
    end process;

    u_demod : entity work.msk_demodulator
        generic map ( SAMPLE_W => 12 )
        port map (
            clk  => aclk,
            init => not aresetn,
            rx_freq_word_f1 => FREQ_WORD_F1,
            rx_freq_word_f2 => FREQ_WORD_F2,
            discard_rxnco   => (others => '0'),
            lpf_p_gain  => LPF_P_GAIN,  lpf_i_gain  => LPF_I_GAIN,
            lpf_p_shift => LPF_P_SHIFT, lpf_i_shift => LPF_I_SHIFT,
            lpf_freeze  => '0',         lpf_zero    => '0',
            lpf_alpha   => LPF_ALPHA,
            lpf_accum_f1 => open, lpf_accum_f2 => open,
            f1_nco_adjust => open, f2_nco_adjust => open,
            f1_error => open, f2_error => open,
            rx_dec_lbk_ena => '0', rx_dec_lbk_tclk => '0',
            rx_dec_lbk_f1 => (others=>'0'), rx_dec_lbk_f2 => (others=>'0'),
            rx_enable => '1', rx_svalid => rx_svalid, rx_samples => chan_i_reg(13 downto 2), -- change here
            rx_data => rx_data, rx_data_soft => rx_data_soft, rx_dvalid => rx_dvalid,
            symbol_lock_count => SYM_LOCK_CNT, symbol_lock_threshold => SYM_LOCK_THR,
            cst_lock_f1 => lock_f1, cst_lock_f2 => lock_f2,
            cst_lock_time_f1 => open, cst_lock_time_f2 => open,
            cst_unlock_f1 => open, cst_unlock_f2 => open,
            dbg_acc_i_f1 => open, dbg_acc_q_f1 => open, dbg_acc_iq_delta_f1 => open
        );

    rx_bit_corr <= rx_data;                 -- add an invert here if needed
    demod_lock  <= lock_f1 and lock_f2;

    u_fsync : entity work.frame_sync_detector_soft
        port map (
            clk => aclk, reset => not aresetn,
            rx_bit => rx_bit_corr, rx_bit_valid => rx_dvalid, s_axis_soft_tdata => rx_data_soft,
            m_axis_tdata => open, m_axis_tvalid => open, m_axis_tready => '1', m_axis_tlast => open,
            m_axis_soft_bit_tdata => sb_tdata, m_axis_soft_bit_tvalid => sb_tvalid,
            m_axis_soft_bit_tready => '1', m_axis_soft_bit_tlast => sb_tlast,
            frame_sync_locked => open, frames_received => open,
            frame_sync_errors => open, frame_buffer_overflow => open,
            demod_sync_lock => demod_lock,
            debug_state => open, debug_correlation => open, debug_corr_peak => open,
            debug_bit_count => open, debug_missed_syncs => open, debug_consecutive_good => open,
            debug_soft_current => open, debug_soft_quantized => open, debug_byte_v => open
        );

    --------------------------------------------------------------------------
    -- Soft-bit capture process (writes a file for offline opv-decode -3)
    --------------------------------------------------------------------------

    p_soft_cap : process(aclk)
        file g : text open write_mode is "seam_chan_out.txt";
        variable l : line;
    begin
        if rising_edge(aclk) then
            if sb_tvalid = '1' then            -- soft_bit_tready tied '1'
                write(l, to_integer(unsigned(sb_tdata)));
                writeline(g, l);
                n_soft_beats <= n_soft_beats + 1;
                if sb_tlast = '1' then
                    n_soft_frames <= n_soft_frames + 1;
                end if;
            end if;
        end if;
    end process;



    ---------------------------------------------------------------
    -- Capture the channel-0 complex output
    ---------------------------------------------------------------
    p_chan_cap : process(aclk)
        file fc      : text open write_mode is "chan0_iq.txt";
        variable l   : line;
        variable cnt : integer := 0;
    begin
        if rising_edge(aclk) then
            if rx_svalid = '1' and cnt < 8000 then
                write(l, to_integer(signed(chan_i_reg)));
                write(l, string'(" "));
                write(l, to_integer(signed(chan_q_reg)));
                writeline(fc, l);
                cnt := cnt + 1;
            end if;
        end if;
    end process;



    ---------------------------------------------------------------------------
    -- Output AXIS capture
    -- For each accepted beat (TVALID and TREADY both high), latch the data
    -- into chan_capture[TDEST] and check the per-frame TDEST sequence.
    ---------------------------------------------------------------------------
    p_capture : process(aclk)
        variable idx : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                beats_in_frame  <= 0;
                seen_tdest      <= -1;
                frame_seq_ok    <= true;
                frames_observed <= 0;
            elsif m_axis_chans_tvalid = '1' and m_axis_chans_tready = '1' then
                idx := to_integer(unsigned(m_axis_chans_tdest(5 downto 0)));
                chan_capture(idx) <= m_axis_chans_tdata;

                -- Frame sequence check: TDEST should increment 0,1,...,N-1
                -- TLAST should assert exactly on TDEST=N-1
                if seen_tdest = -1 then
                    -- First beat seen after reset; only accept if idx=0
                    if idx /= 0 then
                        frame_seq_ok <= false;
                        report "Capture: first beat after reset had TDEST=" &
                               integer'image(idx) & " (expected 0)"
                            severity warning;
                    end if;
                else
                    if idx /= seen_tdest + 1 then
                        frame_seq_ok <= false;
                        report "Capture: TDEST out of sequence; got " &
                               integer'image(idx) & " expected " &
                               integer'image(seen_tdest + 1)
                            severity warning;
                    end if;
                end if;
                seen_tdest <= idx;
                beats_in_frame <= beats_in_frame + 1;

                if m_axis_chans_tlast = '1' then
                    if idx /= N_CHANNELS - 1 then
                        frame_seq_ok <= false;
                        report "Capture: TLAST asserted on TDEST=" &
                               integer'image(idx) & " (expected " &
                               integer'image(N_CHANNELS - 1) & ")"
                            severity warning;
                    end if;
                    frames_observed <= frames_observed + 1;
                    beats_in_frame  <= 0;
                    seen_tdest      <= -1;
                end if;
            end if;
        end if;
    end process p_capture;





    ---------------------------------------------------------------------------
    -- Main stimulus + verification
    ---------------------------------------------------------------------------
    p_stim : process

        ---------------------------------------------------------------------
        -- AXI-Lite write transaction (combined AW + W, then B accept)
        ---------------------------------------------------------------------
        procedure axi_write(constant addr : in integer;
                            constant data : in integer) is
        begin
            s_axi_ctrl_awaddr  <= std_logic_vector(to_unsigned(addr, ADDR_WIDTH));
            s_axi_ctrl_wdata   <= std_logic_vector(to_unsigned(data, 32));
            s_axi_ctrl_awvalid <= '1';
            s_axi_ctrl_wvalid  <= '1';
            s_axi_ctrl_bready  <= '1';

            -- Wait for both AW and W to handshake
            wait until rising_edge(aclk) and
                       s_axi_ctrl_awready = '1' and
                       s_axi_ctrl_wready  = '1';
            s_axi_ctrl_awvalid <= '0';
            s_axi_ctrl_wvalid  <= '0';

            -- Wait for B response
            wait until rising_edge(aclk) and s_axi_ctrl_bvalid = '1';
            s_axi_ctrl_bready <= '0';
            wait until rising_edge(aclk);
        end procedure;

        ---------------------------------------------------------------------
        -- AXI-Lite read transaction; returns the read data in `data_out`
        ---------------------------------------------------------------------
        procedure axi_read(constant addr     : in  integer;
                           variable data_out : out integer) is
        begin
            s_axi_ctrl_araddr  <= std_logic_vector(to_unsigned(addr, ADDR_WIDTH));
            s_axi_ctrl_arvalid <= '1';
            s_axi_ctrl_rready  <= '1';

            wait until rising_edge(aclk) and s_axi_ctrl_arready = '1';
            s_axi_ctrl_arvalid <= '0';

            wait until rising_edge(aclk) and s_axi_ctrl_rvalid = '1';
            data_out := to_integer(unsigned(s_axi_ctrl_rdata));
            s_axi_ctrl_rready  <= '0';
            wait until rising_edge(aclk);
        end procedure;

        ---------------------------------------------------------------------
        -- Drive one input sample via AXIS
        ---------------------------------------------------------------------
        --procedure send_sample(constant re_val : in integer;
        --                      constant im_val : in integer) is
        --begin
        --    s_axis_data_tdata(DATA_WIDTH - 1 downto 0) <=
        --        std_logic_vector(to_signed(re_val, DATA_WIDTH));
        --    s_axis_data_tdata(31 downto 32 - DATA_WIDTH) <=
        --        std_logic_vector(to_signed(im_val, DATA_WIDTH));
        --    s_axis_data_tvalid <= '1';
        --    wait until rising_edge(aclk) and s_axis_data_tready = '1';
        --    s_axis_data_tvalid <= '0';
        --end procedure;



	--procedure send_sample(constant re_val : in integer;
	--                  constant im_val : in integer) is
	--begin
	--    report "send_sample call: re=" & integer'image(re_val) severity note;
	--    -- Drive new data and assert tvalid
	--    s_axis_data_tdata(DATA_WIDTH - 1 downto 0) <=
	--        std_logic_vector(to_signed(re_val, DATA_WIDTH));
	--    s_axis_data_tdata(31 downto 32 - DATA_WIDTH) <=
	--        std_logic_vector(to_signed(im_val, DATA_WIDTH));
	--    s_axis_data_tvalid <= '1';
	--
	--    -- Wait one clock for the DUT to sample, then loop until handshake
	--    loop
	--        wait until rising_edge(aclk);
	--        exit when s_axis_data_tready = '1';
	--    end loop;

	--    s_axis_data_tvalid <= '0';
	--end procedure;


	--procedure send_sample(constant re_val : in integer;
        --              constant im_val : in integer) is
	--begin
	--    wait until rising_edge(aclk);                 -- align to clock edge
	--    s_axis_data_tdata(DATA_WIDTH - 1 downto 0) <=
	--        std_logic_vector(to_signed(re_val, DATA_WIDTH));
	--    s_axis_data_tdata(31 downto 32 - DATA_WIDTH) <=
	--        std_logic_vector(to_signed(im_val, DATA_WIDTH));
	--    s_axis_data_tvalid <= '1';
	--    wait until rising_edge(aclk);                 -- hold for one full cycle
	--    s_axis_data_tvalid <= '0';
	--end procedure;


	procedure send_sample(constant re_val : in integer;
                      constant im_val : in integer) is
	begin
	    s_axis_data_tdata(DATA_WIDTH - 1 downto 0) <=
	        std_logic_vector(to_signed(re_val, DATA_WIDTH));
	    s_axis_data_tdata(31 downto 32 - DATA_WIDTH) <=
	        std_logic_vector(to_signed(im_val, DATA_WIDTH));
	    s_axis_data_tvalid <= '1';
	    wait for CLK_PERIOD;            -- tvalid high for exactly 1 cycle
	    s_axis_data_tvalid <= '0';
	end procedure;


        ---------------------------------------------------------------------
        -- Pass/fail helpers
        ---------------------------------------------------------------------
        procedure pass(constant msg : in string) is
        begin
            tests_pass := tests_pass + 1;
            report "PASS: " & msg severity note;
        end procedure;

        procedure fail(constant msg : in string) is
        begin
            tests_fail := tests_fail + 1;
            report "FAIL: " & msg severity warning;
        end procedure;

        ---------------------------------------------------------------------
        -- Local variables
        ---------------------------------------------------------------------
        variable rdata          : integer;
        variable max_power      : integer;
        variable max_idx        : integer;
        variable power_k        : integer;
        variable cycles_per_smp : integer;
        variable tone_phase     : real;
        variable tone_re        : integer;
        variable tone_im        : integer;
        constant TONE_BIN       : integer := 16;   -- target CHANNELIZER channel (post-decimator)
        constant TONE_AMP       : integer := 30000;       -- ~92% full scale 30000
        constant DC_LEVEL       : integer := 20000;
        -- SMP_PERIOD (clocks between samples) is now an entity generic so
        -- the input sample rate can be swept without editing source.
        -- 10 -> 10 MSps, 5 -> 20 MSps. See the entity generic declaration.
        variable seed1         : positive := 13;
        variable seed2         : positive := 97;
        variable rnd           : real;
        variable noise_re      : integer;
        variable noise_im      : integer;
        variable n_zero        : integer;
        variable n_rail        : integer;
        variable n_mid         : integer;
        constant NOISE_AMP     : integer := 3000;   -- input peak; RMS ~1700, like the ADC
        constant NOISE_SAMPLES : integer := 15000;  -- enough frames for the ema_2 cascade to settle
        --file fin               : text open read_mode is "opv_chan_stim.txt";
        file fin               : text open read_mode is "cw_tone_27k_10msps.txt";
        variable l             : line;
        variable iv, qv        : integer;
        variable n_fed         : integer := 0;

    begin

        ---------------------------------------------------------------------
        -- Reset
        ---------------------------------------------------------------------
        aresetn <= '0';
        wait for 20 * CLK_PERIOD;
        aresetn <= '1';
        wait for 20 * CLK_PERIOD;


        -- Test Control
        if RUN_CHANNELIZER_TESTS then


        report "================================================";
        report "Phase 1 AXI Wrapper Smoke Test";
        report "================================================";

        ---------------------------------------------------------------------
        -- Test 1: VERSION read returns 0x00010000 (v0.1.0)
        ---------------------------------------------------------------------
        report "--- Test 1: VERSION read ---";
        axi_read(ADDR_VERSION, rdata);
        if rdata = 16#00010000# then
            pass("VERSION = 0x00010000 (v0.1.0)");
        else
            fail("VERSION expected 0x00010000, got 0x" &
                 to_hstring(to_unsigned(rdata, 32)));
        end if;

        ---------------------------------------------------------------------
        -- Test 2: CONTROL register write/read
        ---------------------------------------------------------------------
        report "--- Test 2: CONTROL write/read ---";
        -- After reset, enable should be '1' (default)
        axi_read(ADDR_CONTROL, rdata);
        if to_unsigned(rdata, 32)(1) = '1' then
            pass("CONTROL.enable = 1 after reset");
        else
            fail("CONTROL.enable expected 1 after reset, got " &
                 integer'image(rdata));
        end if;

        -- Disable, then re-enable
        axi_write(ADDR_CONTROL, 0);
        axi_read(ADDR_CONTROL, rdata);
        if rdata = 0 then
            pass("CONTROL writeable to 0");
        else
            fail("CONTROL=0 readback got " & integer'image(rdata));
        end if;
        axi_write(ADDR_CONTROL, 2);  -- re-enable

        ---------------------------------------------------------------------
        -- Test 3: OUTPUT_SHIFT register write/read
        ---------------------------------------------------------------------
        report "--- Test 3: OUTPUT_SHIFT write/read ---";
        axi_read(ADDR_OUTPUT_SHIFT, rdata);
        if rdata = DATA_WIDTH then
            pass("OUTPUT_SHIFT default = " & integer'image(DATA_WIDTH));
        else
            fail("OUTPUT_SHIFT default expected " &
                 integer'image(DATA_WIDTH) & ", got " & integer'image(rdata));
        end if;

        axi_write(ADDR_OUTPUT_SHIFT, 20);
        axi_read(ADDR_OUTPUT_SHIFT, rdata);
        if rdata = 20 then
            pass("OUTPUT_SHIFT writeable to 20");
        else
            fail("OUTPUT_SHIFT=20 readback got " & integer'image(rdata));
        end if;
        -- Restore default
        axi_write(ADDR_OUTPUT_SHIFT, DATA_WIDTH);
        --axi_write(ADDR_OUTPUT_SHIFT, 4); -- do not shift away our entire value

        ---------------------------------------------------------------------
        -- Test 4: STATUS readable, ready bit should be high
        ---------------------------------------------------------------------
        report "--- Test 4: STATUS register ---";
        -- Channelizer's `ready` may take a couple cycles to come up after
        -- reset; give it a few hundred clocks to settle.
        wait for 200 * CLK_PERIOD;
        axi_read(ADDR_STATUS, rdata);
        if to_unsigned(rdata, 32)(0) = '1' then
            pass("STATUS.ready = 1");
        else
            fail("STATUS.ready expected 1, got STATUS=" &
                 integer'image(rdata));
        end if;

        ---------------------------------------------------------------------
        -- Test 5: DC input -> energy in channel 0
        ---------------------------------------------------------------------
        report "--- Test 5: DC input, expect channel 0 hot ---";
        -- Send DC samples for long enough to fill the FIR delay line
        -- and produce many output frames so the EMA filters settle.

        -- DEBUG: try a shift of 16
        axi_write(ADDR_OUTPUT_SHIFT, 16);



        --for i in 0 to 5000 loop
        --    send_sample(DC_LEVEL, 0);
        --    wait for (SMP_PERIOD - 2) * CLK_PERIOD;
        --end loop;


	for i in 0 to 5000 loop
	    send_sample(DC_LEVEL, 0);
	    wait for (SMP_PERIOD - 1) * CLK_PERIOD;  -- 9 cycles ? 10 total
	end loop;


        -- Read all 64 channel powers and find the peak channel
        max_power := 0;
        max_idx   := -1;
        for k in 0 to N_CHANNELS - 1 loop
            axi_read(ADDR_POWER_BASE + 4 * k, power_k);
            if power_k > max_power then
                max_power := power_k;
                max_idx   := k;
            end if;
        end loop;

	-- Skirt shape check — bimodal failure (saturated/zero pattern) won't satisfy this
	report "  Skirt shape:";
	for k in 0 to 5 loop
	    axi_read(ADDR_POWER_BASE + 4 * k, power_k);
	    report "    ch " & integer'image(k) & " = " & integer'image(power_k);
	end loop;
	report "  ...";
	for k in 30 to 33 loop  -- deep stopband expected
	    axi_read(ADDR_POWER_BASE + 4 * k, power_k);
	    report "    ch " & integer'image(k) & " = " & integer'image(power_k);
	end loop;
	report "  ...";
	for k in 58 to 63 loop
	    axi_read(ADDR_POWER_BASE + 4 * k, power_k);
	    report "    ch " & integer'image(k) & " = " & integer'image(power_k);
	end loop;



        report "  Peak channel = " & integer'image(max_idx) &
               "  power = " & integer'image(max_power);
        if max_idx = 0 and max_power > 0 then
            pass("DC test: peak in channel 0 with non-zero power");
        else
            fail("DC test: peak in channel " & integer'image(max_idx) &
                 " (expected 0)");
        end if;




-- Clear EMA state between tests so prior signal content doesn't bleed in
aresetn <= '0';
wait for 200 ns;  -- a few clock cycles
aresetn <= '1';
wait for 1 us;    -- let the design come back up





        ---------------------------------------------------------------------
        -- Test 6: Tone at TONE_BIN -> energy in matching channel
        ---------------------------------------------------------------------
        report "--- Test 6: Tone at bin " & integer'image(TONE_BIN) &
               ", expect channel " & integer'image(TONE_BIN) & " hot ---";
        tone_phase := 0.0;
        for i in 0 to 5000 loop
            -- 2:1 halfband decimator => channelizer runs at half the wrapper rate, so
            -- generate the tone at half the digital frequency (denominator 2*N_CHANNELS)
            -- to land it in channel TONE_BIN. A tone with TONE_BIN >= 32 sits above
            -- wrapper fs/4 and the halfband rejects it (that's what killed the old bin-32).
            tone_re := integer(real(TONE_AMP) *
                cos(2.0 * MATH_PI * real(TONE_BIN) * real(i) / real(2 * N_CHANNELS)));
            tone_im := integer(real(TONE_AMP) *
                sin(2.0 * MATH_PI * real(TONE_BIN) * real(i) / real(2 * N_CHANNELS)));
            send_sample(tone_re, tone_im);
            wait for (SMP_PERIOD - 1) * CLK_PERIOD;
        end loop;

        max_power := 0;
        max_idx   := -1;
        for k in 0 to N_CHANNELS - 1 loop
            axi_read(ADDR_POWER_BASE + 4 * k, power_k);
            if power_k > max_power then
                max_power := power_k;
                max_idx   := k;
            end if;
        end loop;
        report "  Peak channel = " & integer'image(max_idx) &
               "  power = " & integer'image(max_power);
        if max_idx = TONE_BIN and max_power > 0 then
            pass("Tone test: peak in channel " & integer'image(TONE_BIN));
        else
            fail("Tone test: peak in channel " & integer'image(max_idx) &
                 " (expected " & integer'image(TONE_BIN) & ")");
        end if;

        ---------------------------------------------------------------------
        -- Test 7: FRAME_COUNT increments
        ---------------------------------------------------------------------
        report "--- Test 7: FRAME_COUNT incrementing ---";
        axi_read(ADDR_FRAME_COUNT, rdata);
        report "  FRAME_COUNT = " & integer'image(rdata) &
               "  frames observed in capture = " &
               integer'image(frames_observed);
        if rdata > 100 then
            pass("FRAME_COUNT > 100 (we sent lots of samples)");
        else
            fail("FRAME_COUNT expected > 100, got " & integer'image(rdata));
        end if;

        ---------------------------------------------------------------------
        -- Test 8: Frame sequence integrity (from p_capture)
        ---------------------------------------------------------------------
        report "--- Test 8: Frame sequence integrity ---";
        if frame_seq_ok and frames_observed > 100 then
            pass("All observed frames had TDEST=0..63 with TLAST on 63 (" &
                 integer'image(frames_observed) & " frames)");
        elsif not frame_seq_ok then
            fail("Frame sequence anomaly detected in capture");
        else
            fail("Too few frames observed: " &
                 integer'image(frames_observed));
        end if;

        ---------------------------------------------------------------------
        -- Test 9: DROPPED_FRAMES should be zero in this run
        ---------------------------------------------------------------------
        report "--- Test 9: DROPPED_FRAMES ---";
        axi_read(ADDR_DROPPED, rdata);
        if rdata = 0 then
            pass("DROPPED_FRAMES = 0");
        else
            fail("DROPPED_FRAMES expected 0, got " & integer'image(rdata));
        end if;

        ---------------------------------------------------------------------
        -- Test 10: EMA arithmetic saturation regression
        ---------------------------------------------------------------------
        -- Apply sustained DC stress for ~2 ms (about 7x the original wrap
        -- period of ~280 us). Pre-saturation-fix, u_ema_2 sum wrapped past
        -- +2^42 within the first ~280 us under DC_LEVEL=20000 input.
        -- With saturation in place, sum clamps cleanly and channel 0 power
        -- reads back as a bounded positive value indefinitely.
        --
        -- The concurrent sum_overflow_monitor (architecture-level) catches
        -- any wrap event during this stress; this AXI-Lite check verifies
        -- the user-visible output path also stays correct.
        ---------------------------------------------------------------------
        report "--- Test 10: Sustained DC stress, ch 0 power must stay bounded ---";

        -- Clean reset to known state
        aresetn <= '0';
        wait for 20 * CLK_PERIOD;
        aresetn <= '1';
        wait for 20 * CLK_PERIOD;

        -- Apply 15,000 samples of DC at the level that previously caused
        -- wrapping.
        for i in 0 to 15000 loop
            send_sample(DC_LEVEL, 0);
            wait for (SMP_PERIOD - 1) * CLK_PERIOD;
        end loop;


        -- Let EMAs settle on final values
        wait for 100 * CLK_PERIOD;

        -- Read channel 0 power
        axi_read(ADDR_POWER_BASE + 4 * 0, rdata);
        report "  Test 10: ch 0 power after 500 us DC stress = " &
               integer'image(rdata);

        -- Three assertions, in order of specificity:
        --   (a) Power must be positive (high bit clear) -- catches wraparound
        --   (b) Power must be > 0 -- catches stuck-at-zero failure mode
        --   (c) Power must be in a reasonable steady-state range.
        --       Test 5 measured ~640M after 500 us. After 2 ms (~5x as much
        --       integration time), expect EMA closer to its true steady
        --       state -- somewhere in [400M, 1.0B] is plausible. Tighten
        --       this bound once you observe the actual converged value.
        if rdata < 0 then
            -- VHDL integer is signed; rdata < 0 means MSB of 32-bit register set
            fail("Test 10: ch 0 power " & integer'image(rdata) &
                 " has MSB set - EMA may have wrapped");
        elsif rdata = 0 then
            fail("Test 10: ch 0 power is zero - EMA may be stuck or disabled");


        --elsif rdata < 600_000_000 or rdata > 700_000_000 then
        --    fail("Test 10: ch 0 power " & integer'image(rdata) &
        --         " outside expected steady-state [600M, 700M]");


	elsif rdata < 2_000_000 or rdata > 4_000_000 then
	    fail("Test 10: ch 0 power " & integer'image(rdata) &
	         " outside expected steady-state [2M, 4M] for PROD_W=51");



        else
            pass("Test 10: EMA bounded under sustained DC, ch 0 = " &
                 integer'image(rdata));
        end if;

        ---------------------------------------------------------------------
        -- Test 11: BROADBAND NOISE  (the real-antenna regime)
        ---------------------------------------------------------------------
        report "--- Test 11: broadband noise, reproduce the hardware bimodal ---";

        -- NO aresetn toggle: a register write in the first cycles out of
        -- aresetn hangs the AXI-Lite handshake. Clear the EMAs via the soft-
        -- reset bit instead (core_reset <= not aresetn OR ctrl_soft_reset).
        axi_write(ADDR_OUTPUT_SHIFT, 14);   -- match the board
        axi_write(ADDR_CONTROL, 1);         -- soft reset: core_reset=1, clears EMA cascade
        axi_write(ADDR_CONTROL, 2);         -- release + enable: core_reset=0, run
        -- alpha defaults are already 4096/64 (correct) -- no alpha writes needed

        for i in 0 to NOISE_SAMPLES - 1 loop
            uniform(seed1, seed2, rnd);
            noise_re := integer(round((rnd - 0.5) * 2.0 * real(NOISE_AMP)));
            uniform(seed1, seed2, rnd);
            noise_im := integer(round((rnd - 0.5) * 2.0 * real(NOISE_AMP)));
            send_sample(noise_re, noise_im);
            wait for (SMP_PERIOD - 1) * CLK_PERIOD;
        end loop;

        wait for 200 * CLK_PERIOD;

        n_zero := 0; n_rail := 0; n_mid := 0;
        for k in 0 to N_CHANNELS - 1 loop
            axi_read(ADDR_POWER_BASE + 4 * k, power_k);
            report "    ch " & integer'image(k) & " = 0x" &
                   to_hstring(to_unsigned(power_k, 32));
            if power_k = 0 then
                n_zero := n_zero + 1;
            elsif power_k = 16#7FFFFFFF# then
                n_rail := n_rail + 1;
            else
                n_mid := n_mid + 1;
            end if;
        end loop;
        report "  NOISE RESULT: zero=" & integer'image(n_zero) &
               "  railed(0x7FFFFFFF=-1)=" & integer'image(n_rail) &
               "  intermediate=" & integer'image(n_mid);
        if n_mid = 0 then
            fail("Test 11: NO intermediate values -- BIMODAL REPRODUCED IN SIM.");
        else
            pass("Test 11: " & integer'image(n_mid) & " channels intermediate.");
        end if;


        -- Test control
        end if;


    -- ===== Phase 2: Opulent Voice burst through the channelizer into the demod =====
    report "=== OPV stimulus phase: channel " & integer'image(TARGET_CHANNEL) & " ===" severity note;
    s_axis_data_tvalid <= '0';
    wait for 1 us;                           -- flush the tone-test tail out of the pipeline

while not endfile(fin) loop
    readline(fin, l);
    read(l, iv);
    read(l, qv);
    s_axis_data_tdata(15 downto 0)  <= std_logic_vector(to_signed(iv, 16));
    s_axis_data_tdata(31 downto 16) <= std_logic_vector(to_signed(qv, 16));
    s_axis_data_tvalid <= '1';
    wait until rising_edge(aclk) and s_axis_data_tready = '1';   -- sample accepted
    n_fed := n_fed + 1;
    s_axis_data_tvalid <= '0';                                   -- de-assert between samples
    for k in 1 to SMP_PERIOD-1 loop                              -- idle 9 clocks -> 10 MHz
        wait until rising_edge(aclk);
    end loop;
end loop;
s_axis_data_tvalid <= '0';



--original code replaced with above
--    while not endfile(fin) loop
--        readline(fin, l);
--        read(l, iv);
--        read(l, qv);
--        s_axis_data_tdata(15 downto 0)  <= std_logic_vector(to_signed(iv, 16));
--        s_axis_data_tdata(31 downto 16) <= std_logic_vector(to_signed(qv, 16));
--       s_axis_data_tvalid <= '1';
--        wait until rising_edge(aclk) and s_axis_data_tready = '1';
--        n_fed := n_fed + 1;
--    end loop;
--    s_axis_data_tvalid <= '0';




    report "OPV phase fed " & integer'image(n_fed) & " samples" severity note;
    wait for 50 us;                          -- let the demod lock + frame_sync drain soft frames
    report "DEMOD PATH: target samples=" & integer'image(n_target_samps)
         & "  soft beats=" & integer'image(n_soft_beats)
         & "  soft frames=" & integer'image(n_soft_frames) severity note;

        ---------------------------------------------------------------------
        -- Summary
        ---------------------------------------------------------------------
        report "================================================";
        report "Phase 1 AXI Wrapper Smoke Test COMPLETE";
        report "  PASS: " & integer'image(tests_pass);
        report "  FAIL: " & integer'image(tests_fail);
        report "================================================";

        report "DEMOD PATH: target samples=" & integer'image(n_target_samps)
         & "  soft beats=" & integer'image(n_soft_beats)
         & "  soft frames=" & integer'image(n_soft_frames) severity note;

        if tests_fail = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "TESTS FAILED: " & integer'image(tests_fail)
                severity error;
        end if;

        running <= '0';
        wait for 5 * CLK_PERIOD;
        finish;
    end process p_stim;

end architecture sim;
