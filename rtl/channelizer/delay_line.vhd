-------------------------------------------------------------------------------
-- delay_line.vhd
-- Sample Delay Line for Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- A delay line is a shift register that stores sample history. In an FIR 
-- filter, we compute:
--
--   y[n] = h[0]·x[n] + h[1]·x[n-1] + h[2]·x[n-2] + ... + h[M-1]·x[n-(M-1)]
--
-- The delay line provides x[n], x[n-1], x[n-2], etc. - the current sample
-- and its history - so each coefficient h[k] multiplies the correct sample.
--
-------------------------------------------------------------------------------
-- ROLE IN POLYPHASE CHANNELIZER  
-------------------------------------------------------------------------------
-- In a polyphase channelizer with N channels, input samples are distributed
-- round-robin across N branches:
--
--   Sample index:  0  1  2  3  4  5  6  7  8  9  10 11 ...
--   Goes to branch: 0  1  2  3  0  1  2  3  0  1  2  3 ...  (for N=4)
--
-- Each branch has its own delay line. Branch 0 sees samples 0, 4, 8, 12...
-- Branch 1 sees samples 1, 5, 9, 13... and so on.
--
-- This module implements ONE delay line for ONE branch. The top-level 
-- channelizer instantiates N of these (4 for MDT, 64 for Haifuraiya).
--
-------------------------------------------------------------------------------
-- OPERATION
-------------------------------------------------------------------------------
-- When 'shift_en' is asserted:
--   1. All values shift down by one position
--   2. 'data_in' enters at position 0 (newest)
--   3. The oldest value falls off the end (discarded)
--
-- Example with M=4 taps, showing shift operation:
--
--   Before shift (shift_en=0):
--   ┌────────┬────────┬────────┬────────┐
--   │ x[n-3] │ x[n-2] │ x[n-1] │  x[n]  │
--   └────────┴────────┴────────┴────────┘
--     tap[3]   tap[2]   tap[1]   tap[0]    ← Output indices
--     oldest                     newest
--
--   After shift with new sample x[n+1] (shift_en=1):
--   ┌────────┬────────┬────────┬────────┐
--   │ x[n-2] │ x[n-1] │  x[n]  │ x[n+1] │
--   └────────┴────────┴────────┴────────┘
--     tap[3]   tap[2]   tap[1]   tap[0]
--              ← everything shifts left, new sample enters at tap[0]
--
-- The 'taps' output provides all M values simultaneously, allowing
-- parallel multiplication with coefficients.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
--        ____      ____      ____      ____
-- clk   |    |____|    |____|    |____|    |____
--
--       ─────────┐         ┌─────────
-- shift_en      │         │           (pulse when new sample for this branch)
--       ────────┴─────────┴─────────
--
--       ══════════════════╳═══════════════════
-- data_in    (old)        │    (new sample)
--       ══════════════════╪═══════════════════
--                         │
--                         ▼
--       ══════════════════╳═══════════════════
-- taps      (old values)  │  (shifted, includes new sample)
--       ══════════════════╪═══════════════════
--
-- Output 'taps' updates on the clock edge when shift_en=1.
-- When shift_en=0, taps holds its previous value.
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE
-------------------------------------------------------------------------------
-- This module uses flip-flops (registers), not Block RAM.
--
--   Flip-flops = DELAY_DEPTH × DATA_WIDTH
--
--   MDT (one branch):        16 × 16 = 256 FFs
--   Haifuraiya (one branch): 24 × 16 = 384 FFs
--
--   Total for all branches:
--     MDT:        4 branches × 256 = 1,024 FFs
--     Haifuraiya: 64 branches × 384 = 24,576 FFs
--
-- For Haifuraiya on ZCU102 (548K FFs available), this is < 5% utilization.
-- For MDT on iCE40 UP (~5K FFs available), this is ~20% utilization.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity delay_line is
    generic (
        -- Number of taps (delay depth)
        -- MDT: 16, Haifuraiya: 24
        DELAY_DEPTH : positive := 16;
        
        -- Width of each sample (bits)
        -- Typically 16 for complex I or Q component
        DATA_WIDTH  : positive := 16
    );
    port (
        -- Clock
        clk      : in  std_logic;
        
        -- Synchronous reset (active high)
        -- Clears all taps to zero
        reset    : in  std_logic;
        
        -- Shift enable
        -- Assert for one clock cycle when a new sample arrives for this branch
        -- When low, delay line holds its current values
        shift_en : in  std_logic;
        
        -- Input sample (newest)
        -- Valid when shift_en is high
        data_in  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        
        -- All tap outputs (directly accessible for parallel multiply)
        -- taps(0) = newest sample (just entered)
        -- taps(DELAY_DEPTH-1) = oldest sample
        taps     : out std_logic_vector(DELAY_DEPTH * DATA_WIDTH - 1 downto 0)
    );
end entity delay_line;

architecture rtl of delay_line is

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type delay_array_t is array (0 to DELAY_DEPTH - 1) of 
        std_logic_vector(DATA_WIDTH - 1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal delay_reg : delay_array_t := (others => (others => '0'));

begin

    ---------------------------------------------------------------------------
    -- Shift Register Process
    ---------------------------------------------------------------------------
    -- On each clock edge with shift_en=1:
    --   - Shift all values toward higher indices (older)
    --   - Load new sample at index 0 (newest)
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Clear all taps to zero
                delay_reg <= (others => (others => '0'));
            elsif shift_en = '1' then
                -- Shift toward higher indices
                for i in DELAY_DEPTH - 1 downto 1 loop
                    delay_reg(i) <= delay_reg(i - 1);
                end loop;
                -- Load new sample at index 0
                delay_reg(0) <= data_in;
            end if;
            -- When shift_en='0', hold current values (implicit)
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output Assignment
    ---------------------------------------------------------------------------
    -- Pack all taps into a single vector for easy connection to MAC units
    -- taps(DATA_WIDTH-1 downto 0) = tap 0 (newest)
    -- taps(2*DATA_WIDTH-1 downto DATA_WIDTH) = tap 1
    -- etc.
    ---------------------------------------------------------------------------
    gen_taps: for i in 0 to DELAY_DEPTH - 1 generate
        taps((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH) <= delay_reg(i);
    end generate gen_taps;

end architecture rtl;
