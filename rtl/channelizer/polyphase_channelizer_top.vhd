-------------------------------------------------------------------------------
-- polyphase_channelizer_top.vhd
-- Top-Level Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the top-level module that integrates all components:
--
--   1. Coefficient ROM - stores filter coefficients
--   2. Polyphase Filterbank - N branches of FIR filters
--   3. FFT - converts filtered outputs to frequency channels
--
-- The channelizer takes streaming input samples and produces N frequency
-- channel outputs.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                 ┌──────────────────────────────────────────────────────┐
--                 │           polyphase_channelizer_top                  │
--                 │                                                      │
--                 │  ┌───────────┐    ┌──────────────────┐    ┌───────┐ │
--  sample_in ────►│  │           │    │                  │    │       │ │
--                 │  │ coeff_rom │───►│ polyphase_       │───►│  FFT  │─┼──► channel_out
--  sample_valid ─►│  │           │    │ filterbank       │    │       │ │
--                 │  └───────────┘    │                  │    │ 4pt/  │ │
--                 │                   │  N fir_branches  │    │ 64pt  │ │
--                 │                   └──────────────────┘    └───────┘ │
--                 │                                                      │
--                 │                              channel_valid ─────────►│
--                 └──────────────────────────────────────────────────────┘
--
-------------------------------------------------------------------------------
-- OPERATION
-------------------------------------------------------------------------------
-- 1. On reset, coefficients are loaded from ROM into filterbank
-- 2. Input samples arrive one at a time (sample_in, sample_valid)
-- 3. Samples are distributed round-robin to N filter branches
-- 4. After N samples, filterbank outputs are fed to FFT
-- 5. FFT produces N frequency channel outputs
-- 6. Channel outputs are valid when channel_valid asserts
--
-------------------------------------------------------------------------------
-- CONFIGURATIONS
-------------------------------------------------------------------------------
-- The design supports two configurations via generics:
--
--   MDT (iCE40 UltraPlus):
--     - N_CHANNELS = 4
--     - TAPS_PER_BRANCH = 16
--     - 4-point FFT
--     - 40 ksps input → 10 ksps per channel
--
--   Haifuraiya (ZCU102):
--     - N_CHANNELS = 64
--     - TAPS_PER_BRANCH = 24
--     - 64-point FFT  
--     - 10 Msps input → 156.25 ksps per channel
--
-------------------------------------------------------------------------------
-- ACTIVE CONFIGURATION
-------------------------------------------------------------------------------
-- This file implements the MDT configuration with 4-point FFT.
-- For Haifuraiya, a separate top-level or generate statement would
-- instantiate the 64-point FFT instead.
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
        
        -- Coefficient file path
        COEFF_FILE      : string := "mdt_coeffs.hex"
    );
    port (
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;
        
        -- Input sample stream
        sample_re       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_im       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid    : in  std_logic;
        
        -- Output channels
        -- For MDT: 4 channels × (ACCUM_WIDTH real + ACCUM_WIDTH imag)
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
    -- Signals: Coefficient ROM
    ---------------------------------------------------------------------------
    signal coeff_addr : std_logic_vector(COEFF_ADDR_WIDTH - 1 downto 0);
    signal coeff_data : std_logic_vector(COEFF_WIDTH - 1 downto 0);
    signal coeff_load : std_logic;

    ---------------------------------------------------------------------------
    -- Signals: Filterbank
    ---------------------------------------------------------------------------
    signal fb_sample_in    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal fb_outputs      : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_outputs_valid: std_logic;

    ---------------------------------------------------------------------------
    -- Signals: FFT (4-point for MDT)
    ---------------------------------------------------------------------------
    signal fft_in          : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal fft_valid_in    : std_logic;
    signal fft_out         : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal fft_valid_out   : std_logic;

    ---------------------------------------------------------------------------
    -- State
    ---------------------------------------------------------------------------
    signal coeffs_loaded   : std_logic := '0';

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
    -- Polyphase Filterbank
    ---------------------------------------------------------------------------
    -- Note: For complex input, we process real and imaginary separately
    -- This simplified version only processes the real part
    -- A full implementation would have two filterbanks or interleaved processing
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
            clk            => clk,
            reset          => reset,
            sample_in      => sample_re,  -- Process real part
            sample_valid   => sample_valid,
            coeff_addr     => coeff_addr,
            coeff_data     => coeff_data,
            coeff_load     => coeff_load,
            branch_outputs => fb_outputs,
            outputs_valid  => fb_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Track when coefficients are loaded
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                coeffs_loaded <= '0';
            elsif coeff_load = '0' and coeffs_loaded = '0' then
                -- coeff_load went low, coefficients are loaded
                coeffs_loaded <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Prepare FFT Input
    ---------------------------------------------------------------------------
    -- Pack filterbank outputs for FFT
    -- For now, imaginary parts are zero (real-only processing)
    ---------------------------------------------------------------------------
    gen_fft_input : for i in 0 to N_CHANNELS - 1 generate
        -- Real part from filterbank
        fft_in((i * 2 + 1) * ACCUM_WIDTH - 1 downto i * 2 * ACCUM_WIDTH) 
            <= fb_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
        -- Imaginary part = 0
        fft_in((i * 2 + 2) * ACCUM_WIDTH - 1 downto (i * 2 + 1) * ACCUM_WIDTH) 
            <= (others => '0');
    end generate gen_fft_input;
    
    fft_valid_in <= fb_outputs_valid;

    ---------------------------------------------------------------------------
    -- 4-Point FFT (MDT configuration)
    ---------------------------------------------------------------------------
    -- Note: Only instantiated for N_CHANNELS = 4
    -- For N_CHANNELS = 64, use fft_64pt instead
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
    ready         <= coeffs_loaded and not coeff_load;

end architecture rtl;
