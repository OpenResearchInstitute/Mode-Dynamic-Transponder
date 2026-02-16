-------------------------------------------------------------------------------
-- mac.vhd
-- Multiply-Accumulate Unit for Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- The MAC (Multiply-Accumulate) unit computes the dot product of filter
-- coefficients and delay line samples:
--
--   result = Σ (coeff[k] × sample[k])  for k = 0 to M-1
--
-- This is the core operation of an FIR filter. Each polyphase branch has
-- one MAC that processes its delay line against its coefficients.
--
-------------------------------------------------------------------------------
-- OPERATION MODES
-------------------------------------------------------------------------------
-- This MAC supports two modes of operation:
--
-- 1. SEQUENTIAL MODE (resource-efficient, used for MDT on iCE40):
--    - One multiplier, processes taps one at a time
--    - Takes M clock cycles to complete
--    - Uses: 1 multiplier, 1 accumulator
--
-- 2. PARALLEL MODE (fast, could be used for Haifuraiya):
--    - All taps multiplied simultaneously
--    - Completes in fewer cycles (tree adder)
--    - Uses: M multipliers, adder tree
--    - NOT IMPLEMENTED in this version (future enhancement)
--
-- This implementation uses SEQUENTIAL mode for simplicity and portability.
--
-------------------------------------------------------------------------------
-- SEQUENTIAL OPERATION TIMING
-------------------------------------------------------------------------------
-- To compute the FIR output for one set of samples:
--
--   1. Assert 'start' for one cycle with coefficients and samples valid
--   2. MAC iterates through all M taps (M clock cycles)
--   3. 'done' asserts when result is valid
--   4. Read 'result', then start next computation
--
--         ____      ____      ____      ____      ____      ____
--  clk   |    |____|    |____|    |____|    |____|    |____|    |
--
--        ─────┐                                            ┌─────
--  start      └────────────────────────────────────────────┘
--
--        ═════╳════════════════════════════════════════════╳═════
--  coeffs     ║  (must remain stable during computation)   ║
--        ═════╪════════════════════════════════════════════╪═════
--
--        ═════╳════════════════════════════════════════════╳═════
--  samples    ║  (must remain stable during computation)   ║
--        ═════╪════════════════════════════════════════════╪═════
--
--                                                    ┌───────────
--  done  ────────────────────────────────────────────┘
--
--        ════════════════════════════════════════════╳═══════════
--  result                (invalid)                   ║  (valid)
--        ════════════════════════════════════════════╪═══════════
--
--        |<──────────── M clock cycles ─────────────>|
--
-------------------------------------------------------------------------------
-- FIXED-POINT ARITHMETIC
-------------------------------------------------------------------------------
-- Input samples:     DATA_WIDTH bits (signed, e.g., 16-bit Q1.14)
-- Coefficients:      COEFF_WIDTH bits (signed, e.g., 16-bit Q1.14)
-- Product:           DATA_WIDTH + COEFF_WIDTH bits (e.g., 32-bit)
-- Accumulator:       ACCUM_WIDTH bits (must be wide enough for sum of M products)
--
-- Required accumulator width to avoid overflow:
--   ACCUM_WIDTH >= DATA_WIDTH + COEFF_WIDTH + ceil(log2(M))
--
--   MDT:        16 + 16 + ceil(log2(16)) = 36 bits
--   Haifuraiya: 16 + 16 + ceil(log2(24)) = 37 bits (use 40 for margin)
--
-- The output is the full accumulator width. Truncation/rounding to the
-- desired output width is handled downstream.
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE
-------------------------------------------------------------------------------
-- Sequential mode (this implementation):
--   - 1 multiplier (DATA_WIDTH × COEFF_WIDTH)
--   - 1 accumulator (ACCUM_WIDTH bits)
--   - Counter (log2(M) bits)
--   - Control FSM (few FFs)
--
-- On iCE40 UP: Uses 1 DSP block (if available) or LUT-based multiplier
-- On Xilinx: Uses 1 DSP48 slice
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac is
    generic (
        -- Number of taps to accumulate
        -- MDT: 16, Haifuraiya: 24
        NUM_TAPS    : positive := 16;
        
        -- Width of input samples (signed)
        DATA_WIDTH  : positive := 16;
        
        -- Width of coefficients (signed)
        COEFF_WIDTH : positive := 16;
        
        -- Width of accumulator (must prevent overflow)
        -- Needs: DATA_WIDTH + COEFF_WIDTH + ceil(log2(NUM_TAPS))
        ACCUM_WIDTH : positive := 36
    );
    port (
        -- Clock and reset
        clk     : in  std_logic;
        reset   : in  std_logic;
        
        -- Control
        start   : in  std_logic;    -- Begin new computation
        done    : out std_logic;    -- Result is valid
        
        -- Input: All coefficients packed into one vector
        -- coeff(COEFF_WIDTH-1 downto 0) = coeff[0]
        -- coeff(2*COEFF_WIDTH-1 downto COEFF_WIDTH) = coeff[1]
        -- etc.
        coeffs  : in  std_logic_vector(NUM_TAPS * COEFF_WIDTH - 1 downto 0);
        
        -- Input: All samples packed into one vector (from delay line)
        -- Same packing as coeffs
        samples : in  std_logic_vector(NUM_TAPS * DATA_WIDTH - 1 downto 0);
        
        -- Output: Accumulated result (full precision)
        result  : out std_logic_vector(ACCUM_WIDTH - 1 downto 0)
    );
end entity mac;

architecture rtl of mac is

    ---------------------------------------------------------------------------
    -- Functions
    ---------------------------------------------------------------------------
    
    -- Calculate bits needed to represent values 0 to n-1
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

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant TAP_IDX_WIDTH : positive := clog2(NUM_TAPS);
    constant PRODUCT_WIDTH : positive := DATA_WIDTH + COEFF_WIDTH;

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type state_t is (IDLE, COMPUTING, DONE_STATE);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state     : state_t := IDLE;
    signal tap_idx   : unsigned(TAP_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal accum     : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    
    -- Current tap's coefficient and sample
    signal curr_coeff  : signed(COEFF_WIDTH - 1 downto 0);
    signal curr_sample : signed(DATA_WIDTH - 1 downto 0);
    signal product     : signed(PRODUCT_WIDTH - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Extract current coefficient and sample based on tap index
    ---------------------------------------------------------------------------
    process(coeffs, samples, tap_idx)
        variable idx : integer;
    begin
        idx := to_integer(tap_idx);
        
        curr_coeff <= signed(
            coeffs((idx + 1) * COEFF_WIDTH - 1 downto idx * COEFF_WIDTH)
        );
        
        curr_sample <= signed(
            samples((idx + 1) * DATA_WIDTH - 1 downto idx * DATA_WIDTH)
        );
    end process;

    ---------------------------------------------------------------------------
    -- Multiplier
    ---------------------------------------------------------------------------
    product <= curr_coeff * curr_sample;

    ---------------------------------------------------------------------------
    -- MAC State Machine
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state   <= IDLE;
                tap_idx <= (others => '0');
                accum   <= (others => '0');
            else
                case state is
                    
                    when IDLE =>
                        if start = '1' then
                            -- Begin new computation
                            tap_idx <= (others => '0');
                            accum   <= (others => '0');
                            state   <= COMPUTING;
                        end if;
                    
                    when COMPUTING =>
                        -- Accumulate current product
                        accum <= accum + resize(product, ACCUM_WIDTH);
                        
                        if tap_idx = NUM_TAPS - 1 then
                            -- Last tap - done
                            state <= DONE_STATE;
                        else
                            -- More taps to process
                            tap_idx <= tap_idx + 1;
                        end if;
                    
                    when DONE_STATE =>
                        -- Hold result until next start
                        if start = '1' then
                            -- New computation requested
                            tap_idx <= (others => '0');
                            accum   <= (others => '0');
                            state   <= COMPUTING;
                        end if;
                
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    done   <= '1' when state = DONE_STATE else '0';
    result <= std_logic_vector(accum);

end architecture rtl;
