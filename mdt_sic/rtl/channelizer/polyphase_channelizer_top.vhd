-------------------------------------------------------------------------------
-- polyphase_channelizer_top.vhd
-- Top-Level Polyphase Channelizer
-- (Path A complete: complex I/Q via two polyphase_filterbank instances)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the top-level module that integrates the channelizer components:
--
--   1. Coefficient ROM      - stores filter coefficients
--   2. Coefficient Loader   - reads ROM, presents wide coeff bus to all filterbanks
--   3. Polyphase Filterbank (RE) - N branches filtering the real input
--   4. Polyphase Filterbank (IM) - N branches filtering the imaginary input
--   5. FFT                  - converts filtered I+jQ outputs to frequency channels
--
-- With both real and imaginary paths feeding the FFT, the channelizer can
-- now distinguish positive and negative frequencies (e.g., +Fs/4 vs -Fs/4),
-- which the real-only version could not.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                 ┌──────────────────────────────────────────────────────────┐
--                 │           polyphase_channelizer_top                      │
--                 │                                                          │
--                 │  ┌───────────┐    ┌──────────────┐                       │
--                 │  │           │    │              │                       │
--                 │  │ coeff_rom │◄──►│ coeff_loader │                       │
--                 │  │           │    │              │                       │
--                 │  └───────────┘    └──────┬───────┘                       │
--                 │                          │ branch_coeffs (wide)          │
--                 │                          ├──────────────┐                │
--                 │                          │              │                │
--                 │                          ▼              ▼                │
--                 │                  ┌─────────────┐ ┌─────────────┐         │
--   sample_re ───►│─────────────────►│ filterbank  │ │ filterbank  │         │
--                 │                  │   (RE)      │ │   (IM)      │◄────────┼─── sample_im
--                 │                  └──────┬──────┘ └──────┬──────┘         │
--                 │                         │ fb_re        │ fb_im           │
--                 │                         ▼              ▼                 │
--                 │                  ┌─────────────────────────┐             │
--                 │                  │     4-Point FFT         │             │
--                 │                  │   (complex I + jQ)      │             │
--                 │                  └────────────┬────────────┘             │
--                 │                               │                          │
--                 │                               ▼                          │
--                 │                          channel_out  ───────────────────►
--                 │                          channel_valid ──────────────────►
--                 └──────────────────────────────────────────────────────────┘
--
-------------------------------------------------------------------------------
-- RESOURCE NOTES
-------------------------------------------------------------------------------
-- Adding the second filterbank doubles the channelizer's MAC count:
--   N_CHANNELS branches in RE + N_CHANNELS branches in IM = 2*N MACs total.
-- For MDT (N=4), this exactly fills the iCE40UP5K's 8 MAC16 DSP blocks
-- (100% DSP utilization). For Haifuraiya, ZCU102 has ample DSP slices.
--
-- EBR usage grows by N_CHANNELS (one EBR per delay_line in the new filterbank):
--   MDT: 5 -> 9 of 30 EBRs used.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity polyphase_channelizer_top is
    generic (
        -- Number of channels
        N_CHANNELS      : positive := 4;

        -- Taps per polyphase branch
        TAPS_PER_BRANCH : positive := 16;

        -- Data widths
        DATA_WIDTH      : positive := 16;
        COEFF_WIDTH     : positive := 16;
        ACCUM_WIDTH     : positive := 36;

        -- Coefficient file path (informational; ROM is hardcoded for synthesis)
        COEFF_FILE      : string := "mdt_coeffs.hex"
    );
    port (
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Input sample stream (complex)
        sample_re       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_im       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid    : in  std_logic;

        -- Output channels
        -- For MDT: 4 channels x (ACCUM_WIDTH real + ACCUM_WIDTH imag)
        channel_out     : out std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
        channel_valid   : out std_logic;

        -- Status
        ready           : out std_logic  -- High when ready for samples
    );

    -- Function to calculate address width
    function clog2(n : positive) return positive is
        variable result : positive := 1;
        variable value  : positive := 2;
    begin
        while value < n loop
            result := result + 1;
            value := value * 2;
        end loop;
        return result;
    end function;

end entity polyphase_channelizer_top;

architecture rtl of polyphase_channelizer_top is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant TOTAL_COEFFS    : positive := N_CHANNELS * TAPS_PER_BRANCH;
    constant COEFF_ADDR_WIDTH: positive := clog2(TOTAL_COEFFS);

    ---------------------------------------------------------------------------
    -- Signals: Coefficient ROM <-> Loader
    ---------------------------------------------------------------------------
    signal coeff_addr : std_logic_vector(COEFF_ADDR_WIDTH - 1 downto 0);
    signal coeff_data : std_logic_vector(COEFF_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals: Loader -> Filterbanks (shared)
    ---------------------------------------------------------------------------
    signal branch_coeffs_bus : std_logic_vector(
        N_CHANNELS * TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
    signal coeffs_ready      : std_logic;

    ---------------------------------------------------------------------------
    -- Signals: Filterbank outputs (RE and IM paths)
    ---------------------------------------------------------------------------
    signal fb_re_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_re_outputs_valid : std_logic;

    signal fb_im_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_im_outputs_valid : std_logic;

    ---------------------------------------------------------------------------
    -- Signals: FFT (4-point for MDT)
    ---------------------------------------------------------------------------
    signal fft_in        : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal fft_valid_in  : std_logic;
    signal fft_out       : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal fft_valid_out : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Coefficient ROM
    ---------------------------------------------------------------------------
    u_coeff_rom : entity work.coeff_rom
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ADDR_WIDTH      => COEFF_ADDR_WIDTH,
            COEFF_FILE      => COEFF_FILE
        )
        port map (
            clk   => clk,
            addr  => coeff_addr,
            coeff => coeff_data
        );

    ---------------------------------------------------------------------------
    -- Coefficient Loader (shared by both filterbanks)
    ---------------------------------------------------------------------------
    u_coeff_loader : entity work.coeff_loader
        generic map (
            N_CHANNELS       => N_CHANNELS,
            TAPS_PER_BRANCH  => TAPS_PER_BRANCH,
            COEFF_WIDTH      => COEFF_WIDTH,
            COEFF_ADDR_WIDTH => COEFF_ADDR_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,
            coeff_addr        => coeff_addr,
            coeff_data        => coeff_data,
            branch_coeffs_out => branch_coeffs_bus,
            coeffs_ready      => coeffs_ready
        );

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank - Real path
    ---------------------------------------------------------------------------
    -- Filters sample_re. Outputs feed the FFT's real inputs.
    ---------------------------------------------------------------------------
    u_filterbank_re : entity work.polyphase_filterbank
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_re,
            sample_valid     => sample_valid,
            branch_coeffs_in => branch_coeffs_bus,
            coeffs_ready     => coeffs_ready,
            branch_outputs   => fb_re_outputs,
            outputs_valid    => fb_re_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank - Imaginary path (NEW)
    ---------------------------------------------------------------------------
    -- Filters sample_im. Outputs feed the FFT's imaginary inputs.
    -- Shares clk, reset, sample_valid, and coefficients with u_filterbank_re,
    -- so its state machine is cycle-synchronous with the RE filterbank.
    ---------------------------------------------------------------------------
    u_filterbank_im : entity work.polyphase_filterbank
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_im,
            sample_valid     => sample_valid,
            branch_coeffs_in => branch_coeffs_bus,
            coeffs_ready     => coeffs_ready,
            branch_outputs   => fb_im_outputs,
            outputs_valid    => fb_im_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Prepare FFT Input (complex)
    ---------------------------------------------------------------------------
    -- Pack filterbank outputs for FFT:
    --   real(channel i) = u_filterbank_re.branch_outputs(i)
    --   imag(channel i) = u_filterbank_im.branch_outputs(i)
    ---------------------------------------------------------------------------
    gen_fft_input : for i in 0 to N_CHANNELS - 1 generate
        -- Real part from RE filterbank
        fft_in((i * 2 + 1) * ACCUM_WIDTH - 1 downto i * 2 * ACCUM_WIDTH)
            <= fb_re_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
        -- Imaginary part from IM filterbank (was zero before this commit)
        fft_in((i * 2 + 2) * ACCUM_WIDTH - 1 downto (i * 2 + 1) * ACCUM_WIDTH)
            <= fb_im_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
    end generate gen_fft_input;

    -- Both filterbanks are cycle-synchronous (same clk/reset/sample_valid,
    -- identical FSMs), so either outputs_valid signal can trigger the FFT.
    -- We pick RE arbitrarily; IM goes high in the same cycle.
    fft_valid_in <= fb_re_outputs_valid;

    ---------------------------------------------------------------------------
    -- 4-Point FFT (MDT configuration)
    ---------------------------------------------------------------------------
    gen_fft_4pt : if N_CHANNELS = 4 generate
        u_fft : entity work.fft_4pt
            generic map (
                DATA_WIDTH => ACCUM_WIDTH
            )
            port map (
                clk       => clk,
                reset     => reset,
                x_in      => fft_in,
                valid_in  => fft_valid_in,
                X_out     => fft_out,
                valid_out => fft_valid_out
            );
    end generate gen_fft_4pt;

    ---------------------------------------------------------------------------
    -- Output
    ---------------------------------------------------------------------------
    channel_out   <= fft_out;
    channel_valid <= fft_valid_out;
    ready         <= coeffs_ready;

end architecture rtl;