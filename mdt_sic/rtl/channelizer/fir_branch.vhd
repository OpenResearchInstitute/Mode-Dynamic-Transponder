-------------------------------------------------------------------------------
-- fir_branch.vhd
-- Single FIR Filter Branch for Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- A FIR branch combines a delay line and MAC unit to implement one branch
-- of the polyphase filterbank. Each branch:
--
--   1. Receives input samples (one every N clock cycles, where N = channels)
--   2. Stores sample history in a delay line
--   3. Multiplies all taps by their coefficients and sums (MAC)
--   4. Outputs the filter result
--
-- The polyphase channelizer instantiates N of these branches (4 for MDT,
-- 64 for Haifuraiya), each processing every Nth input sample.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                         ┌─────────────────────────────────────┐
--                         │           fir_branch                │
--                         │                                     │
--    sample_in ──────────►│──┐                                  │
--                         │  │    ┌────────────┐                │
--    sample_valid ───────►│──┼───►│ delay_line │                │
--                         │  │    │            │                │
--                         │  │    │ shift_en   │                │
--                         │  │    │            │  taps          │
--                         │  │    └─────┬──────┘                │
--                         │  │          │                       │
--                         │  │          ▼                       │
--                         │  │    ┌────────────┐                │
--    coeffs ─────────────►│──┼───►│    mac     │                │
--                         │  │    │            │                │
--                         │  │    │ start      │                │
--                         │  │    │       done │───────────────►│───► result_valid
--                         │  │    │     result │───────────────►│───► result
--                         │  │    └────────────┘                │
--                         │                                     │
--                         └─────────────────────────────────────┘
--
-------------------------------------------------------------------------------
-- OPERATION TIMING
-------------------------------------------------------------------------------
-- When a new sample arrives (sample_valid=1):
--
--   1. Sample enters the delay line (shift)
--   2. MAC computation starts automatically
--   3. After M cycles, result_valid asserts with the filter output
--
--         ____      ____      ____             ____      ____
--  clk   |    |____|    |____|    |__ ••• __|    |____|    |
--
--        ─────┐                                      
--  sample     └──────────────────────────────────────────────
--  valid
--
--        ═════╳══════════════════════════════════════════════
--  sample_in  ║ new sample                            
--        ═════╪══════════════════════════════════════════════
--
--                                               ┌────────────
--  result                                       │            
--  valid  ──────────────────────────────────────┘
--
--        ═══════════════════════════════════════╳════════════
--  result          (computing)                  ║ valid
--        ═══════════════════════════════════════╪════════════
--
--        |<──────────── M cycles ─────────────>|
--
-------------------------------------------------------------------------------
-- COEFFICIENTS
-------------------------------------------------------------------------------
-- Coefficients are provided as an input port, not stored internally.
-- This allows:
--   - Sharing a single coefficient ROM across all branches
--   - The parent module (polyphase_filterbank) manages coefficient addressing
--
-- The coeffs input must remain stable during MAC computation (M cycles).
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE (per branch)
-------------------------------------------------------------------------------
--   Delay line: TAPS_PER_BRANCH × DATA_WIDTH flip-flops
--   MAC:        1 multiplier + 1 accumulator + small FSM
--
--   MDT (one branch):        256 FFs + 1 mult
--   Haifuraiya (one branch): 384 FFs + 1 mult
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fir_branch is
    generic (
        -- Number of taps in this branch
        -- MDT: 16, Haifuraiya: 24
        TAPS_PER_BRANCH : positive := 16;
        
        -- Width of input samples (signed)
        DATA_WIDTH      : positive := 16;
        
        -- Width of coefficients (signed)
        COEFF_WIDTH     : positive := 16;
        
        -- Width of accumulator/output
        -- Must be >= DATA_WIDTH + COEFF_WIDTH + ceil(log2(TAPS_PER_BRANCH))
        ACCUM_WIDTH     : positive := 36
    );
    port (
        -- Clock and reset
        clk          : in  std_logic;
        reset        : in  std_logic;
        
        -- Sample input
        sample_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid : in  std_logic;  -- Assert for one cycle when new sample arrives
        
        -- Coefficients for this branch (from coefficient ROM or external source)
        -- Must remain stable during computation (TAPS_PER_BRANCH cycles)
        -- Packed format: coeff[0] in LSBs, coeff[TAPS_PER_BRANCH-1] in MSBs
        coeffs       : in  std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
        
        -- Filter output
        result       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        result_valid : out std_logic   -- Asserts when result is valid
    );
end entity fir_branch;

architecture rtl of fir_branch is

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    
    -- Delay line outputs (all taps)
    signal delay_taps : std_logic_vector(TAPS_PER_BRANCH * DATA_WIDTH - 1 downto 0);
    
    -- MAC control and output
    signal mac_start  : std_logic;
    signal mac_done   : std_logic;
    signal mac_result : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    
    -- State for coordinating delay line and MAC
    signal computing  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Delay Line Instance
    ---------------------------------------------------------------------------
    -- Stores sample history for this branch
    ---------------------------------------------------------------------------
    u_delay_line : entity work.delay_line
        generic map (
            DELAY_DEPTH => TAPS_PER_BRANCH,
            DATA_WIDTH  => DATA_WIDTH
        )
        port map (
            clk      => clk,
            reset    => reset,
            shift_en => sample_valid,
            data_in  => sample_in,
            taps     => delay_taps
        );

    ---------------------------------------------------------------------------
    -- MAC Instance
    ---------------------------------------------------------------------------
    -- Computes dot product of coefficients and delay line samples
    ---------------------------------------------------------------------------
    u_mac : entity work.mac
        generic map (
            NUM_TAPS    => TAPS_PER_BRANCH,
            DATA_WIDTH  => DATA_WIDTH,
            COEFF_WIDTH => COEFF_WIDTH,
            ACCUM_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk     => clk,
            reset   => reset,
            start   => mac_start,
            done    => mac_done,
            coeffs  => coeffs,
            samples => delay_taps,
            result  => mac_result
        );

    ---------------------------------------------------------------------------
    -- Control Logic
    ---------------------------------------------------------------------------
    -- Start MAC computation when a new sample arrives
    -- The delay line shifts on the same clock edge, so the MAC sees
    -- the updated taps on the next cycle when it begins computing.
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mac_start <= '0';
                computing <= '0';
            else
                -- Default: don't start
                mac_start <= '0';
                
                if sample_valid = '1' and computing = '0' then
                    -- New sample arrived, start MAC on next cycle
                    -- (delay line will have shifted by then)
                    mac_start <= '1';
                    computing <= '1';
                elsif mac_done = '1' then
                    -- Computation complete, ready for next sample
                    computing <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    result       <= mac_result;
    result_valid <= mac_done;

end architecture rtl;
