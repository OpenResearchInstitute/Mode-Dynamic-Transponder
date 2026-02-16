-------------------------------------------------------------------------------
-- tb_mac.vhd
-- Testbench for Multiply-Accumulate Unit
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies MAC operation with known inputs and expected results.
--   Tests include:
--     1. Simple case: all coefficients = 1, samples = 1, 2, 3, 4
--     2. Mixed signs: positive and negative values
--     3. Reset behavior
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mac is
end entity tb_mac;

architecture sim of tb_mac is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant NUM_TAPS    : positive := 4;    -- Small for easy verification
    constant DATA_WIDTH  : positive := 16;
    constant COEFF_WIDTH : positive := 16;
    constant ACCUM_WIDTH : positive := 36;
    constant CLK_PERIOD  : time := 10 ns;
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk     : std_logic := '0';
    signal reset   : std_logic := '0';
    signal start   : std_logic := '0';
    signal done    : std_logic;
    signal coeffs  : std_logic_vector(NUM_TAPS * COEFF_WIDTH - 1 downto 0);
    signal samples : std_logic_vector(NUM_TAPS * DATA_WIDTH - 1 downto 0);
    signal result  : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    
    signal running : boolean := true;
    
    ---------------------------------------------------------------------------
    -- Helper: Pack array of integers into coefficient/sample vector
    ---------------------------------------------------------------------------
    procedure pack_values(
        values : in  integer_vector;
        width  : in  positive;
        signal vec : out std_logic_vector
    ) is
        variable tmp : signed(width - 1 downto 0);
    begin
        for i in values'range loop
            tmp := to_signed(values(i), width);
            vec((i + 1) * width - 1 downto i * width) <= std_logic_vector(tmp);
        end loop;
    end procedure;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.mac
        generic map (
            NUM_TAPS    => NUM_TAPS,
            DATA_WIDTH  => DATA_WIDTH,
            COEFF_WIDTH => COEFF_WIDTH,
            ACCUM_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk     => clk,
            reset   => reset,
            start   => start,
            done    => done,
            coeffs  => coeffs,
            samples => samples,
            result  => result
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable result_int : signed(ACCUM_WIDTH - 1 downto 0);
        variable expected   : integer;
    begin
        report "=== MAC Testbench ===" severity note;
        report "Configuration: " & integer'image(NUM_TAPS) & " taps, " &
               integer'image(DATA_WIDTH) & "-bit data, " &
               integer'image(COEFF_WIDTH) & "-bit coeffs" severity note;
        
        -- Initialize inputs
        coeffs  <= (others => '0');
        samples <= (others => '0');
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -----------------------------------------------------------------------
        -- Test 1: Simple sum
        -- coeffs = [1, 1, 1, 1], samples = [1, 2, 3, 4]
        -- Expected: 1*1 + 1*2 + 1*3 + 1*4 = 10
        -----------------------------------------------------------------------
        report "Test 1: coeffs=[1,1,1,1], samples=[1,2,3,4]" severity note;
        
        -- Pack coefficients: all 1s
        coeffs((0+1)*COEFF_WIDTH-1 downto 0*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((1+1)*COEFF_WIDTH-1 downto 1*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((2+1)*COEFF_WIDTH-1 downto 2*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((3+1)*COEFF_WIDTH-1 downto 3*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        
        -- Pack samples: 1, 2, 3, 4
        samples((0+1)*DATA_WIDTH-1 downto 0*DATA_WIDTH) <= std_logic_vector(to_signed(1, DATA_WIDTH));
        samples((1+1)*DATA_WIDTH-1 downto 1*DATA_WIDTH) <= std_logic_vector(to_signed(2, DATA_WIDTH));
        samples((2+1)*DATA_WIDTH-1 downto 2*DATA_WIDTH) <= std_logic_vector(to_signed(3, DATA_WIDTH));
        samples((3+1)*DATA_WIDTH-1 downto 3*DATA_WIDTH) <= std_logic_vector(to_signed(4, DATA_WIDTH));
        
        wait for CLK_PERIOD;
        
        -- Start computation
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        -- Wait for done
        wait until done = '1';
        wait for CLK_PERIOD / 2;  -- Sample in middle of clock
        
        result_int := signed(result);
        expected := 10;
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 1 FAILED!" severity error;
        report "  Test 1 PASSED" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 2: With actual filter-like coefficients
        -- coeffs = [2, 4, 4, 2], samples = [100, 200, 300, 400]
        -- Expected: 2*100 + 4*200 + 4*300 + 2*400 = 200 + 800 + 1200 + 800 = 3000
        -----------------------------------------------------------------------
        report "Test 2: coeffs=[2,4,4,2], samples=[100,200,300,400]" severity note;
        
        coeffs((0+1)*COEFF_WIDTH-1 downto 0*COEFF_WIDTH) <= std_logic_vector(to_signed(2, COEFF_WIDTH));
        coeffs((1+1)*COEFF_WIDTH-1 downto 1*COEFF_WIDTH) <= std_logic_vector(to_signed(4, COEFF_WIDTH));
        coeffs((2+1)*COEFF_WIDTH-1 downto 2*COEFF_WIDTH) <= std_logic_vector(to_signed(4, COEFF_WIDTH));
        coeffs((3+1)*COEFF_WIDTH-1 downto 3*COEFF_WIDTH) <= std_logic_vector(to_signed(2, COEFF_WIDTH));
        
        samples((0+1)*DATA_WIDTH-1 downto 0*DATA_WIDTH) <= std_logic_vector(to_signed(100, DATA_WIDTH));
        samples((1+1)*DATA_WIDTH-1 downto 1*DATA_WIDTH) <= std_logic_vector(to_signed(200, DATA_WIDTH));
        samples((2+1)*DATA_WIDTH-1 downto 2*DATA_WIDTH) <= std_logic_vector(to_signed(300, DATA_WIDTH));
        samples((3+1)*DATA_WIDTH-1 downto 3*DATA_WIDTH) <= std_logic_vector(to_signed(400, DATA_WIDTH));
        
        wait for CLK_PERIOD;
        
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1';
        wait for CLK_PERIOD / 2;
        
        result_int := signed(result);
        expected := 3000;
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 2 FAILED!" severity error;
        report "  Test 2 PASSED" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 3: Mixed signs
        -- coeffs = [1, -1, 1, -1], samples = [10, 20, 30, 40]
        -- Expected: 1*10 + (-1)*20 + 1*30 + (-1)*40 = 10 - 20 + 30 - 40 = -20
        -----------------------------------------------------------------------
        report "Test 3: coeffs=[1,-1,1,-1], samples=[10,20,30,40]" severity note;
        
        coeffs((0+1)*COEFF_WIDTH-1 downto 0*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((1+1)*COEFF_WIDTH-1 downto 1*COEFF_WIDTH) <= std_logic_vector(to_signed(-1, COEFF_WIDTH));
        coeffs((2+1)*COEFF_WIDTH-1 downto 2*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((3+1)*COEFF_WIDTH-1 downto 3*COEFF_WIDTH) <= std_logic_vector(to_signed(-1, COEFF_WIDTH));
        
        samples((0+1)*DATA_WIDTH-1 downto 0*DATA_WIDTH) <= std_logic_vector(to_signed(10, DATA_WIDTH));
        samples((1+1)*DATA_WIDTH-1 downto 1*DATA_WIDTH) <= std_logic_vector(to_signed(20, DATA_WIDTH));
        samples((2+1)*DATA_WIDTH-1 downto 2*DATA_WIDTH) <= std_logic_vector(to_signed(30, DATA_WIDTH));
        samples((3+1)*DATA_WIDTH-1 downto 3*DATA_WIDTH) <= std_logic_vector(to_signed(40, DATA_WIDTH));
        
        wait for CLK_PERIOD;
        
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1';
        wait for CLK_PERIOD / 2;
        
        result_int := signed(result);
        expected := -20;
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 3 FAILED!" severity error;
        report "  Test 3 PASSED" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 4: Verify cycles taken
        -- Should take NUM_TAPS cycles from start to done
        -----------------------------------------------------------------------
        report "Test 4: Verify computation takes " & integer'image(NUM_TAPS) & " cycles" severity note;
        
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        -- Count cycles until done
        for i in 1 to NUM_TAPS loop
            assert done = '0'
                report "Done asserted too early at cycle " & integer'image(i)
                severity error;
            wait for CLK_PERIOD;
        end loop;
        
        assert done = '1'
            report "Done not asserted after " & integer'image(NUM_TAPS) & " cycles"
            severity error;
        report "  Timing verified - PASSED" severity note;
        
        report "" severity note;
        report "=== All Tests Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
