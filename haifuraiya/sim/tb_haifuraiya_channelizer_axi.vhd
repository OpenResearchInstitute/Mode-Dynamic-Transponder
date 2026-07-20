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
        SMP_PERIOD : integer := 5
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

    -- s_axi_demod driver signals (was tied idle at the DUT; now driven so the
    -- bench can write the demod register file and bracket its init)
    signal s_axi_demod_awaddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_axi_demod_awvalid : std_logic := '0';
    signal s_axi_demod_awready : std_logic;
    signal s_axi_demod_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_demod_wstrb   : std_logic_vector(3 downto 0)  := "1111";
    signal s_axi_demod_wvalid  : std_logic := '0';
    signal s_axi_demod_wready  : std_logic;
    signal s_axi_demod_bresp   : std_logic_vector(1 downto 0);
    signal s_axi_demod_bvalid  : std_logic;
    signal s_axi_demod_bready  : std_logic := '0';
    signal s_axi_demod_araddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_axi_demod_arvalid : std_logic := '0';
    signal s_axi_demod_arready : std_logic;
    signal s_axi_demod_rdata   : std_logic_vector(31 downto 0);
    signal s_axi_demod_rresp   : std_logic_vector(1 downto 0);
    signal s_axi_demod_rvalid  : std_logic;
    signal s_axi_demod_rready  : std_logic := '0';

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

    -- true = full regression, false = jump to OPV injection for tuning
    constant RUN_CHANNELIZER_TESTS : boolean := false;

    -- Bracket bypass. true = run the 16-write demod init bracket (test the demod
    -- path). false = skip it, going channelizer-enable -> injection directly,
    -- exactly like the old bench that ran the channelizer fine. Flip to false to
    -- prove the channelizer + feed still work, isolating the bracket as suspect.
    constant DO_DEMOD_BRACKET : boolean := true;

    -- ===== Demod-path integration (added) =====
    constant TARGET_INPUT_BIN : natural := 5; -- input tone bin to listen to
    constant TARGET_CHANNEL : natural := TARGET_INPUT_BIN;   -- fix landed: arithmetic numbering

    --rx_freq_word_f1 = 0x058CD20B   (lower tone, +13550 Hz)?
    --rx_freq_word_f2 = 0xFA732DF5   (upper tone, -13550 Hz)?
    --rx_freq_word_f2 = 0x10A67621   (upper tone, +40650 Hz)
    --rx_freq_word_f1 = 0x13333333    (0.0750 = centroid − half the offset)
    --rx_freq_word_f2 = 0x39999999    (0.2250 = centroid + half the offset)
    --rx_freq_word_f1 = 0x278E9F6B    real msk_demod
    --rx_freq_word_f2 = 0x32A84381    real msk_demod
    constant FREQ_WORD_F1 : std_logic_vector(31 downto 0) := x"FA732DF5"; -- complex lower
    constant FREQ_WORD_F2 : std_logic_vector(31 downto 0) := x"058CD20B"; -- complex upper



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
    --constant LPF_P_SHIFT : std_logic_vector(7 downto 0)  := x"14";       -- 20
    --constant LPF_I_SHIFT : std_logic_vector(7 downto 0)  := x"1D";       -- 29
    constant SYM_LOCK_CNT : std_logic_vector(9 downto 0)  := "0010000000"; -- 128 (RDL default)
    constant SYM_LOCK_THR : std_logic_vector(15 downto 0) := x"0008"; -- was 0x0018 (decimal 24)

    signal chan_i_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal chan_q_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal dbg_soft_corr_s : std_logic_vector(15 downto 0);
    signal dbg_sym_valid_s : std_logic;
    signal rx_svalid   : std_logic := '0';
    signal lock_f1, lock_f2 : std_logic;

    signal sb_tdata  : std_logic_vector(2 downto 0);
    signal sb_tvalid : std_logic;
    signal sb_tlast  : std_logic;

    signal sb_tready         : std_logic := '1';                 -- drain the soft-bit stream
    signal frame_sync_locked : std_logic;
    signal frames_received   : std_logic_vector(31 downto 0);

    -- integration counters (visible at end-of-sim)
    signal n_target_samps : integer := 0;  -- samples handed to the demod
                                           -- (counted by p_count_target)
    signal n_soft_beats   : integer := 0;  -- soft bits emitted
    signal n_soft_frames  : integer := 0;  -- frame_sync frames
    signal n_soft_raw     : natural := 0;
    signal dbg_f1_err_s : std_logic_vector(31 downto 0) := (others => '0');




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









u_rx : entity work.haifuraiya_rx_axi
    generic map (
        TARGET_CHANNEL           => TARGET_CHANNEL,
        COMPLEX_INPUT            => true,
        N_CHANNELS               => N_CHANNELS,
        M_DECIMATION             => M_DECIMATION,
        C_S_AXI_CTRL_ADDR_WIDTH  => ADDR_WIDTH,
        C_S_AXI_DEMOD_ADDR_WIDTH => ADDR_WIDTH
    )
    port map (
        aclk => aclk, aresetn => aresetn,

        -- 20 Msps stimulus
        s_axis_data_tdata  => s_axis_data_tdata,
        s_axis_data_tvalid => s_axis_data_tvalid,
        s_axis_data_tready => s_axis_data_tready,

        -- soft-bit out
        m_axis_soft_bit_tdata  => sb_tdata,
        m_axis_soft_bit_tvalid => sb_tvalid,
        m_axis_soft_bit_tready => sb_tready,
        m_axis_soft_bit_tlast  => sb_tlast,

        -- channelizer AXI-Lite passthrough (unchanged)
        s_axi_ctrl_awaddr  => s_axi_ctrl_awaddr,  s_axi_ctrl_awvalid => s_axi_ctrl_awvalid,
        s_axi_ctrl_awready => s_axi_ctrl_awready, s_axi_ctrl_wdata   => s_axi_ctrl_wdata,
        s_axi_ctrl_wstrb   => s_axi_ctrl_wstrb,   s_axi_ctrl_wvalid  => s_axi_ctrl_wvalid,
        s_axi_ctrl_wready  => s_axi_ctrl_wready,  s_axi_ctrl_bresp   => s_axi_ctrl_bresp,
        s_axi_ctrl_bvalid  => s_axi_ctrl_bvalid,  s_axi_ctrl_bready  => s_axi_ctrl_bready,
        s_axi_ctrl_araddr  => s_axi_ctrl_araddr,  s_axi_ctrl_arvalid => s_axi_ctrl_arvalid,
        s_axi_ctrl_arready => s_axi_ctrl_arready, s_axi_ctrl_rdata   => s_axi_ctrl_rdata,
        s_axi_ctrl_rresp   => s_axi_ctrl_rresp,   s_axi_ctrl_rvalid  => s_axi_ctrl_rvalid,
        s_axi_ctrl_rready  => s_axi_ctrl_rready,

        -- demod AXI-Lite: now driven by the bench (axi_write_demod / axi_read_demod)
        s_axi_demod_awaddr  => s_axi_demod_awaddr,  s_axi_demod_awvalid => s_axi_demod_awvalid,
        s_axi_demod_awready => s_axi_demod_awready,
        s_axi_demod_wdata   => s_axi_demod_wdata,   s_axi_demod_wstrb   => s_axi_demod_wstrb,
        s_axi_demod_wvalid  => s_axi_demod_wvalid,  s_axi_demod_wready  => s_axi_demod_wready,
        s_axi_demod_bresp   => s_axi_demod_bresp,   s_axi_demod_bvalid  => s_axi_demod_bvalid,
        s_axi_demod_bready  => s_axi_demod_bready,
        s_axi_demod_araddr  => s_axi_demod_araddr,  s_axi_demod_arvalid => s_axi_demod_arvalid,
        s_axi_demod_arready => s_axi_demod_arready,
        s_axi_demod_rdata   => s_axi_demod_rdata,   s_axi_demod_rresp   => s_axi_demod_rresp,
        s_axi_demod_rvalid  => s_axi_demod_rvalid,  s_axi_demod_rready  => s_axi_demod_rready,

        -- watch these
        frame_sync_locked => frame_sync_locked, frames_received => frames_received,
        cst_lock_f1 => lock_f1, cst_lock_f2 => lock_f2,

        -- debug tap -> TB capture signals
        dbg_tgt_i => chan_i_reg, dbg_tgt_q => chan_q_reg, dbg_tgt_valid => rx_svalid,
        dbg_soft_corr => dbg_soft_corr_s, dbg_sym_valid => dbg_sym_valid_s
    );

    -- count samples actually handed to the demod (restores the lost
    -- incrementer behind the "DEMOD PATH: target samples" report)
    p_count_target : process(aclk)
    begin
        if rising_edge(aclk) then
            if rx_svalid = '1' then
                n_target_samps <= n_target_samps + 1;
            end if;
        end if;
    end process;
























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


    --------------------------------------------------------------------------
    -- Raw soft capture. debug_soft_quantized tells you WHICH code; this tells
    -- you WHERE the thresholds belong.
    --   QUANT_THR = mean|soft| / 3.5 * {1,2,3}
    -- the ratio opv_demod.hpp's FrameDecoder::decode() forces:
    --   n = (-soft/scale)*3.5 + 3.5,  scale = mean|soft| over the frame.
    -- dbg_soft_corr is rx_data_soft AFTER the rx_invert correction, which is
    -- exactly what the frame sync correlator and the quantiser see.
    --------------------------------------------------------------------------
    p_soft_raw_cap : process(aclk)
        file     fr : text open write_mode is "soft_raw.txt";
        variable lr : line;
    begin
        if rising_edge(aclk) then
            if dbg_sym_valid_s = '1' then
                write(lr, to_integer(signed(dbg_soft_corr_s)));
                writeline(fr, lr);
                n_soft_raw <= n_soft_raw + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Capture the channel-0 complex output
    ---------------------------------------------------------------
    p_chan_cap : process(aclk)
        file fc      : text open write_mode is "channel_iq.txt";
        variable l   : line;
        variable cnt : integer := 0;
    begin
        if rising_edge(aclk) then
            if rx_svalid = '1' and cnt < 60000 then
                write(l, to_integer(signed(chan_i_reg)));
                write(l, string'(" "));
                write(l, to_integer(signed(chan_q_reg)));
                writeline(fc, l);
                cnt := cnt + 1;
            end if;
        end if;
    end process;


    ---------------------------------------------------------------
    -- Capture f1_error (= cd_ang, carrier phase error) once per symbol
    -- Gate on value-change: f1_error updates only at dump, holds otherwise,
    -- so this yields one sample/symbol with no held repeats. No 2008 needed.
    ---------------------------------------------------------------
    p_f1_error_cap : process(aclk)
        file file_f1  : text open write_mode is "f1_error.txt";
        variable lf1  : line;
        variable prev : std_logic_vector(31 downto 0) := (others => '0');
    begin
        if rising_edge(aclk) then
            if dbg_f1_err_s /= prev then
                write(lf1, to_integer(signed(dbg_f1_err_s)));
                writeline(file_f1, lf1);
                prev := dbg_f1_err_s;
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
        -- AXI-Lite WRITE to the DEMOD slave (s_axi_demod).
        -- Data is std_logic_vector, not integer: the freq words (0xFA732DF5)
        -- overflow VHDL's 32-bit signed integer. Same single-beat handshake
        -- as the channelizer slave (AW+W together, then B).
        ---------------------------------------------------------------------
        procedure axi_write_demod(constant addr : in integer;
                                  constant data : in std_logic_vector(31 downto 0)) is
            variable aw_done, w_done : boolean := false;
            variable to_cnt          : integer := 0;
        begin
            s_axi_demod_awaddr  <= std_logic_vector(to_unsigned(addr, ADDR_WIDTH));
            s_axi_demod_wdata   <= data;
            s_axi_demod_awvalid <= '1';
            s_axi_demod_wvalid  <= '1';
            s_axi_demod_bready  <= '1';
            -- Accept AW and W in EITHER order; do not require the same edge.
            aw_done := false;  w_done := false;
            while not (aw_done and w_done) loop
                wait until rising_edge(aclk);
                if s_axi_demod_awready = '1' then s_axi_demod_awvalid <= '0'; aw_done := true; end if;
                if s_axi_demod_wready  = '1' then s_axi_demod_wvalid  <= '0'; w_done  := true; end if;
                to_cnt := to_cnt + 1;
                assert to_cnt < 1000
                    report "TIMEOUT in axi_write_demod: awready/wready never asserted (addr 0x" &
                           to_hstring(to_unsigned(addr, 16)) & ")" severity failure;
            end loop;
            -- B-channel response, now with its own timeout. THIS is the wait
            -- that ran silently to 62 ms: AW and W were accepted but bvalid
            -- never came back, and there was no guard here.
            to_cnt := 0;
            loop
                wait until rising_edge(aclk);
                exit when s_axi_demod_bvalid = '1';
                to_cnt := to_cnt + 1;
                assert to_cnt < 1000
                    report "TIMEOUT waiting for bvalid in axi_write_demod (addr 0x" &
                           to_hstring(to_unsigned(addr, 16)) &
                           ") -- slave took the write but never responded" severity failure;
            end loop;
            s_axi_demod_bready <= '0';
            wait until rising_edge(aclk);
        end procedure;

        ---------------------------------------------------------------------
        -- AXI-Lite READ from the DEMOD slave; returns data in `data_out`.
        ---------------------------------------------------------------------
        procedure axi_read_demod(constant addr     : in  integer;
                                 variable data_out : out std_logic_vector(31 downto 0)) is
        begin
            s_axi_demod_araddr  <= std_logic_vector(to_unsigned(addr, ADDR_WIDTH));
            s_axi_demod_arvalid <= '1';
            s_axi_demod_rready  <= '1';
            wait until rising_edge(aclk) and s_axi_demod_arready = '1';
            s_axi_demod_arvalid <= '0';
            wait until rising_edge(aclk) and s_axi_demod_rvalid = '1';
            data_out := s_axi_demod_rdata;
            s_axi_demod_rready  <= '0';
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
        variable v_demod_ver    : std_logic_vector(31 downto 0);
        variable sl_wait        : integer := 0;
        variable power_k        : integer;
        variable cycles_per_smp : integer;
        variable tone_phase     : real;
        variable tone_re        : integer;
        variable tone_im        : integer;
        constant TONE_BIN       : integer := 16;   -- target CHANNELIZER channel (post-decimator) 
                                                   -- this is the INPUT frequency bin (below halfband cutoff)
        constant TONE_EXPECT    : integer := N_CHANNELS - TONE_BIN;  -- OUTPUT channel after commutator reversal = 48
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
        --file fin               : text open read_mode is "tone_plus.txt";
        file fin               : text open read_mode is "opv_chan_stim.txt";
        --file fin               : text open read_mode is "opv_chan_stim.txt";
        --file fin               : text open read_mode is "cw_tone_27k_10msps.txt";
        variable l             : line;
        variable iv, qv        : integer;
        variable n_fed         : integer := 0;
        variable tready_to     : integer := 0;   -- timeout counter for the tready wait

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
               ", expect channel " & integer'image(TONE_EXPECT) & " hot ---";
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

        if max_idx = TONE_EXPECT and max_power > 0 then
            pass("Tone test: peak in channel " & integer'image(TONE_EXPECT));
        else
            fail("Tone test: peak in channel " & integer'image(max_idx) &
                 " (expected " & integer'image(TONE_EXPECT) & ")");
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
        report "--- frame-structure integrity covered by the bare-core regression.";
        report "--- m_axis_chans not exposed in the u_rx-wrapped harness.";
        report "----------------------------------------------------------";
        report "-- Test 8 retired with full honors                      --";
        report "----------------------------------------------------------";
        --if frame_seq_ok and frames_observed > 100 then
        --    pass("All observed frames had TDEST=0..63 with TLAST on 63 (" &
        --         integer'image(frames_observed) & " frames)");
        --elsif not frame_seq_ok then
        --    fail("Frame sequence anomaly detected in capture");
        --else
        --    fail("Too few frames observed: " &
        --         integer'image(frames_observed));
        --end if;

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

	elsif rdata < 2_000_000 or rdata > 5_000_000 then
	    fail("Test 10: ch 0 power " & integer'image(rdata) &
	         " outside expected steady-state [2M, 5M] for PROD_W=51");
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
        else


    report "===============================================================================";
    report "===== Phase 2: Opulent Voice burst through the channelizer into the demod =====";
    report "=== OPV stimulus phase: channel " & integer'image(TARGET_CHANNEL) & " ===" severity note;
    report "===============================================================================";

    s_axis_data_tvalid <= '0';
    wait for 1 us;                           -- flush the tone-test tail out of the pipeline

    -- Configure the channelizer to match the board before feeding the burst
    axi_write(ADDR_OUTPUT_SHIFT, 14);        -- match the board: 4x more channel amplitude than default 16
    
    -- POWER_ALPHA1/2 set the power-detector EMA time constants:
    --     tau = 2^18 / ALPHA  channel samples,  at 625 ksps
    -- The normalizer's gain is GAIN_TARGET/sqrt(power), so the AGC settling
    -- time IS the power detector's settling time. Every OPV transmission opens
    -- with one 40 ms preamble frame, so the gain must converge inside 40 ms.
    --   ALPHA2 =  64 -> tau 6.55 ms -> 5*tau = 32.8 ms   (7 ms of margin)
    --   ALPHA2 = 256 -> tau 1.64 ms -> 5*tau =  8.2 ms   (32 ms of margin)
    -- Costs slightly noisier CHANNEL_POWER telemetry, which Bouro can average.
    -- Do not leave these to reset defaults. GAIN_MANUAL taught us that.
    axi_write(ADDR_ALPHA1, 4096);   -- tau1 = 64 samples = 0.10 ms
    axi_write(ADDR_ALPHA2,  256);   -- tau2 = 1024 samples = 1.64 ms

    axi_write(ADDR_CONTROL, 1);              -- soft reset (bit0=1): core_reset=1, clears the EMA cascade
    axi_write(ADDR_CONTROL, 2);              -- release + enable (bit1=1): core_reset=0, run
    wait for 2 us;                           -- let the reset settle / pipeline re-prime before the burst
    report "MILESTONE 1: channelizer configured + enabled" severity note;

    -- =========================================================================
    -- DEMOD INIT BRACKET
    -- Learned from the standalone msk_top bench: MSK_INIT=1 -> write all config
    -- -> MSK_INIT=0. The channelizer is up and flowing; hold the demod in init,
    -- configure it, then release it ONTO the live channel output. Recall
    -- init = reset_h OR demod_init, so writing the bit re-asserts init even
    -- though reset_h fell long ago. This is the step the old bench could not do
    -- (s_axi_demod was tied idle), and the reason the demod never initialized.
    -- =========================================================================
    if DO_DEMOD_BRACKET then
    -- VERSION GATE: which RTL is actually bound in this sim?
    -- Read DEMOD_VERSION (0x000) BEFORE the first write. Reads ride AR/R,
    -- independent of the AW/W/B channel that has been hanging, so this
    -- returns even if the 0x05C write later stalls.
    --   0x00050000 -> v0.5.0, the current source is bound. Bracket is real RTL.
    --   0x0003xxxx -> a stale v0.3 register file is bound; purge IP cache/gen.
    axi_read_demod(16#000#, v_demod_ver);
    report "DEMOD_VERSION readback = 0x" & to_hstring(v_demod_ver) severity note;

    axi_write_demod(16#05C#, x"00000001");   -- DEMOD_INIT = 1 : hold the loops in reset
    axi_write_demod(16#004#, x"00000000");   -- CONTROL: rx_invert = 0 (coordinate with bring-up.sh)
    axi_write_demod(16#008#, FREQ_WORD_F1);  -- FREQ_F1   -13550 Hz @ 625 ksps
    axi_write_demod(16#00C#, FREQ_WORD_F2);  -- FREQ_F2   +13550 Hz
    axi_write_demod(16#010#, x"00000033");   -- LPF_P_GAIN
    axi_write_demod(16#014#, x"00000007");   -- LPF_I_GAIN
    axi_write_demod(16#018#, x"00000000");   -- LPF_ALPHA  (bring-up.sh uses 0x80; standalone used 0 -- A/B if marginal)
    axi_write_demod(16#01C#, x"00000002");   -- LPF_P_SHIFT 2 
    axi_write_demod(16#020#, x"0000000C");   -- LPF_I_SHIFT 6
    axi_write_demod(16#024#, x"00000080");   -- SYM_LOCK_COUNT = 128  (standalone count; reset default was 128)
    axi_write_demod(16#028#, x"00000008");   -- SYM_LOCK_THRESHOLD = 8  (CALIBRATE vs CST_IQ_DELTA on real amplitude)
    axi_write_demod(16#030#, x"00000400");   -- GAIN_MANUAL = 1024 = 1.000 (Q6.10)
    axi_write_demod(16#064#, x"00000000");   -- RX_SAMPLE_DISCARD = 0 (not 0x18)

    -- map v6 symbol lock detector (sym_lock_detector.vhd) -- explicit
    -- writes of the proven(-provisional) defaults, bring-up.sh parity:
    axi_write_demod(16#0A4#, x"00000019");   -- SYM_LOCK_THRESH   = 25 % (C++ LOCK_THRESH 0.25, verbatim)
    axi_write_demod(16#0A8#, x"00000032");   -- SYM_UNLOCK_THRESH = 50 % (C++ UNLOCK_THRESH 0.50, verbatim)
    axi_write_demod(16#0AC#, x"00000006");   -- SYM_LOCK_WINDOW   log2 -> 64 symbols
    -- CFO block (WP2 step 1): auto=1 -> applied word ZERO until the AFC
    -- lands (step 2), so this regression is unperturbed. RED-FIRST system
    -- procedure for the manual path (run by hand, documented here):
    --   1. regenerate stimulus with --carrier-offset 5000 (beyond theta's
    --      +/-212 Hz): run MUST fail to decode (RED) with defaults.
    --   2. axi_write_demod 0x0B8 <= 0x00060A00 (auto=0),
    --      axi_write_demod 0x0BC <= 0x00001388 (+5000): run MUST decode
    --      6/6 (GREEN) -- correction path proven end to end.
    --   3. readback 0x0B4 (CFO_ESTIMATE) = applied word both times.
    axi_write_demod(16#0B8#, x"00060A01");   -- CFO_CTRL: acq_shift 6, trk_shift 10, auto
    axi_write_demod(16#0BC#, x"00000000");   -- CFO_MANUAL: 0 Hz
    axi_write_demod(16#0C4#, x"00000148");   -- TIM_ALPHA = 328 Q16 (C++ 0.005)
    axi_write_demod(16#0C8#, x"000000A8");   -- TIM_BETA  = 168 Q24 (C++ 1e-5)

    -- Once we have real noise on hardware, run a short BER 
    -- comparison of the uniform set against the current 500/1400/2800 and keep whichever wins. 
    -- The histogram sets the scale; a BER run picks the shape. Conventional-and-scale is 
    -- the right place to start; let the bit errors have the final word.

    -- QUANT_THR ratio 1:2:3, forced by opv_demod.hpp:
    --   n = (-soft/scale)*3.5 + 3.5,  scale = mean|soft| over the frame
    -- so the boundaries sit at scale/3.5, 2*scale/3.5, 3*scale/3.5.
    -- Calibrated for mean|soft| = 3916 at demod amp ~545 (gain_manual unity,
    -- normalizer bypassed). These MOVE when NORM_AUTO goes to '1'.
    -- we recalculated from soft_cap collection, and re-ran at NORM_AUTO = 0. 

    -- shortcuts:
    -- mean|soft|  = debug_corr_peak / 24
    -- QUANT_THR_1 = debug_corr_peak / 84        (= mean/3.5)
    -- QUANT_THR_2 = 2 x QUANT_THR_1
    -- QUANT_THR_3 = 3 x QUANT_THR_1
    -- FS_HUNT     = 0.80 x debug_corr_peak
    -- FS_VERIFY   = 0.40 x debug_corr_peak

    -- these are from the NORM_AUTO = 0 simulation
    --axi_write_demod(16#050#, x"00000D7C");   -- QUANT_THR_1 =   3452
    --axi_write_demod(16#054#, x"00001AF8");   -- QUANT_THR_2 =   6904
    --axi_write_demod(16#058#, x"00002874");   -- QUANT_THR_3 =  10356
    --axi_write_demod(16#048#, x"00038A25");   -- FS_HUNT_THRESH   = 231973  (80%)
    --axi_write_demod(16#04C#, x"0001C512");   -- FS_VERIFY_THRESH = 115986  (40%)

    axi_write_demod(16#050#, x"0000134E");   -- QUANT_THR_1 =   4942
    axi_write_demod(16#054#, x"0000269C");   -- QUANT_THR_2 =   9884
    axi_write_demod(16#058#, x"000039EA");   -- QUANT_THR_3 =  14826

    --axi_write_demod(16#048#, x"0005FE43");   -- FS_HUNT_THRESH   = 392,771
    --axi_write_demod(16#04C#, x"0004EF83");   -- FS_VERIFY_THRESH = 323,459

    -- now we have normalized limits on the hunting and verifying thresholds
    axi_write_demod(16#048#, x"00000055");   -- FS_HUNT_PCT   = 85
    axi_write_demod(16#04C#, x"00000046");   -- FS_VERIFY_PCT = 70

    axi_write_demod(16#060#, x"00000004");   -- LOOP_CTRL : rx_enable=1, not frozen/zeroed
    axi_write_demod(16#05C#, x"00000000");   -- DEMOD_INIT = 0 : release onto the live channel output

    axi_read_demod(16#01C#, v_demod_ver);
    report "READBACK P_SHIFT = 0x" & to_hstring(v_demod_ver) severity note;
    axi_read_demod(16#020#, v_demod_ver);
    report "READBACK I_SHIFT = 0x" & to_hstring(v_demod_ver) severity note;

    ------------------------------------------------------------------
    -- SL-D: symbol lock detector register walk (map v6 0x0A0-0x0AC)
    ------------------------------------------------------------------
    axi_read_demod(16#0A4#, v_demod_ver);
    if v_demod_ver(7 downto 0) = x"19" then pass("SL-D SYM_LOCK_THRESH readback 25%");
    else fail("SL-D SYM_LOCK_THRESH readback: got 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0A8#, v_demod_ver);
    if v_demod_ver(7 downto 0) = x"32" then pass("SL-D SYM_UNLOCK_THRESH readback 50%");
    else fail("SL-D SYM_UNLOCK_THRESH readback: got 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0AC#, v_demod_ver);
    if v_demod_ver(3 downto 0) = x"6" then pass("SL-D SYM_LOCK_WINDOW readback 6 (64 sym)");
    else fail("SL-D SYM_LOCK_WINDOW readback: got 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0B8#, v_demod_ver);
    if v_demod_ver = x"00060A01" then pass("CFO-D CFO_CTRL readback 0x00060A01");
    else fail("CFO-D CFO_CTRL readback: got 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0B4#, v_demod_ver);
    if v_demod_ver = x"00000000" then pass("CFO-D applied word 0 (auto, no estimator)");
    else fail("CFO-D applied nonzero: 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0C4#, v_demod_ver);
    if v_demod_ver(15 downto 0) = x"0148" then pass("TL-D TIM_ALPHA readback 0x0148 (0.005)");
    else fail("TL-D TIM_ALPHA readback: got 0x" & to_hstring(v_demod_ver)); end if;
    axi_read_demod(16#0C8#, v_demod_ver);
    if v_demod_ver(15 downto 0) = x"00A8" then pass("TL-D TIM_BETA readback 0x00A8 (1e-5)");
    else fail("TL-D TIM_BETA readback: got 0x" & to_hstring(v_demod_ver)); end if;

    ------------------------------------------------------------------
    -- SL-B: NO symbol lock before signal (the anti-insta-lock check).
    -- The demod is released onto a dead channel here; STATUS bit1 must
    -- read 0 -- the old G_LOCK_SYM calendar would have latched it high
    -- ~22 ms after init unconditionally.
    ------------------------------------------------------------------
    wait for 100 us;
    axi_read_demod(16#040#, v_demod_ver);
    if v_demod_ver(1) = '0' then pass("SL-B no symbol lock on dead channel (STATUS.1 = 0)");
    else fail("SL-B STATUS.1 asserted with no signal -- lock detector lying"); end if;
	
    wait for 2 us;                           -- let the re-init settle before the burst arrives
    report "MILESTONE 2: demod bracket complete; endfile(fin)=" &
           boolean'image(endfile(fin)) severity note;
    else
    report "MILESTONE 2 SKIPPED: DO_DEMOD_BRACKET=false (channelizer-only path, like the old bench)"
           severity note;
    end if;

while not endfile(fin) loop
    readline(fin, l);
    read(l, iv);
    read(l, qv);
    s_axis_data_tdata(15 downto 0)  <= std_logic_vector(to_signed(iv, 16));
    s_axis_data_tdata(31 downto 16) <= std_logic_vector(to_signed(qv, 16));
    s_axis_data_tvalid <= '1';
    -- wait for tready, but with a bounded timeout so a stuck stream fails loud
    tready_to := 0;
    loop
        wait until rising_edge(aclk);
        exit when s_axis_data_tready = '1';
        tready_to := tready_to + 1;
        assert tready_to < 100000
            report "TIMEOUT: s_axis_data_tready never asserted (sample " &
                   integer'image(n_fed) & ")" severity failure;
    end loop;
    n_fed := n_fed + 1;
    if n_fed = 1 then
        report "MILESTONE 3: first sample accepted by the channelizer" severity note;
    end if;
    s_axis_data_tvalid <= '0';
    for k in 1 to SMP_PERIOD-1 loop
        wait until rising_edge(aclk);
    end loop;
end loop;
-- ZERO TAIL: the MLSE holds its last 64 decisions in the traceback and
-- emits them only as further symbols arrive. In the field the channel
-- never stops (silence is still noise samples); the bench must imitate
-- that or the burst's final ~65 soft bits are never emitted and the
-- last frame is lost to truncation. ~30000 ADC samples ~= 940 channel
-- samples ~= 81 symbols: traceback depth + margin.
for zi in 1 to 30000 loop
    s_axis_data_tdata <= (others => '0');
    s_axis_data_tvalid <= '1';
    loop
        wait until rising_edge(aclk);
        exit when s_axis_data_tready = '1';
    end loop;
    s_axis_data_tvalid <= '0';
    for k in 1 to SMP_PERIOD-1 loop
        wait until rising_edge(aclk);
    end loop;
end loop;
s_axis_data_tvalid <= '0';
report "MILESTONE 4: injection complete, fed " & integer'image(n_fed) &
       " samples (+30000 zero-tail)" severity note;



    report "OPV phase fed " & integer'image(n_fed) & " samples" severity note;
    ------------------------------------------------------------------
    -- SL-A: symbol lock from the REAL signal within the 40 ms preamble
    -- budget (Paul KB5MU 2026-07-07 spec: sub-40 ms desired). Polls
    -- STATUS.1; reports the live avg_err for SL-3 calibration.
    ------------------------------------------------------------------
    sl_wait := 0;
    loop
        axi_read_demod(16#040#, v_demod_ver);
        exit when v_demod_ver(1) = '1';
        sl_wait := sl_wait + 1;
        if sl_wait > 400 then
            fail("SL-A symbol lock not achieved within 40 ms of signal");
            exit;
        end if;
        wait for 100 us;
    end loop;
    if v_demod_ver(1) = '1' then
        pass("SL-A symbol lock on real signal at ~" &
             integer'image(sl_wait/10) & "." & integer'image(sl_wait mod 10) & " ms");
    end if;
    axi_read_demod(16#0A0#, v_demod_ver);
    axi_read_demod(16#0B0#, v_demod_ver);
    report "AFC: CFO_STATE = " & integer'image(to_integer(unsigned(v_demod_ver(2 downto 0)))) &
           " (0 IDLE/1 SEARCH/2 CORR/3 HELD/4 LOST)" severity note;
    axi_read_demod(16#0B4#, v_demod_ver);
    report "AFC: CFO_ESTIMATE (applied, Hz) = " &
           integer'image(to_integer(signed(v_demod_ver(15 downto 0)))) severity note;
    axi_read_demod(16#0C0#, v_demod_ver);
    report "AFC: CFO_QUALITY = " &
           integer'image(to_integer(unsigned(v_demod_ver(15 downto 0)))) severity note;
    axi_read_demod(16#0CC#, v_demod_ver);
    report "TL: SYM_CLK_OFFSET (Q24 smp/sym) = " &
           integer'image(to_integer(signed(v_demod_ver))) &
           " (zero-offset stimulus: expect near 0, was walking +/-2500-class pre-fix)"
           severity note;
    report "SL quality: locked ratio_pct = " &
           integer'image(to_integer(unsigned(v_demod_ver(15 downto 8)))) &
           " % (expect well under 25)" severity note;

    wait for 50 us;                          -- let the demod lock + frame_sync drain soft frames
    ------------------------------------------------------------------
    -- SL-C: configuration takes effect live -- write window_log2=4,
    -- detector flushes (map v6: write flushes); on the zero-tail dead
    -- air the mean rises and lock must NOT return: lock tracks the
    -- SIGNAL at the new setting, not elapsed time.
    ------------------------------------------------------------------
    axi_write_demod(16#0AC#, x"00000004");   -- window 16: flush + reconfig
    wait for 200 us;
    axi_read_demod(16#040#, v_demod_ver);
    if v_demod_ver(1) = '0' then
        pass("SL-C window reconfig flushed; no relock on dead air (cfg=16)");
    else
        fail("SL-C STATUS.1 high on dead air after reconfig");
    end if;
    axi_read_demod(16#0A0#, v_demod_ver);
    report "SL quality: dead-air ratio_pct = " &
           integer'image(to_integer(unsigned(v_demod_ver(15 downto 8)))) &
           " % (expect near 100)" severity note;

    report "DEMOD PATH: target samples=" & integer'image(n_target_samps)
         & "  soft beats=" & integer'image(n_soft_beats)
         & "  soft frames=" & integer'image(n_soft_frames) severity note;

        -- Test control
        end if;


        ---------------------------------------------------------------------
        -- Summary
        ---------------------------------------------------------------------
        report "================================================";
        report "Phase 1 AXI Wrapper Smoke Test COMPLETE";
        report "  PASS: " & integer'image(tests_pass);
        report "  FAIL: " & integer'image(tests_fail);
        report "================================================";
        report "soft_raw: captured " & integer'image(n_soft_raw) & " symbols" severity note;

        ------------------------------------------------------------------
    -- SL-C: configuration takes effect live -- write window_log2=4,
    -- detector flushes (map v6: write flushes); on the zero-tail dead
    -- air the mean rises and lock must NOT return: lock tracks the
    -- SIGNAL at the new setting, not elapsed time.
    ------------------------------------------------------------------
    axi_write_demod(16#0AC#, x"00000004");   -- window 16: flush + reconfig
    wait for 200 us;
    axi_read_demod(16#040#, v_demod_ver);
    if v_demod_ver(1) = '0' then
        pass("SL-C window reconfig flushed; no relock on dead air (cfg=16)");
    else
        fail("SL-C STATUS.1 high on dead air after reconfig");
    end if;
    axi_read_demod(16#0A0#, v_demod_ver);
    report "SL quality: dead-air ratio_pct = " &
           integer'image(to_integer(unsigned(v_demod_ver(15 downto 8)))) &
           " % (expect near 100)" severity note;

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
