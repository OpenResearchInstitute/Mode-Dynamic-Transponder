-------------------------------------------------------------------------------
-- haifuraiya_channelizer_top.vhd
-- Top-Level Polyphase Channelizer for Haifuraiya (Opulent Voice uplinks)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
--
-------------------------------------------------------------------------------
-- OVERVIEW (parallel-MAC version)
-------------------------------------------------------------------------------
-- Receiver-side polyphase channelizer for the Haifuraiya FDMA uplink
-- system. Channelizes complex baseband I/Q into N=64 channels of
-- 156.25 kHz spacing, suitable for per-channel Opulent Voice demod.
--
-- This version uses parallel-MAC filterbanks: each branch instantiates
-- TAPS_PER_BRANCH multipliers (24 DSP48E2 per branch on ZU9EG) and
-- holds its coefficient slice as elaboration-time constants read from
-- COEFF_FILE. Compared to the iCE40-style serial MAC, this drops:
--   * the coeff_rom instances
--   * the LOAD_COEFFS state machine inside the filterbank
--   * the multi-cycle ready latency at startup
--
-- Architecture:
--
--   1. Two polyphase_filterbank_parallel instances (I and Q paths).
--      Each branch in each filterbank reads its own coefficient slice
--      at elaboration. No shared state between I and Q.
--
--   2. Parallel-to-sequential adapter. Filterbanks emit all 64 branch
--      outputs simultaneously on a packed bus; fft_64pt expects them
--      sequentially. The adapter latches on outputs_valid and walks
--      indices 0..63 over the next 64 clocks.
--
--   3. fft_64pt. Iterative radix-2 DIF FFT, ~320 cycles per frame.
--      (See note in fft_64pt regarding the OUTPUTTING-stage buffer
--      selection -- still pending review before tone-test runs.)
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--   +--------------------------------------------------------------------------------+
--   |                       haifuraiya_channelizer_top                               |
--   |                                                                                |
--   |              +------------------------+                                        |
--   |              | polyphase_filterbank_  |                                        |
--   |  sample_re ->| parallel (I)           |-- parallel bus (I) --+                 |
--   |              | 64 branches x 24 taps  |                      |                 |
--   |              | coeffs from .hex       |                      v                 |
--   |              +------------------------+             +--------------+           |
--   |                                                     | parallel-to- |           |
--   |                                                     |  sequential  |---------- |---> fft_64pt
--   |                                                     |   adapter    |           |    -> channel out
--   |                                                     +--------------+           |
--   |              +------------------------+                      ^                 |
--   |              | polyphase_filterbank_  |                      |                 |
--   |  sample_im ->| parallel (Q)           |-- parallel bus (Q) --+                 |
--   |              | 64 branches x 24 taps  |                                        |
--   |              | coeffs from .hex       |                                        |
--   |              +------------------------+                                        |
--   |                                                                                |
--   +--------------------------------------------------------------------------------+
--
-------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_channelizer_top is
    generic (
        -- Channelizer dimensions (Haifuraiya defaults)
        N_CHANNELS       : positive := 64;
        -- Decimation factor (samples per output frame).
        --   M = N_CHANNELS: critically sampled (default, backward compatible).
        --   M < N_CHANNELS: oversampled / guard-band channelizer.
        --                   For Haifuraiya production: M_DECIMATION = 16
        --                   (4x oversampled, M divides N).
        M_DECIMATION     : positive := 64;
        TAPS_PER_BRANCH  : positive := 24;

        -- Data path widths
        DATA_WIDTH       : positive := 16;
        COEFF_WIDTH      : positive := 16;
        ACCUM_WIDTH      : positive := 40;

        -- Coefficient file (passed down to each branch)
        COEFF_FILE       : string   := "haifuraiya_coeffs.hex"
    );
    port (
        clk              : in  std_logic;
        reset            : in  std_logic;

        sample_re        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_im        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid     : in  std_logic;

        channel_re       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        channel_im       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        channel_idx      : out std_logic_vector(5 downto 0);
        channel_valid    : out std_logic;
        channel_last     : out std_logic;

        ready            : out std_logic;
        frame_dropped    : out std_logic
    );

    function clog2(n : positive) return positive is
        variable result : positive := 1;
        variable value  : positive := 2;
    begin
        while value < n loop
            result := result + 1;
            value  := value * 2;
        end loop;
        return result;
    end function;

end entity haifuraiya_channelizer_top;

architecture rtl of haifuraiya_channelizer_top is

    constant CHANNEL_IDX_WIDTH : positive := clog2(N_CHANNELS);

    ---------------------------------------------------------------------------
    -- Filterbank outputs (packed buses + valid pulses)
    ---------------------------------------------------------------------------
    signal fb_i_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_i_outputs_valid : std_logic;
    signal fb_q_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_q_outputs_valid : std_logic;

    ---------------------------------------------------------------------------
    -- Parallel-to-sequential adapter state
    ---------------------------------------------------------------------------
    type bin_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal latched_re : bin_array_t;
    signal latched_im : bin_array_t;

    type p2s_state_t is (P2S_WAITING, P2S_STREAMING);
    signal p2s_state : p2s_state_t := P2S_WAITING;
    signal p2s_idx   : unsigned(CHANNEL_IDX_WIDTH - 1 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Dual-FFT arbitration
    --
    -- For M_DECIMATION < N_CHANNELS the polyphase produces frames faster
    -- than a single sequential FFT can process them (the FFT takes
    -- ~320 cycles for N=64). We instantiate two FFTs in parallel and the
    -- P2S routes each captured frame to whichever FFT is currently idle,
    -- with a round-robin preference encoded in next_fft. current_fft
    -- remembers which FFT we're streaming to during P2S_STREAMING.
    --
    -- For M_DECIMATION = N_CHANNELS (default / regression), only FFT_0 is
    -- ever needed; FFT_1 sits idle. No behavioral change vs. single-FFT
    -- design.
    ---------------------------------------------------------------------------
    signal next_fft     : std_logic := '0';  -- preferred FFT for next capture
    signal current_fft  : std_logic := '0';  -- which FFT the active stream targets

    -- FFT 0 input/output signal set
    signal fft0_x_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft0_x_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft0_x_idx   : std_logic_vector(5 downto 0) := (others => '0');
    signal fft0_x_valid : std_logic := '0';
    signal fft0_x_last  : std_logic := '0';
    signal fft0_busy      : std_logic;
    signal fft0_out_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft0_out_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft0_out_idx   : std_logic_vector(5 downto 0);
    signal fft0_out_valid : std_logic;
    signal fft0_out_last  : std_logic;

    -- FFT 1 input/output signal set
    signal fft1_x_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft1_x_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft1_x_idx   : std_logic_vector(5 downto 0) := (others => '0');
    signal fft1_x_valid : std_logic := '0';
    signal fft1_x_last  : std_logic := '0';
    signal fft1_busy      : std_logic;
    signal fft1_out_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft1_out_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft1_out_idx   : std_logic_vector(5 downto 0);
    signal fft1_out_valid : std_logic;
    signal fft1_out_last  : std_logic;

    ---------------------------------------------------------------------------
    -- Status
    ---------------------------------------------------------------------------
    signal ready_r          : std_logic := '0';
    signal frame_dropped_r  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank: I path
    ---------------------------------------------------------------------------
    u_filterbank_i : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS      => N_CHANNELS,
            M_DECIMATION    => M_DECIMATION,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH,
            COEFF_FILE      => COEFF_FILE
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => sample_re,
            sample_valid   => sample_valid,
            branch_outputs => fb_i_outputs,
            outputs_valid  => fb_i_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank: Q path
    ---------------------------------------------------------------------------
    u_filterbank_q : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS      => N_CHANNELS,
            M_DECIMATION    => M_DECIMATION,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH,
            COEFF_FILE      => COEFF_FILE
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => sample_im,
            sample_valid   => sample_valid,
            branch_outputs => fb_q_outputs,
            outputs_valid  => fb_q_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Ready: trivial now - just deasserted during reset, asserted otherwise.
    -- Kept as a port for compatibility with downstream consumers.
    ---------------------------------------------------------------------------
    p_ready : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ready_r <= '0';
            else
                ready_r <= '1';
            end if;
        end if;
    end process p_ready;

    ---------------------------------------------------------------------------
    -- Dual-FFT P2S Adapter
    --
    -- Round-robin: each captured frame goes to whichever FFT is preferred
    -- by next_fft. If the preferred FFT is busy, we try the other one. If
    -- both are busy, we drop. With the FFT's anticipated-IDLE busy signal
    -- and frames arriving every M_DECIMATION * (clk/sample) cycles, the
    -- arbitration sustains drop-free operation for M_DECIMATION as low as
    -- N_CHANNELS/2 (e.g. M=32 for N=64). For more aggressive oversampling
    -- (M=16 with N=64) the two FFTs together still keep up because they
    -- alternate frames exactly.
    --
    -- During STREAMING, current_fft selects which FFT's input port we
    -- drive. The other FFT's input port holds its default deassertion.
    ---------------------------------------------------------------------------
    p_p2s : process(clk)
    begin
        if rising_edge(clk) then
            -- Default deassertions every cycle
            fft0_x_valid    <= '0';
            fft0_x_last     <= '0';
            fft1_x_valid    <= '0';
            fft1_x_last     <= '0';
            frame_dropped_r <= '0';

            if reset = '1' then
                p2s_state   <= P2S_WAITING;
                p2s_idx     <= (others => '0');
                next_fft    <= '0';
                current_fft <= '0';
            else
                case p2s_state is

                    when P2S_WAITING =>
                        if fb_i_outputs_valid = '1' then
                            -- Pick an idle FFT, preferring next_fft.
                            if next_fft = '0' and fft0_busy = '0' then
                                -- Latch and route to FFT_0
                                for i in 0 to N_CHANNELS - 1 loop
                                    latched_re(i) <= fb_i_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                    latched_im(i) <= fb_q_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                end loop;
                                p2s_state   <= P2S_STREAMING;
                                p2s_idx     <= (others => '0');
                                current_fft <= '0';
                                next_fft    <= '1';
                            elsif next_fft = '1' and fft1_busy = '0' then
                                for i in 0 to N_CHANNELS - 1 loop
                                    latched_re(i) <= fb_i_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                    latched_im(i) <= fb_q_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                end loop;
                                p2s_state   <= P2S_STREAMING;
                                p2s_idx     <= (others => '0');
                                current_fft <= '1';
                                next_fft    <= '0';
                            elsif fft0_busy = '0' then
                                -- Preferred FFT busy but the other is free
                                for i in 0 to N_CHANNELS - 1 loop
                                    latched_re(i) <= fb_i_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                    latched_im(i) <= fb_q_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                end loop;
                                p2s_state   <= P2S_STREAMING;
                                p2s_idx     <= (others => '0');
                                current_fft <= '0';
                                next_fft    <= '1';
                            elsif fft1_busy = '0' then
                                for i in 0 to N_CHANNELS - 1 loop
                                    latched_re(i) <= fb_i_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                    latched_im(i) <= fb_q_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                end loop;
                                p2s_state   <= P2S_STREAMING;
                                p2s_idx     <= (others => '0');
                                current_fft <= '1';
                                next_fft    <= '0';
                            else
                                -- Both FFTs busy: drop this frame
                                frame_dropped_r <= '1';
                            end if;
                        end if;

                    when P2S_STREAMING =>
                        -- Drive the currently-selected FFT only; the other
                        -- holds its default deassertions from the top.
                        if current_fft = '0' then
                            fft0_x_valid <= '1';
                            fft0_x_re    <= latched_re(to_integer(p2s_idx));
                            fft0_x_im    <= latched_im(to_integer(p2s_idx));
                            fft0_x_idx   <= std_logic_vector(resize(p2s_idx, 6));
                            if p2s_idx = N_CHANNELS - 1 then
                                fft0_x_last <= '1';
                                p2s_state   <= P2S_WAITING;
                                p2s_idx     <= (others => '0');
                            else
                                p2s_idx <= p2s_idx + 1;
                            end if;
                        else
                            fft1_x_valid <= '1';
                            fft1_x_re    <= latched_re(to_integer(p2s_idx));
                            fft1_x_im    <= latched_im(to_integer(p2s_idx));
                            fft1_x_idx   <= std_logic_vector(resize(p2s_idx, 6));
                            if p2s_idx = N_CHANNELS - 1 then
                                fft1_x_last <= '1';
                                p2s_state   <= P2S_WAITING;
                                p2s_idx     <= (others => '0');
                            else
                                p2s_idx <= p2s_idx + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process p_p2s;

    ---------------------------------------------------------------------------
    -- Dual N-Point FFTs
    --
    -- Two identical FFT instances. Each one runs the same fft_n_pt logic
    -- (320 cycles busy per frame for N=64). The P2S round-robins frames
    -- between them, so combined throughput is one frame per 160 cycles.
    -- That meets M_DECIMATION=16 budget at 100 MHz / 10 Msps.
    --
    -- The two FFTs' OUTPUTTING phases are offset by the inter-frame period
    -- and each lasts 64 cycles, so they never produce out_valid='1'
    -- simultaneously: the output mux below picks whichever is currently
    -- emitting.
    ---------------------------------------------------------------------------
    u_fft_0 : entity work.fft_n_pt
        generic map (
            N          => N_CHANNELS,
            DATA_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_re      => fft0_x_re,
            x_im      => fft0_x_im,
            x_idx     => fft0_x_idx,
            x_valid   => fft0_x_valid,
            x_last    => fft0_x_last,
            out_re    => fft0_out_re,
            out_im    => fft0_out_im,
            out_idx   => fft0_out_idx,
            out_valid => fft0_out_valid,
            out_last  => fft0_out_last,
            busy      => fft0_busy
        );

    u_fft_1 : entity work.fft_n_pt
        generic map (
            N          => N_CHANNELS,
            DATA_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_re      => fft1_x_re,
            x_im      => fft1_x_im,
            x_idx     => fft1_x_idx,
            x_valid   => fft1_x_valid,
            x_last    => fft1_x_last,
            out_re    => fft1_out_re,
            out_im    => fft1_out_im,
            out_idx   => fft1_out_idx,
            out_valid => fft1_out_valid,
            out_last  => fft1_out_last,
            busy      => fft1_busy
        );

    ---------------------------------------------------------------------------
    -- Output mux
    --
    -- Combinational pick of whichever FFT is currently emitting. Their
    -- OUTPUTTING phases never overlap (offset by inter-frame period > 64
    -- cycles), so at most one out_valid is '1' at any time.
    ---------------------------------------------------------------------------
 
   --channel_re    <= fft0_out_re    when fft0_out_valid = '1' else fft1_out_re;

channel_re   <= fft0_out_re   when fft0_out_valid = '1'
           else fft1_out_re   when fft1_out_valid = '1'
           else (others => '0');
channel_im   <= fft0_out_im   when fft0_out_valid = '1'
           else fft1_out_im   when fft1_out_valid = '1'
           else (others => '0');
channel_idx  <= fft0_out_idx  when fft0_out_valid = '1'
           else fft1_out_idx  when fft1_out_valid = '1'
           else (others => '0');
channel_last <= fft0_out_last when fft0_out_valid = '1'
           else fft1_out_last when fft1_out_valid = '1'
           else '0';

    --channel_im    <= fft0_out_im    when fft0_out_valid = '1' else fft1_out_im;
    --channel_idx   <= fft0_out_idx   when fft0_out_valid = '1' else fft1_out_idx;

    channel_valid <= fft0_out_valid or fft1_out_valid;

    --channel_last  <= fft0_out_last  when fft0_out_valid = '1' else fft1_out_last;

    ready         <= ready_r;
    frame_dropped <= frame_dropped_r;

end architecture rtl;
