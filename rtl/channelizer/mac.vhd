-------------------------------------------------------------------------------
-- mac.vhd
-- Multiply-Accumulate Unit for Polyphase Channelizer (GHDL-compatible)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- This version avoids dynamic array slicing which crashes GHDL 6.0.0
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac is
    generic (
        NUM_TAPS    : positive := 16;
        DATA_WIDTH  : positive := 16;
        COEFF_WIDTH : positive := 16;
        ACCUM_WIDTH : positive := 36
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        start   : in  std_logic;
        done    : out std_logic;
        coeffs  : in  std_logic_vector(NUM_TAPS * COEFF_WIDTH - 1 downto 0);
        samples : in  std_logic_vector(NUM_TAPS * DATA_WIDTH - 1 downto 0);
        result  : out std_logic_vector(ACCUM_WIDTH - 1 downto 0)
    );
end entity mac;

architecture rtl of mac is

    ---------------------------------------------------------------------------
    -- Functions
    ---------------------------------------------------------------------------
    function clog2(n : positive) return positive is
        variable r : positive := 1;
        variable v : positive := 2;
    begin
        while v < n loop
            r := r + 1;
            v := v * 2;
        end loop;
        return r;
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
    
    -- Unpacked coefficient and sample arrays
    type coeff_array_t is array (0 to NUM_TAPS - 1) of signed(COEFF_WIDTH - 1 downto 0);
    type sample_array_t is array (0 to NUM_TAPS - 1) of signed(DATA_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state     : state_t := IDLE;
    signal tap_idx   : unsigned(TAP_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal accum     : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    
    -- Unpacked arrays (avoid dynamic slicing)
    signal coeff_arr  : coeff_array_t;
    signal sample_arr : sample_array_t;
    
    -- Current tap's coefficient and sample
    signal curr_coeff  : signed(COEFF_WIDTH - 1 downto 0);
    signal curr_sample : signed(DATA_WIDTH - 1 downto 0);
    signal product     : signed(PRODUCT_WIDTH - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Unpack coefficients and samples into arrays at input
    -- This is done combinatorially and avoids dynamic slicing in the FSM
    ---------------------------------------------------------------------------
    gen_unpack: for i in 0 to NUM_TAPS - 1 generate
        coeff_arr(i) <= signed(coeffs((i + 1) * COEFF_WIDTH - 1 downto i * COEFF_WIDTH));
        sample_arr(i) <= signed(samples((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH));
    end generate;

    ---------------------------------------------------------------------------
    -- Select current coefficient and sample based on tap index
    ---------------------------------------------------------------------------
    curr_coeff  <= coeff_arr(to_integer(tap_idx));
    curr_sample <= sample_arr(to_integer(tap_idx));

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
                            tap_idx <= (others => '0');
                            accum   <= (others => '0');
                            state   <= COMPUTING;
                        end if;
                    
                    when COMPUTING =>
                        accum <= accum + resize(product, ACCUM_WIDTH);
                        
                        if tap_idx = NUM_TAPS - 1 then
                            state <= DONE_STATE;
                        else
                            tap_idx <= tap_idx + 1;
                        end if;
                    
                    when DONE_STATE =>
                        if start = '1' then
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
