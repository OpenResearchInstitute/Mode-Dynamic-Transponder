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
--                ┌──────────────────────────────────────────────────────┐
--                │           haifuraiya_channelizer_top                 │
--                │                                                      │
--                │   ┌────────────────────────┐                         │
--                │   │ polyphase_filterbank_  │                         │
--   sample_re ──►│──►│ parallel (I)           │── parallel bus (I) ──┐  │
--                │   │ 64 branches × 24 taps  │                      │  │
--                │   │ coeffs from .hex       │                      │  │
--                │   └────────────────────────┘                      ▼  │
--                │   ┌────────────────────────┐         ┌───────────────┐
--                │   │ polyphase_filterbank_  │         │ parallel-to-  │
--   sample_im ──►│──►│ parallel (Q)           │── parallel bus (Q) ──►│   sequential  │── ► fft_64pt
--                │   │ 64 branches × 24 taps  │         │   adapter     │     ──►  channel out
--                │   │ coeffs from .hex       │         │               │
--                │   └────────────────────────┘         └───────────────┘
--                │                                                      │
--                └──────────────────────────────────────────────────────┘
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_channelizer_top is
    generic (
        -- Channelizer dimensions (Haifuraiya defaults)
        N_CHANNELS       : positive := 64;
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

    -- FFT input drive
    signal fft_x_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft_x_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal fft_x_idx   : std_logic_vector(5 downto 0) := (others => '0');
    signal fft_x_valid : std_logic := '0';
    signal fft_x_last  : std_logic := '0';

    -- FFT outputs
    signal fft_busy      : std_logic;
    signal fft_out_re    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft_out_im    : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal fft_out_idx   : std_logic_vector(5 downto 0);
    signal fft_out_valid : std_logic;
    signal fft_out_last  : std_logic;

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
    -- Parallel-to-Sequential Adapter
    -- (Unchanged from serial-MAC version: still bridges parallel filterbank
    -- bus to the sequential fft_64pt input.)
    ---------------------------------------------------------------------------
    p_p2s : process(clk)
    begin
        if rising_edge(clk) then
            -- Default deassertions
            fft_x_valid     <= '0';
            fft_x_last      <= '0';
            frame_dropped_r <= '0';

            if reset = '1' then
                p2s_state <= P2S_WAITING;
                p2s_idx   <= (others => '0');
            else
                case p2s_state is

                    when P2S_WAITING =>
                        if fb_i_outputs_valid = '1' then
                            if fft_busy = '1' then
                                -- FFT still busy with previous frame; drop this one
                                frame_dropped_r <= '1';
                            else
                                -- Capture parallel buses into bin arrays
                                for i in 0 to N_CHANNELS - 1 loop
                                    latched_re(i) <= fb_i_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                    latched_im(i) <= fb_q_outputs(
                                        (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                end loop;
                                p2s_state <= P2S_STREAMING;
                                p2s_idx   <= (others => '0');
                            end if;
                        end if;

                    when P2S_STREAMING =>
                        fft_x_valid <= '1';
                        fft_x_re    <= latched_re(to_integer(p2s_idx));
                        fft_x_im    <= latched_im(to_integer(p2s_idx));
                        fft_x_idx   <= std_logic_vector(resize(p2s_idx, 6));
                        if p2s_idx = N_CHANNELS - 1 then
                            fft_x_last <= '1';
                            p2s_state  <= P2S_WAITING;
                            p2s_idx    <= (others => '0');
                        else
                            p2s_idx <= p2s_idx + 1;
                        end if;

                end case;
            end if;
        end if;
    end process p_p2s;

    ---------------------------------------------------------------------------
    -- 64-Point FFT
    ---------------------------------------------------------------------------
    u_fft : entity work.fft_64pt
        generic map (
            DATA_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_re      => fft_x_re,
            x_im      => fft_x_im,
            x_idx     => fft_x_idx,
            x_valid   => fft_x_valid,
            x_last    => fft_x_last,
            out_re    => fft_out_re,
            out_im    => fft_out_im,
            out_idx   => fft_out_idx,
            out_valid => fft_out_valid,
            out_last  => fft_out_last,
            busy      => fft_busy
        );

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    channel_re    <= fft_out_re;
    channel_im    <= fft_out_im;
    channel_idx   <= fft_out_idx;
    channel_valid <= fft_out_valid;
    channel_last  <= fft_out_last;
    ready         <= ready_r;
    frame_dropped <= frame_dropped_r;

end architecture rtl;
