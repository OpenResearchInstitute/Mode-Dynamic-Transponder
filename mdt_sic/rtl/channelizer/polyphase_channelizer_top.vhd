-------------------------------------------------------------------------------
-- polyphase_channelizer_top.vhd
-- Top-Level Polyphase Channelizer
-- (Option 3: coeff_loader split out from filterbank; single filterbank still)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the top-level module that integrates the channelizer components:
--
--   1. Coefficient ROM            - stores filter coefficients
--   2. Coefficient Loader (NEW)   - reads ROM, presents wide coeff bus
--   3. Polyphase Filterbank       - N branches of FIR filters
--   4. FFT                        - converts filtered outputs to channels
--
-- The channelizer takes streaming input samples and produces N frequency
-- channel outputs.
--
-- NOTE: Still real-only at this commit. sample_im is wired to the entity
-- but currently ignored downstream; the FFT receives zero on its imaginary
-- input. The second filterbank (for the Q path) will land in a follow-up
-- commit and connect sample_im through to the FFT imag.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                 ┌────────────────────────────────────────────────────────┐
--                 │           polyphase_channelizer_top                    │
--                 │                                                        │
--                 │  ┌───────────┐    ┌──────────────┐                     │
--                 │  │           │    │              │                     │
--                 │  │ coeff_rom │◄──►│ coeff_loader │                     │
--                 │  │           │    │              │                     │
--                 │  └───────────┘    └──────┬───────┘                     │
--                 │                          │ branch_coeffs (wide)        │
--                 │                          │ coeffs_ready                │
--                 │                          ▼                             │
--   sample_re ───►│                  ┌──────────────────┐    ┌───────┐    │
--                 │                  │ polyphase_       │───►│  FFT  │────┼─► channel_out
--   sample_im ────┼─── (unused, Q    │ filterbank       │ ┌─►│       │    │
--                 │     filterbank   │  N fir_branches  │ │  │ 4pt   │    │
--                 │     coming soon) │                  │ │  │       │    │
--                 │                  └──────────────────┘ │  └───────┘    │
--                 │                                       │               │
--                 │                                      '0' (placeholder)│
--                 │                            channel_valid ─────────────►│
--                 └────────────────────────────────────────────────────────┘
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

        -- Input sample stream (sample_im currently unused; second filterbank
        -- in a follow-up commit will connect it through)
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
    -- Signals: Loader -> Filterbank
    ---------------------------------------------------------------------------
    signal branch_coeffs_bus : std_logic_vector(
        N_CHANNELS * TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
    signal coeffs_ready      : std_logic;

    ---------------------------------------------------------------------------
    -- Signals: Filterbank
    ---------------------------------------------------------------------------
    signal fb_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_outputs_valid : std_logic;

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
    -- Coefficient Loader (NEW)
    ---------------------------------------------------------------------------
    -- Owns the LOAD_COEFFS state machine extracted from polyphase_filterbank.
    -- Drives coeff_rom address and presents a wide coefficient bus that one
    -- or more filterbanks can slice. coeffs_ready stays high after loading.
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
    -- Polyphase Filterbank (real path only at this commit)
    ---------------------------------------------------------------------------
    -- For complex input, a second filterbank will handle sample_im in the
    -- next commit. For now, sample_im is ignored downstream.
    ---------------------------------------------------------------------------
    u_filterbank : entity work.polyphase_filterbank
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
            branch_outputs   => fb_outputs,
            outputs_valid    => fb_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Prepare FFT Input
    ---------------------------------------------------------------------------
    -- Pack filterbank outputs for FFT.
    -- Imaginary inputs are zero for now (second filterbank will fill these).
    ---------------------------------------------------------------------------
    gen_fft_input : for i in 0 to N_CHANNELS - 1 generate
        -- Real part from the (only) filterbank
        fft_in((i * 2 + 1) * ACCUM_WIDTH - 1 downto i * 2 * ACCUM_WIDTH)
            <= fb_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
        -- Imaginary part = 0 (placeholder until second filterbank lands)
        fft_in((i * 2 + 2) * ACCUM_WIDTH - 1 downto (i * 2 + 1) * ACCUM_WIDTH)
            <= (others => '0');
    end generate gen_fft_input;

    fft_valid_in <= fb_outputs_valid;

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