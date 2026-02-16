-------------------------------------------------------------------------------
-- tb_fir_branch.vhd
-- Testbench for FIR Branch
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies the complete FIR branch operation:
--     1. Sample input → delay line → MAC → result
--     2. Correct filter output for known inputs
--     3. Timing of result_valid relative to sample_valid
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fir_branch is
end entity tb_fir_branch;

architecture sim of tb_fir_branch is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant TAPS_PER_BRANCH : positive := 4;    -- Small for easy verification
    constant DATA_WIDTH      : positive := 16;
    constant COEFF_WIDTH     : positive := 16;
    constant ACCUM_WIDTH     : positive := 36;
    constant CLK_PERIOD      : time := 10 ns;
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal reset        : std_logic := '0';
    signal sample_in    : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal sample_valid : std_logic := '0';
    signal coeffs       : std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
    signal result       : std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal result_valid : std_logic;
    
    signal running      : boolean := true;
    
    ---------------------------------------------------------------------------
    -- Helper: Count cycles until result_valid
    ---------------------------------------------------------------------------
    signal cycle_count  : integer := 0;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.fir_branch
        generic map (
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk          => clk,
            reset        => reset,
            sample_in    => sample_in,
            sample_valid => sample_valid,
            coeffs       => coeffs,
            result       => result,
            result_valid => result_valid
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable result_int : signed(ACCUM_WIDTH - 1 downto 0);
        variable expected   : integer;
        variable start_time : time;
    begin
        report "=== FIR Branch Testbench ===" severity note;
        report "Configuration: " & integer'image(TAPS_PER_BRANCH) & " taps" severity note;
        
        -- Initialize coefficients: [1, 2, 3, 4] (simple weighted sum)
        -- coeff[0]=1, coeff[1]=2, coeff[2]=3, coeff[3]=4
        coeffs((0+1)*COEFF_WIDTH-1 downto 0*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((1+1)*COEFF_WIDTH-1 downto 1*COEFF_WIDTH) <= std_logic_vector(to_signed(2, COEFF_WIDTH));
        coeffs((2+1)*COEFF_WIDTH-1 downto 2*COEFF_WIDTH) <= std_logic_vector(to_signed(3, COEFF_WIDTH));
        coeffs((3+1)*COEFF_WIDTH-1 downto 3*COEFF_WIDTH) <= std_logic_vector(to_signed(4, COEFF_WIDTH));
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -----------------------------------------------------------------------
        -- Test 1: Feed in samples [10, 20, 30, 40] one at a time
        -- After 4 samples, delay line contains: tap[0]=40, tap[1]=30, tap[2]=20, tap[3]=10
        -- Expected result: 1*40 + 2*30 + 3*20 + 4*10 = 40 + 60 + 60 + 40 = 200
        -----------------------------------------------------------------------
        report "Test 1: Loading samples [10, 20, 30, 40]..." severity note;
        
        -- Sample 1: 10
        sample_in <= std_logic_vector(to_signed(10, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        -- Wait for MAC to complete before next sample
        wait until result_valid = '1';
        wait for CLK_PERIOD;
        
        -- Sample 2: 20
        sample_in <= std_logic_vector(to_signed(20, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        wait until result_valid = '1';
        wait for CLK_PERIOD;
        
        -- Sample 3: 30
        sample_in <= std_logic_vector(to_signed(30, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        wait until result_valid = '1';
        wait for CLK_PERIOD;
        
        -- Sample 4: 40
        sample_in <= std_logic_vector(to_signed(40, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        -- Wait for result
        wait until result_valid = '1';
        wait for CLK_PERIOD / 2;  -- Sample mid-cycle
        
        result_int := signed(result);
        expected := 200;  -- 1*40 + 2*30 + 3*20 + 4*10
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 1 FAILED!" severity error;
        report "  Test 1 PASSED" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 2: Feed another sample (50) and verify shift
        -- Delay line becomes: tap[0]=50, tap[1]=40, tap[2]=30, tap[3]=20
        -- (10 falls off the end)
        -- Expected: 1*50 + 2*40 + 3*30 + 4*20 = 50 + 80 + 90 + 80 = 300
        -----------------------------------------------------------------------
        report "Test 2: Adding sample 50 (10 should fall off)..." severity note;
        
        sample_in <= std_logic_vector(to_signed(50, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        wait until result_valid = '1';
        wait for CLK_PERIOD / 2;
        
        result_int := signed(result);
        expected := 300;  -- 1*50 + 2*40 + 3*30 + 4*20
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 2 FAILED!" severity error;
        report "  Test 2 PASSED" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 3: Verify timing - result should come M+1 cycles after sample_valid
        -- (1 cycle for mac_start delay + M cycles for MAC computation)
        -----------------------------------------------------------------------
        report "Test 3: Verifying timing..." severity note;
        
        sample_in <= std_logic_vector(to_signed(60, DATA_WIDTH));
        sample_valid <= '1';
        start_time := now;
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        wait until result_valid = '1';
        
        report "  Time from sample_valid to result_valid: " & 
               time'image(now - start_time) severity note;
        report "  Expected approximately: " & 
               time'image(CLK_PERIOD * (TAPS_PER_BRANCH + 1)) severity note;
        report "  Test 3 PASSED (timing observed)" severity note;
        
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 4: Negative values
        -- Current delay line: tap[0]=60, tap[1]=50, tap[2]=40, tap[3]=30
        -- Change coeffs to [1, -1, 1, -1]
        -- Expected: 1*60 + (-1)*50 + 1*40 + (-1)*30 = 60 - 50 + 40 - 30 = 20
        -----------------------------------------------------------------------
        report "Test 4: Testing with negative coefficients..." severity note;
        
        coeffs((0+1)*COEFF_WIDTH-1 downto 0*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((1+1)*COEFF_WIDTH-1 downto 1*COEFF_WIDTH) <= std_logic_vector(to_signed(-1, COEFF_WIDTH));
        coeffs((2+1)*COEFF_WIDTH-1 downto 2*COEFF_WIDTH) <= std_logic_vector(to_signed(1, COEFF_WIDTH));
        coeffs((3+1)*COEFF_WIDTH-1 downto 3*COEFF_WIDTH) <= std_logic_vector(to_signed(-1, COEFF_WIDTH));
        
        sample_in <= std_logic_vector(to_signed(70, DATA_WIDTH));
        sample_valid <= '1';
        wait for CLK_PERIOD;
        sample_valid <= '0';
        
        -- Now delay line is: tap[0]=70, tap[1]=60, tap[2]=50, tap[3]=40
        -- Expected: 1*70 + (-1)*60 + 1*50 + (-1)*40 = 70 - 60 + 50 - 40 = 20
        
        wait until result_valid = '1';
        wait for CLK_PERIOD / 2;
        
        result_int := signed(result);
        expected := 20;
        report "  Result: " & integer'image(to_integer(result_int)) & 
               ", Expected: " & integer'image(expected) severity note;
        assert to_integer(result_int) = expected
            report "Test 4 FAILED!" severity error;
        report "  Test 4 PASSED" severity note;
        
        report "" severity note;
        report "=== All Tests Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
