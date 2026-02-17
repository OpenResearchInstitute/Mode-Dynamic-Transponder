-------------------------------------------------------------------------------
-- fft_4pt.vhd
-- 4-Point FFT for MDT Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- A 4-point FFT converts 4 time-domain samples into 4 frequency bins.
-- In the polyphase channelizer, the FFT follows the filterbank and performs
-- the final frequency separation into N channels.
--
-- For N=4 channels at 40 ksps input:
--   - Channel 0: DC (0 kHz)
--   - Channel 1: +10 kHz  
--   - Channel 2: ±20 kHz (Nyquist edge)
--   - Channel 3: -10 kHz
--
-------------------------------------------------------------------------------
-- 4-POINT FFT STRUCTURE
-------------------------------------------------------------------------------
-- A 4-point radix-2 FFT has 2 stages of butterflies:
--
--   Input      Stage 1         Stage 2        Output
--   (bit-rev)  (twiddle=1)     (twiddles)     (natural order)
--
--   x[0] ──────┬──────(+)──────┬──────(+)────► X[0]
--              │       │       │       │
--              └──(+)──┼───────┼──(+)──┼────► X[1]
--                  │   │       │   │   │
--   x[2] ──────┬───┘   │       │   │   │
--              │       │       │   │   │
--              └──────(-)──────┼───┼───┼────► X[2]  
--                              │   │   │
--   x[1] ──────┬──────(+)──────┘   │   │
--              │       │           │   │
--              └──(+)──┼───────────┘   │
--                  │   │               │
--   x[3] ──────┬───┘   │               │
--              │       │               │
--              └──────(-)──────────────┘───► X[3]
--
-- Actually, for clarity, here's the DIF (decimation-in-frequency) structure:
--
--   Stage 1: 2-point DFTs on pairs (0,2) and (1,3)
--   Stage 2: 2-point DFTs with twiddle W4^0=1 and W4^1=-j
--
-------------------------------------------------------------------------------
-- TWIDDLE FACTORS
-------------------------------------------------------------------------------
-- For a 4-point FFT, the twiddle factors are:
--
--   W4^0 = 1      = ( 1,  0)
--   W4^1 = -j     = ( 0, -1)
--   W4^2 = -1     = (-1,  0)
--   W4^3 = j      = ( 0,  1)
--
-- Since all twiddles are ±1 or ±j, NO MULTIPLIERS are needed!
-- We just do additions, subtractions, and swap/negate real/imag parts.
--
-- Multiply by -j: (a + jb) × (-j) = b - ja
--   Real_out = Imag_in
--   Imag_out = -Real_in
--
-------------------------------------------------------------------------------
-- IMPLEMENTATION
-------------------------------------------------------------------------------
-- This is a fully combinatorial implementation (no pipelining).
-- For 40 ksps sample rate on MDT, timing is not critical.
--
-- For higher speeds (Haifuraiya), use fft_64pt which will be pipelined.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
--        ____      ____
-- clk   |    |____|    |____
--
--       ─────┐         ┌─────
-- valid_in   └─────────┘
--
--       ═════╳═════════╳═════
-- x_in       ║ (data)  ║
--       ═════╪═════════╪═════
--
--             ┌─────────┐
-- valid_out ──┘         └────   (1 cycle latency)
--
--       ═════════╳═══════════
-- X_out         ║ (result)
--       ═════════╪═══════════
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fft_4pt is
    generic (
        -- Input data width (real and imaginary parts separately)
        DATA_WIDTH : positive := 36
    );
    port (
        -- Clock and reset
        clk       : in  std_logic;
        reset     : in  std_logic;
        
        -- Input: 4 complex samples (from polyphase filterbank)
        -- Each sample is DATA_WIDTH bits real + DATA_WIDTH bits imag
        -- Packed as: x0_re, x0_im, x1_re, x1_im, x2_re, x2_im, x3_re, x3_im
        x_in      : in  std_logic_vector(4 * 2 * DATA_WIDTH - 1 downto 0);
        valid_in  : in  std_logic;
        
        -- Output: 4 complex frequency bins
        -- Same packing as input
        X_out     : out std_logic_vector(4 * 2 * DATA_WIDTH - 1 downto 0);
        valid_out : out std_logic
    );
end entity fft_4pt;

architecture rtl of fft_4pt is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant SAMPLE_WIDTH : positive := 2 * DATA_WIDTH;  -- Complex = re + im
    
    -- Extra bits to prevent overflow (2 stages = 2 bits growth)
    constant GUARD_BITS   : positive := 2;
    constant INTERNAL_WIDTH : positive := DATA_WIDTH + GUARD_BITS;

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type complex_t is record
        re : signed(INTERNAL_WIDTH - 1 downto 0);
        im : signed(INTERNAL_WIDTH - 1 downto 0);
    end record;
    
    type complex_array_t is array (0 to 3) of complex_t;

    ---------------------------------------------------------------------------
    -- Functions
    ---------------------------------------------------------------------------
    
    -- Extract complex sample from packed input
    function unpack_sample(
        packed : std_logic_vector;
        index  : natural;
        width  : positive
    ) return complex_t is
        variable result : complex_t;
        variable base   : natural;
    begin
        base := index * 2 * width;
        result.re := resize(signed(packed(base + width - 1 downto base)), INTERNAL_WIDTH);
        result.im := resize(signed(packed(base + 2*width - 1 downto base + width)), INTERNAL_WIDTH);
        return result;
    end function;
    
    -- Pack complex sample into output vector
    function pack_sample(
        sample : complex_t;
        width  : positive
    ) return std_logic_vector is
        variable result : std_logic_vector(2 * width - 1 downto 0);
    begin
        -- Truncate back to original width (drop guard bits)
        result(width - 1 downto 0) := std_logic_vector(sample.re(width - 1 downto 0));
        result(2*width - 1 downto width) := std_logic_vector(sample.im(width - 1 downto 0));
        return result;
    end function;
    
    -- Butterfly: returns (a + b, a - b)
    procedure butterfly(
        a : in complex_t;
        b : in complex_t;
        sum : out complex_t;
        diff : out complex_t
    ) is
    begin
        sum.re := a.re + b.re;
        sum.im := a.im + b.im;
        diff.re := a.re - b.re;
        diff.im := a.im - b.im;
    end procedure;
    
    -- Multiply by -j: (a + jb) × (-j) = b - ja
    function mult_neg_j(x : complex_t) return complex_t is
        variable result : complex_t;
    begin
        result.re := x.im;
        result.im := -x.re;
        return result;
    end function;

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal x_samples : complex_array_t;  -- Input samples (unpacked)
    signal X_bins    : complex_array_t;  -- Output bins
    
    -- Intermediate results
    signal s1 : complex_array_t;     -- After stage 1
    
    -- Pipeline register
    signal X_reg : complex_array_t;
    signal valid_reg : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Unpack inputs
    ---------------------------------------------------------------------------
    process(x_in)
    begin
        for i in 0 to 3 loop
            x_samples(i) <= unpack_sample(x_in, i, DATA_WIDTH);
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- FFT Computation (DIT - Decimation in Time)
    ---------------------------------------------------------------------------
    -- Stage 1: Butterflies on (x0,x2) and (x1,x3) - no twiddles
    -- Stage 2: Butterflies on results with twiddle W4^1 = -j on second pair
    ---------------------------------------------------------------------------
    process(x_samples)
        variable t0, t1, t2, t3 : complex_t;
        variable s1_0, s1_1, s1_2, s1_3 : complex_t;
    begin
        -- Stage 1: 2-point DFTs
        -- Butterfly on (x[0], x[2])
        butterfly(x_samples(0), x_samples(2), s1_0, s1_2);
        
        -- Butterfly on (x[1], x[3])
        butterfly(x_samples(1), x_samples(3), s1_1, s1_3);
        
        -- Stage 2: Final butterflies with twiddles
        -- X[0] = s1_0 + s1_1 (twiddle = W4^0 = 1)
        -- X[1] = s1_2 + s1_3 * W4^1 = s1_2 + s1_3 * (-j)
        -- X[2] = s1_0 - s1_1 (twiddle = W4^0 = 1, but subtract)
        -- X[3] = s1_2 - s1_3 * W4^1 = s1_2 - s1_3 * (-j)
        
        butterfly(s1_0, s1_1, X_bins(0), X_bins(2));
        
        -- For X[1] and X[3], apply -j twiddle to s1_3 first
        t3 := mult_neg_j(s1_3);
        butterfly(s1_2, t3, X_bins(1), X_bins(3));
    end process;

    ---------------------------------------------------------------------------
    -- Output Register (1 cycle latency)
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_reg <= '0';
                for i in 0 to 3 loop
                    X_reg(i).re <= (others => '0');
                    X_reg(i).im <= (others => '0');
                end loop;
            else
                valid_reg <= valid_in;
                if valid_in = '1' then
                    X_reg <= X_bins;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Pack outputs
    ---------------------------------------------------------------------------
    process(X_reg)
    begin
        for i in 0 to 3 loop
            X_out((i+1) * SAMPLE_WIDTH - 1 downto i * SAMPLE_WIDTH) 
                <= pack_sample(X_reg(i), DATA_WIDTH);
        end loop;
    end process;
    
    valid_out <= valid_reg;

end architecture rtl;
