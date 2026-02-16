-------------------------------------------------------------------------------
-- fft_64pt.vhd
-- 64-Point FFT for Haifuraiya Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- A 64-point FFT converts 64 time-domain samples into 64 frequency bins.
-- This is used in the Haifuraiya configuration for Opulent Voice FDMA.
--
-- For N=64 channels at 10 Msps input:
--   - Channel spacing: 156.25 kHz
--   - Total bandwidth: 10 MHz
--
-------------------------------------------------------------------------------
-- ARCHITECTURE
-------------------------------------------------------------------------------
-- This implementation uses an iterative radix-2 DIF (Decimation In Frequency)
-- architecture with 6 stages (log2(64) = 6).
--
-- For resource efficiency on FPGA:
--   - Single butterfly unit, time-multiplexed
--   - Twiddle factors stored in ROM
--   - Ping-pong buffers for intermediate results
--
-- Latency: 64 × 6 = 384 cycles (plus a few for pipeline)
--
-- For higher throughput, a pipelined architecture could be used, but that
-- requires more resources (6 butterfly units, more memory).
--
-------------------------------------------------------------------------------
-- TWIDDLE FACTORS
-------------------------------------------------------------------------------
-- W64^k = e^(-j*2*pi*k/64) = cos(2*pi*k/64) - j*sin(2*pi*k/64)
--
-- We need twiddles W64^0 through W64^31 (32 unique values).
-- Stored as fixed-point Q1.14 format (16-bit).
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE
-------------------------------------------------------------------------------
--   - 1 complex multiplier (for twiddle multiplication)
--   - 2 × 64 complex sample buffers (ping-pong)
--   - 32 complex twiddle factors (ROM)
--   - Control FSM and counters
--
-- This is more resource-intensive than fft_4pt but necessary for 64 channels.
--
-------------------------------------------------------------------------------
-- NOTE
-------------------------------------------------------------------------------
-- This is a simplified implementation suitable for demonstration.
-- For production, consider using vendor FFT IP cores (Xilinx FFT, etc.)
-- which are highly optimized.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity fft_64pt is
    generic (
        -- Input data width (real and imaginary parts separately)
        DATA_WIDTH : positive := 40
    );
    port (
        -- Clock and reset
        clk       : in  std_logic;
        reset     : in  std_logic;
        
        -- Input: 64 complex samples (from polyphase filterbank)
        -- Active when valid_in is high; samples are loaded sequentially
        x_re      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        x_im      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        x_idx     : in  std_logic_vector(5 downto 0);  -- 0 to 63
        x_valid   : in  std_logic;
        x_last    : in  std_logic;  -- Asserted with last sample (idx=63)
        
        -- Output: 64 complex frequency bins (output sequentially)
        X_re      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        X_im      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        X_idx     : out std_logic_vector(5 downto 0);
        X_valid   : out std_logic;
        X_last    : out std_logic;
        
        -- Status
        busy      : out std_logic  -- High while computing
    );
end entity fft_64pt;

architecture rtl of fft_64pt is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant N          : positive := 64;
    constant LOG2_N     : positive := 6;
    constant TWIDDLE_WIDTH : positive := 16;  -- Q1.14 format
    
    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type state_t is (IDLE, LOADING, COMPUTING, OUTPUTTING);
    
    type complex_t is record
        re : signed(DATA_WIDTH - 1 downto 0);
        im : signed(DATA_WIDTH - 1 downto 0);
    end record;
    
    type sample_buffer_t is array (0 to N - 1) of complex_t;
    
    -- Twiddle factor type (smaller width)
    type twiddle_t is record
        re : signed(TWIDDLE_WIDTH - 1 downto 0);
        im : signed(TWIDDLE_WIDTH - 1 downto 0);
    end record;
    
    type twiddle_rom_t is array (0 to N/2 - 1) of twiddle_t;

    ---------------------------------------------------------------------------
    -- Functions
    ---------------------------------------------------------------------------
    
    -- Initialize twiddle ROM
    -- W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N)
    function init_twiddle_rom return twiddle_rom_t is
        variable rom : twiddle_rom_t;
        variable angle : real;
        variable scale : real;
    begin
        scale := real(2**(TWIDDLE_WIDTH - 2) - 1);  -- Q1.14 scale
        for k in 0 to N/2 - 1 loop
            angle := 2.0 * MATH_PI * real(k) / real(N);
            rom(k).re := to_signed(integer(cos(angle) * scale), TWIDDLE_WIDTH);
            rom(k).im := to_signed(integer(-sin(angle) * scale), TWIDDLE_WIDTH);
        end loop;
        return rom;
    end function;
    
    -- Bit-reverse a 6-bit index
    function bit_reverse(x : unsigned(5 downto 0)) return unsigned is
        variable result : unsigned(5 downto 0);
    begin
        for i in 0 to 5 loop
            result(i) := x(5 - i);
        end loop;
        return result;
    end function;

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state : state_t := IDLE;
    
    -- Ping-pong buffers
    signal buf_a, buf_b : sample_buffer_t;
    signal use_buf_a    : std_logic := '1';  -- Which buffer is source
    
    -- Twiddle ROM
    constant TWIDDLE_ROM : twiddle_rom_t := init_twiddle_rom;
    
    -- Computation state
    signal stage_cnt    : unsigned(2 downto 0) := (others => '0');  -- 0 to 5
    signal butterfly_cnt: unsigned(5 downto 0) := (others => '0');  -- 0 to 63
    signal pair_cnt     : unsigned(5 downto 0) := (others => '0');
    
    -- Butterfly indices
    signal idx_a, idx_b : unsigned(5 downto 0);
    signal twiddle_idx  : unsigned(5 downto 0);
    
    -- Butterfly computation
    signal bf_a, bf_b   : complex_t;
    signal twiddle      : twiddle_t;
    signal bf_out_a, bf_out_b : complex_t;
    signal bf_valid     : std_logic := '0';
    
    -- Output state
    signal out_cnt      : unsigned(5 downto 0) := (others => '0');
    signal output_done  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                stage_cnt <= (others => '0');
                butterfly_cnt <= (others => '0');
                out_cnt <= (others => '0');
                use_buf_a <= '1';
                bf_valid <= '0';
                output_done <= '0';
            else
                bf_valid <= '0';
                
                case state is
                    
                    when IDLE =>
                        if x_valid = '1' then
                            state <= LOADING;
                        end if;
                    
                    when LOADING =>
                        -- Samples are being loaded into buf_a by separate process
                        if x_last = '1' and x_valid = '1' then
                            state <= COMPUTING;
                            stage_cnt <= (others => '0');
                            butterfly_cnt <= (others => '0');
                            use_buf_a <= '1';
                        end if;
                    
                    when COMPUTING =>
                        bf_valid <= '1';
                        
                        if butterfly_cnt = N/2 - 1 then
                            butterfly_cnt <= (others => '0');
                            use_buf_a <= not use_buf_a;
                            
                            if stage_cnt = LOG2_N - 1 then
                                state <= OUTPUTTING;
                                out_cnt <= (others => '0');
                                output_done <= '0';
                            else
                                stage_cnt <= stage_cnt + 1;
                            end if;
                        else
                            butterfly_cnt <= butterfly_cnt + 1;
                        end if;
                    
                    when OUTPUTTING =>
                        if out_cnt = N - 1 then
                            output_done <= '1';
                            state <= IDLE;
                        else
                            out_cnt <= out_cnt + 1;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Input Loading (bit-reversed order)
    ---------------------------------------------------------------------------
    process(clk)
        variable br_idx : unsigned(5 downto 0);
    begin
        if rising_edge(clk) then
            if state = LOADING or state = IDLE then
                if x_valid = '1' then
                    br_idx := bit_reverse(unsigned(x_idx));
                    buf_a(to_integer(br_idx)).re <= signed(x_re);
                    buf_a(to_integer(br_idx)).im <= signed(x_im);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Butterfly Index Computation
    ---------------------------------------------------------------------------
    -- DIF butterfly addressing for each stage
    process(stage_cnt, butterfly_cnt)
        variable half_size : unsigned(5 downto 0);
        variable group_idx, pair_in_group : unsigned(5 downto 0);
    begin
        -- Half-size of butterfly span at this stage
        half_size := to_unsigned(32, 6) srl to_integer(stage_cnt);
        
        -- Compute butterfly pair indices
        -- This is simplified - actual DIF addressing is more complex
        group_idx := butterfly_cnt srl to_integer(to_unsigned(LOG2_N - 1, 3) - stage_cnt);
        pair_in_group := butterfly_cnt and (half_size - 1);
        
        idx_a <= (group_idx sll (to_integer(to_unsigned(LOG2_N, 3) - stage_cnt))) or pair_in_group;
        idx_b <= idx_a + half_size;
        
        -- Twiddle index
        twiddle_idx <= pair_in_group sll to_integer(stage_cnt);
    end process;

    ---------------------------------------------------------------------------
    -- Butterfly Computation
    ---------------------------------------------------------------------------
    -- Read operands
    process(clk)
    begin
        if rising_edge(clk) then
            if use_buf_a = '1' then
                bf_a <= buf_a(to_integer(idx_a));
                bf_b <= buf_a(to_integer(idx_b));
            else
                bf_a <= buf_b(to_integer(idx_a));
                bf_b <= buf_b(to_integer(idx_b));
            end if;
            twiddle <= TWIDDLE_ROM(to_integer(twiddle_idx(4 downto 0)));
        end if;
    end process;
    
    -- Compute butterfly: DIF structure
    -- out_a = a + b
    -- out_b = (a - b) * twiddle
    process(bf_a, bf_b, twiddle)
        variable diff_re, diff_im : signed(DATA_WIDTH - 1 downto 0);
        variable prod_re, prod_im : signed(DATA_WIDTH + TWIDDLE_WIDTH - 1 downto 0);
    begin
        -- Sum
        bf_out_a.re <= bf_a.re + bf_b.re;
        bf_out_a.im <= bf_a.im + bf_b.im;
        
        -- Difference
        diff_re := bf_a.re - bf_b.re;
        diff_im := bf_a.im - bf_b.im;
        
        -- Complex multiply: (diff_re + j*diff_im) * (tw_re + j*tw_im)
        -- = (diff_re*tw_re - diff_im*tw_im) + j*(diff_re*tw_im + diff_im*tw_re)
        prod_re := diff_re * twiddle.re - diff_im * twiddle.im;
        prod_im := diff_re * twiddle.im + diff_im * twiddle.re;
        
        -- Scale back (Q1.14 twiddles)
        bf_out_b.re <= prod_re(DATA_WIDTH + TWIDDLE_WIDTH - 3 downto TWIDDLE_WIDTH - 2);
        bf_out_b.im <= prod_im(DATA_WIDTH + TWIDDLE_WIDTH - 3 downto TWIDDLE_WIDTH - 2);
    end process;
    
    -- Write results to destination buffer
    process(clk)
    begin
        if rising_edge(clk) then
            if bf_valid = '1' then
                if use_buf_a = '1' then
                    buf_b(to_integer(idx_a)) <= bf_out_a;
                    buf_b(to_integer(idx_b)) <= bf_out_b;
                else
                    buf_a(to_integer(idx_a)) <= bf_out_a;
                    buf_a(to_integer(idx_b)) <= bf_out_b;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output
    ---------------------------------------------------------------------------
    process(clk)
        variable src : complex_t;
    begin
        if rising_edge(clk) then
            if state = OUTPUTTING then
                -- Output from whichever buffer has final results
                if use_buf_a = '1' then
                    src := buf_b(to_integer(out_cnt));
                else
                    src := buf_a(to_integer(out_cnt));
                end if;
                X_re <= std_logic_vector(src.re);
                X_im <= std_logic_vector(src.im);
            end if;
        end if;
    end process;
    
    X_idx <= std_logic_vector(out_cnt);
    X_valid <= '1' when state = OUTPUTTING else '0';
    X_last <= '1' when state = OUTPUTTING and out_cnt = N - 1 else '0';
    busy <= '1' when state /= IDLE else '0';

end architecture rtl;
