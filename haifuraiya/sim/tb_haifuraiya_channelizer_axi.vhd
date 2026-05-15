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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_haifuraiya_channelizer_axi is
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
    signal tests_pass : integer := 0;
    signal tests_fail : integer := 0;

    -- Simulation done flag (lets capture process stop)
    signal running : std_logic := '1';

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
            COEFF_FILE              => "haifuraiya_coeffs.hex",
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


	procedure send_sample(constant re_val : in integer;
                      constant im_val : in integer) is
	begin
	    wait until rising_edge(aclk);                 -- align to clock edge
	    s_axis_data_tdata(DATA_WIDTH - 1 downto 0) <=
	        std_logic_vector(to_signed(re_val, DATA_WIDTH));
	    s_axis_data_tdata(31 downto 32 - DATA_WIDTH) <=
	        std_logic_vector(to_signed(im_val, DATA_WIDTH));
	    s_axis_data_tvalid <= '1';
	    wait until rising_edge(aclk);                 -- hold for one full cycle
	    s_axis_data_tvalid <= '0';
	end procedure;



        ---------------------------------------------------------------------
        -- Pass/fail helpers
        ---------------------------------------------------------------------
        procedure pass(constant msg : in string) is
        begin
            tests_pass <= tests_pass + 1;
            report "PASS: " & msg severity note;
        end procedure;

        procedure fail(constant msg : in string) is
        begin
            tests_fail <= tests_fail + 1;
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
        constant TONE_BIN       : integer := 16;          -- known bin
        constant TONE_AMP       : integer := 30000;       -- ~92% full scale
        constant DC_LEVEL       : integer := 20000;
        -- Cycles between samples at 10 MSps with 100 MHz clock
        constant SMP_PERIOD     : integer := 10;
    begin

        ---------------------------------------------------------------------
        -- Reset
        ---------------------------------------------------------------------
        aresetn <= '0';
        wait for 20 * CLK_PERIOD;
        aresetn <= '1';
        wait for 20 * CLK_PERIOD;

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

        for i in 0 to 5000 loop
            send_sample(DC_LEVEL, 0);
            wait for (SMP_PERIOD - 2) * CLK_PERIOD;
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
        report "  Peak channel = " & integer'image(max_idx) &
               "  power = " & integer'image(max_power);
        if max_idx = 0 and max_power > 0 then
            pass("DC test: peak in channel 0 with non-zero power");
        else
            fail("DC test: peak in channel " & integer'image(max_idx) &
                 " (expected 0)");
        end if;

        ---------------------------------------------------------------------
        -- Test 6: Tone at TONE_BIN -> energy in matching channel
        ---------------------------------------------------------------------
        report "--- Test 6: Tone at bin " & integer'image(TONE_BIN) &
               ", expect channel " & integer'image(TONE_BIN) & " hot ---";
        tone_phase := 0.0;
        for i in 0 to 5000 loop
            tone_re := integer(real(TONE_AMP) *
                cos(2.0 * MATH_PI * real(TONE_BIN) * real(i) /
                    real(N_CHANNELS)));
            tone_im := integer(real(TONE_AMP) *
                sin(2.0 * MATH_PI * real(TONE_BIN) * real(i) /
                    real(N_CHANNELS)));
            send_sample(tone_re, tone_im);
            wait for (SMP_PERIOD - 2) * CLK_PERIOD;
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
        -- Summary
        ---------------------------------------------------------------------
        report "================================================";
        report "Phase 1 AXI Wrapper Smoke Test COMPLETE";
        report "  PASS: " & integer'image(tests_pass);
        report "  FAIL: " & integer'image(tests_fail);
        report "================================================";

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
