-------------------------------------------------------------------------------
-- haifuraiya_channelizer_axi.vhd
-- AXI-Stream / AXI-Lite Wrapper for the Haifuraiya Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-- This wrapper takes the validated haifuraiya_channelizer_top entity
-- and presents it as a Vivado IP with three standard interfaces:
--
--   s_axis_data    : AXI-Stream slave  (input samples,  32-bit {Q,I})
--   m_axis_chans   : AXI-Stream master (per-channel,    32-bit {Q,I} + TDEST)
--   s_axi_ctrl     : AXI-Lite slave    (control/telemetry registers)
--
-- The wrapper adds three things over the bare channelizer:
--
--   1. AXIS pin renaming (channelizer's channel_re/im/idx/valid/last
--      already serializes one-channel-per-clock; we just adapt names
--      and quantize 40-bit -> 16-bit each via runtime-tunable shift).
--   2. 64 power_detector instances, one per channel, exposed via the
--      CHANNEL_POWER[0..63] register window. The power detectors run on
--      the requantized 16-bit channel data, so DATA_W=16 keeps each
--      multiplier in one DSP48E2.
--   3. AXI-Lite register block with control (soft reset, enable, EMA
--      alphas, requantize shift) and telemetry (frame count, dropped
--      frames, sticky status flags, per-channel power readbacks).
--
-- Phase 1 wrapper - no output FIFO, no input rate-matching. Downstream
-- is expected to consume m_axis_chans at line rate; if it stalls,
-- backpressure_sticky asserts in STATUS and the affected frame is lost.
-------------------------------------------------------------------------------
-- TIMING / THROUGHPUT
-------------------------------------------------------------------------------
-- At 100 MHz aclk with 10 MSps complex input and M_DECIMATION=16:
--
--   Input AXIS  : up to 1 beat per 10 clocks (~10% of capacity)
--   Output AXIS : 64 beats every 160 clocks  (~40% of capacity)
--
-- Comfortable margins on both sides for downstream DMA pacing.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_channelizer_axi is
    generic (
        -- Channelizer dimensions (passed through to haifuraiya_channelizer_top)
        N_CHANNELS       : positive := 64;
        M_DECIMATION     : positive := 16;
        TAPS_PER_BRANCH  : positive := 24;
        DATA_WIDTH       : positive := 16;
        COEFF_WIDTH      : positive := 16;
        ACCUM_WIDTH      : positive := 40;

        -- Power detector parameters
        POWER_ALPHA_W    : positive := 18;

        -- AXI parameters
        C_S_AXI_CTRL_ADDR_WIDTH : positive := 12   -- 4 KB register window
    );
    port (
        ---------------------------------------------------------------------
        -- Clock and reset (AXI convention: active-low aresetn)
        ---------------------------------------------------------------------
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        ---------------------------------------------------------------------
        -- AXI-Stream slave: input samples
        --   TDATA[31:16] = Q,  TDATA[15:0] = I  (DATA_WIDTH=16 packed)
        ---------------------------------------------------------------------
        s_axis_data_tdata   : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid  : in  std_logic;
        s_axis_data_tready  : out std_logic;

        ---------------------------------------------------------------------
        -- AXI-Stream master: per-channel output samples
        --   TDATA[31:16] = Q_chan, TDATA[15:0] = I_chan
        --   TDEST[7:0] = channel index 0..63 (top 2 bits unused)
        --   TLAST asserted on the last channel of each output frame
        ---------------------------------------------------------------------
        m_axis_chans_tdata  : out std_logic_vector(31 downto 0);
        m_axis_chans_tvalid : out std_logic;
        m_axis_chans_tready : in  std_logic;
        m_axis_chans_tdest  : out std_logic_vector(7 downto 0);
        m_axis_chans_tlast  : out std_logic;

        ---------------------------------------------------------------------
        -- AXI-Lite slave: control and telemetry
        ---------------------------------------------------------------------
        s_axi_ctrl_awaddr   : in  std_logic_vector(C_S_AXI_CTRL_ADDR_WIDTH - 1 downto 0);
        s_axi_ctrl_awvalid  : in  std_logic;
        s_axi_ctrl_awready  : out std_logic;
        s_axi_ctrl_wdata    : in  std_logic_vector(31 downto 0);
        s_axi_ctrl_wstrb    : in  std_logic_vector(3 downto 0);
        s_axi_ctrl_wvalid   : in  std_logic;
        s_axi_ctrl_wready   : out std_logic;
        s_axi_ctrl_bresp    : out std_logic_vector(1 downto 0);
        s_axi_ctrl_bvalid   : out std_logic;
        s_axi_ctrl_bready   : in  std_logic;
        s_axi_ctrl_araddr   : in  std_logic_vector(C_S_AXI_CTRL_ADDR_WIDTH - 1 downto 0);
        s_axi_ctrl_arvalid  : in  std_logic;
        s_axi_ctrl_arready  : out std_logic;
        s_axi_ctrl_rdata    : out std_logic_vector(31 downto 0);
        s_axi_ctrl_rresp    : out std_logic_vector(1 downto 0);
        s_axi_ctrl_rvalid   : out std_logic;
        s_axi_ctrl_rready   : in  std_logic;


	---------------------------------------------------------------------
        -- Debug ports for ILA probing (Phase B hardware debug)
        -- Exposes internal signals so a BD-level ILA can watch the
        -- channelizer -> power_detector signal path to diagnose the
        -- hardware-only bimodal failure (sim shows clean skirt; HW reads
        -- 0 or 0x7FFFFFFF per channel).
        ---------------------------------------------------------------------
        dbg_chan_re_q      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        dbg_chan_im_q      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        dbg_chan_valid_r   : out std_logic;
        dbg_chan_idx_int_r : out std_logic_vector(5 downto 0);
        dbg_chan_valid     : out std_logic;
        dbg_chan_idx_int   : out std_logic_vector(5 downto 0);
        dbg_pd_data_ena    : out std_logic_vector(N_CHANNELS - 1 downto 0);
        dbg_core_reset     : out std_logic;
        dbg_core_dropped   : out std_logic;
        dbg_chan_last      : out std_logic


    );
end entity haifuraiya_channelizer_axi;

architecture rtl of haifuraiya_channelizer_axi is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    -- Power detector output is 2*DATA_W-1 bits for DATA_W=16: 31 bits.
    -- (power_detector declares port as std_logic_vector(2*DATA_W-2 DOWNTO 0),
    -- so the WIDTH is one more than the MSB index. Easy to misread.)
    constant POWER_WIDTH : positive := 2 * DATA_WIDTH - 1;

    ---------------------------------------------------------------------------
    -- Control plane signals (driven by axi_lite_regs)
    ---------------------------------------------------------------------------
    signal ctrl_soft_reset    : std_logic;
    signal ctrl_enable        : std_logic;
    signal ctrl_output_shift  : unsigned(4 downto 0);
    signal ctrl_alpha1        : std_logic_vector(POWER_ALPHA_W - 1 downto 0);
    signal ctrl_alpha2        : std_logic_vector(POWER_ALPHA_W - 1 downto 0);

    -- Telemetry signals (driven into axi_lite_regs)
    signal stat_ready             : std_logic;
    signal stat_overflow_pulse    : std_logic := '0';
    signal stat_backpressure_pulse: std_logic := '0';
    signal stat_frame_count       : std_logic_vector(31 downto 0) := (others => '0');
    signal stat_dropped_frames    : std_logic_vector(31 downto 0) := (others => '0');
    signal stat_channel_power     : std_logic_vector(N_CHANNELS * POWER_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Internal channelizer signals
    ---------------------------------------------------------------------------
    -- Reset to channelizer: combine async aresetn with ctrl_soft_reset
    signal core_reset : std_logic;

    -- Input adapters
    signal sample_re_int    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal sample_im_int    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal sample_valid_int : std_logic;

    -- Channelizer outputs (from haifuraiya_channelizer_top)
    signal chan_re_acc    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal chan_im_acc    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal chan_idx_int   : std_logic_vector(5 downto 0);
    signal chan_valid_r   : std_logic;
    signal chan_idx_int_r : std_logic_vector(chan_idx_int'range);  -- match chan_idx_int's type
    signal chan_valid     : std_logic;
    signal chan_last      : std_logic;
    signal core_ready     : std_logic;
    signal core_dropped   : std_logic;

    -- Requantized channelizer outputs (40 -> 16 bit via output_shift)
    signal chan_re_q  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal chan_im_q  : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- Per-channel data_ena pulses for the 64 power_detector instances
    signal pd_data_ena : std_logic_vector(N_CHANNELS - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Reset combination
    -- AXI's aresetn (active low) AND soft reset bit from CONTROL register.
    ---------------------------------------------------------------------------
    core_reset <= (not aresetn) or ctrl_soft_reset;

    ---------------------------------------------------------------------------
    -- Input AXIS adapter
    -- The channelizer expects sample_re/sample_im at DATA_WIDTH bits.
    -- AXIS packs I in the low half, Q in the high half (ADI convention).
    -- TREADY is held high because the channelizer is always ready to
    -- absorb a sample (the FIR pipeline runs every cycle whether or
    -- not sample_valid is asserted).
    ---------------------------------------------------------------------------
    sample_re_int    <= s_axis_data_tdata(DATA_WIDTH - 1 downto 0);
    sample_im_int    <= s_axis_data_tdata(31 downto 32 - DATA_WIDTH);
    sample_valid_int <= s_axis_data_tvalid and ctrl_enable;

    s_axis_data_tready <= '1';

    ---------------------------------------------------------------------------
    -- Channelizer instance
    ---------------------------------------------------------------------------
    u_chan : entity work.haifuraiya_channelizer_top
        generic map (
            N_CHANNELS      => N_CHANNELS,
            M_DECIMATION    => M_DECIMATION,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk           => aclk,
            reset         => core_reset,

            sample_re     => sample_re_int,
            sample_im     => sample_im_int,
            sample_valid  => sample_valid_int,

            channel_re    => chan_re_acc,
            channel_im    => chan_im_acc,
            channel_idx   => chan_idx_int,
            channel_valid => chan_valid,
            channel_last  => chan_last,

            ready         => core_ready,
            frame_dropped => core_dropped
        );

    ---------------------------------------------------------------------------
    -- Output requantization (ACCUM_WIDTH -> DATA_WIDTH, signed)
    -- Performs a runtime-configurable arithmetic right shift on each of
    -- the I and Q components of the channelizer output, then truncates
    -- to DATA_WIDTH bits with saturation at the extremes.
    --
    -- ctrl_output_shift = 16 by default (extract bits [31:16]).
    -- Valid range 0 .. ACCUM_WIDTH - DATA_WIDTH = 0..24.
    ---------------------------------------------------------------------------
    p_quantize : process(aclk)
        variable shifted_re : signed(ACCUM_WIDTH - 1 downto 0);
        variable shifted_im : signed(ACCUM_WIDTH - 1 downto 0);
        variable shift_amt  : integer range 0 to ACCUM_WIDTH - DATA_WIDTH;
        -- Saturation limits computed numerically (avoids non-static aggregate)
        constant MAX_POS    : signed(DATA_WIDTH - 1 downto 0) :=
                                 to_signed(2**(DATA_WIDTH - 1) - 1, DATA_WIDTH);
        constant MAX_NEG    : signed(DATA_WIDTH - 1 downto 0) :=
                                 to_signed(-(2**(DATA_WIDTH - 1)), DATA_WIDTH);
    begin
        if rising_edge(aclk) then
            if core_reset = '1' then
                chan_re_q <= (others => '0');
                chan_im_q <= (others => '0');
            --else
            elsif chan_valid = '1' then
                -- Clamp the shift amount to the valid range
                if to_integer(ctrl_output_shift) > ACCUM_WIDTH - DATA_WIDTH then
                    shift_amt := ACCUM_WIDTH - DATA_WIDTH;
                else
                    shift_amt := to_integer(ctrl_output_shift);
                end if;

                shifted_re := shift_right(signed(chan_re_acc), shift_amt);
                shifted_im := shift_right(signed(chan_im_acc), shift_amt);

                -- Saturate. If the shifted result is outside [MAX_NEG, MAX_POS],
                -- clip to that range; otherwise just truncate the low DATA_WIDTH
                -- bits.
                if shifted_re > resize(MAX_POS, ACCUM_WIDTH) then
                    chan_re_q <= std_logic_vector(MAX_POS);
                elsif shifted_re < resize(MAX_NEG, ACCUM_WIDTH) then
                    chan_re_q <= std_logic_vector(MAX_NEG);
                else
                    chan_re_q <= std_logic_vector(shifted_re(DATA_WIDTH - 1 downto 0));
                end if;

                if shifted_im > resize(MAX_POS, ACCUM_WIDTH) then
                    chan_im_q <= std_logic_vector(MAX_POS);
                elsif shifted_im < resize(MAX_NEG, ACCUM_WIDTH) then
                    chan_im_q <= std_logic_vector(MAX_NEG);
                else
                    chan_im_q <= std_logic_vector(shifted_im(DATA_WIDTH - 1 downto 0));
                end if;
            end if;
        end if;
    end process p_quantize;

-------------------------------------------------------------------
-- put this near p_quantize
-- it is the dispatch's mirror of what p_quantize does for the data
-------------------------------------------------------------------

p_dispatch_align : process(aclk)
begin
    if rising_edge(aclk) then
        if core_reset = '1' then
            chan_valid_r   <= '0';
            chan_idx_int_r <= (others => '0');
        else
            chan_valid_r   <= chan_valid;
            chan_idx_int_r <= chan_idx_int;
        end if;
    end if;
end process p_dispatch_align;

    ---------------------------------------------------------------------------
    -- Output AXIS adapter
    -- The channelizer's channel_valid/idx/last already produces a clean
    -- one-channel-per-clock stream. We just rename to AXIS conventions.
    -- The requantized 16-bit chan_re_q/chan_im_q are one cycle behind
    -- chan_valid, so we also delay valid/idx/last by one cycle to keep
    -- them aligned.
    ---------------------------------------------------------------------------
    p_axis_out : process(aclk)
    begin
        if rising_edge(aclk) then
            if core_reset = '1' then
                m_axis_chans_tvalid <= '0';
                m_axis_chans_tdata  <= (others => '0');
                m_axis_chans_tdest  <= (others => '0');
                m_axis_chans_tlast  <= '0';
            else
                -- chan_re_q / chan_im_q updated this cycle from data that
                -- arrived as chan_valid='1' one cycle ago.
                m_axis_chans_tvalid <= chan_valid;
                m_axis_chans_tdata  <= chan_im_q & chan_re_q;
                m_axis_chans_tdest  <= "00" & chan_idx_int;
                m_axis_chans_tlast  <= chan_last;
            end if;
        end if;
    end process p_axis_out;

    ---------------------------------------------------------------------------
    -- Per-channel data_ena pulses
    -- Each power detector fires when chan_valid='1' AND chan_idx matches
    -- its own channel index. Generate-for-loop creates one decoder per
    -- instance; synthesis collapses to a single 6-bit-index decoder
    -- fanning out to 64 enables.
    -- Point the dispatch to the registered copies to resolve off-by-one.
    ---------------------------------------------------------------------------
    gen_pd_ena : for k in 0 to N_CHANNELS - 1 generate
        pd_data_ena(k) <= chan_valid_r when
            unsigned(chan_idx_int_r) = to_unsigned(k, chan_idx_int'length)
            else '0';
    end generate;

    ---------------------------------------------------------------------------
    -- 64 power detector instances
    -- One per channel, all running on the same requantized channel data
    -- stream. Each fires only on its own data_ena, so the EMA state
    -- updates correctly per-channel even though the data bus is shared.
    ---------------------------------------------------------------------------
    gen_pd : for k in 0 to N_CHANNELS - 1 generate
        u_pd : entity work.power_detector
            generic map (
                DATA_W      => DATA_WIDTH,
                ALPHA_W     => POWER_ALPHA_W,
                IQ_MOD      => True,
                I_USED      => True,
                Q_USED      => True,
                EMA_CASCADE => True
            )
            port map (
                clk           => aclk,
                init          => core_reset,
                alpha1        => ctrl_alpha1,
                alpha2        => ctrl_alpha2,
                data_I        => chan_re_q,
                data_Q        => chan_im_q,
                data_ena      => pd_data_ena(k),
                power_squared => stat_channel_power(
                                     (k + 1) * POWER_WIDTH - 1 downto
                                     k * POWER_WIDTH)
            );
    end generate;

    ---------------------------------------------------------------------------
    -- Telemetry counters
    -- FRAME_COUNT increments on each chan_last pulse (one per output
    -- frame). DROPPED_FRAMES increments on core_dropped pulses (asserted
    -- by the channelizer when its dual-FFT arbitration loses a frame).
    -- Backpressure sticky asserts when we have valid output data but
    -- downstream isn't ready.
    ---------------------------------------------------------------------------
    p_counters : process(aclk)
    begin
        if rising_edge(aclk) then
            if core_reset = '1' then
                stat_frame_count    <= (others => '0');
                stat_dropped_frames <= (others => '0');
            else
                if chan_last = '1' and chan_valid = '1' then
                    stat_frame_count <=
                        std_logic_vector(unsigned(stat_frame_count) + 1);
                end if;
                if core_dropped = '1' then
                    stat_dropped_frames <=
                        std_logic_vector(unsigned(stat_dropped_frames) + 1);
                end if;
            end if;
        end if;
    end process p_counters;

    stat_ready              <= core_ready;
    stat_overflow_pulse     <= core_dropped;
    -- Backpressure: we drive m_axis_chans_tvalid='1' but downstream
    -- is not asserting tready. Phase 1 doesn't honor TREADY (we just
    -- record that it happened), so we still emit the data; the flag
    -- tells software downstream is too slow.
    stat_backpressure_pulse <=
        '1' when m_axis_chans_tready = '0' and chan_valid = '1' else '0';

    ---------------------------------------------------------------------------
    -- AXI-Lite register block
    ---------------------------------------------------------------------------
    u_regs : entity work.axi_lite_regs
        generic map (
            N_CHANNELS    => N_CHANNELS,
            POWER_WIDTH   => POWER_WIDTH,
            ALPHA_W       => POWER_ALPHA_W,
            ACCUM_WIDTH   => ACCUM_WIDTH,
            DATA_WIDTH    => DATA_WIDTH,
            ADDR_WIDTH    => C_S_AXI_CTRL_ADDR_WIDTH,
            VERSION_MAJOR => 0,
            VERSION_MINOR => 1,
            VERSION_PATCH => 0
        )
        port map (
            aclk           => aclk,
            aresetn        => aresetn,

            s_axi_awaddr   => s_axi_ctrl_awaddr,
            s_axi_awvalid  => s_axi_ctrl_awvalid,
            s_axi_awready  => s_axi_ctrl_awready,
            s_axi_wdata    => s_axi_ctrl_wdata,
            s_axi_wstrb    => s_axi_ctrl_wstrb,
            s_axi_wvalid   => s_axi_ctrl_wvalid,
            s_axi_wready   => s_axi_ctrl_wready,
            s_axi_bresp    => s_axi_ctrl_bresp,
            s_axi_bvalid   => s_axi_ctrl_bvalid,
            s_axi_bready   => s_axi_ctrl_bready,
            s_axi_araddr   => s_axi_ctrl_araddr,
            s_axi_arvalid  => s_axi_ctrl_arvalid,
            s_axi_arready  => s_axi_ctrl_arready,
            s_axi_rdata    => s_axi_ctrl_rdata,
            s_axi_rresp    => s_axi_ctrl_rresp,
            s_axi_rvalid   => s_axi_ctrl_rvalid,
            s_axi_rready   => s_axi_ctrl_rready,

            soft_reset     => ctrl_soft_reset,
            enable         => ctrl_enable,
            output_shift   => ctrl_output_shift,
            power_alpha1   => ctrl_alpha1,
            power_alpha2   => ctrl_alpha2,

            ready_in            => stat_ready,
            overflow_pulse      => stat_overflow_pulse,
            backpressure_pulse  => stat_backpressure_pulse,
            frame_count_in      => stat_frame_count,
            dropped_frames_in   => stat_dropped_frames,
            channel_power_flat  => stat_channel_power
        );



    ---------------------------------------------------------------------------
    -- Debug port drivers — straight passthrough of internal signals
    ---------------------------------------------------------------------------
    dbg_chan_re_q      <= chan_re_q;
    dbg_chan_im_q      <= chan_im_q;
    dbg_chan_valid_r   <= chan_valid_r;
    dbg_chan_idx_int_r <= chan_idx_int_r;
    dbg_chan_valid     <= chan_valid;
    dbg_chan_idx_int   <= chan_idx_int;
    dbg_pd_data_ena    <= pd_data_ena;
    dbg_core_reset     <= core_reset;
    dbg_core_dropped   <= core_dropped;
    dbg_chan_last      <= chan_last;


end architecture rtl;
