-------------------------------------------------------------------------------
-- tb_polyphase_filterbank.vhd
-- Testbench for Polyphase Filterbank
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies the polyphase filterbank operation:
--     1. Coefficient loading from ROM
--     2. Sample distribution (round-robin)
--     3. All branches compute and produce outputs
--     4. outputs_valid timing
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_polyphase_filterbank is
end entity tb_polyphase_filterbank;

architecture sim of tb_polyphase_filterbank is

    ---------------------------------------------------------------------------
    -- Constants (small values for easy verification)
    ---------------------------------------------------------------------------
    constant N_CHANNELS      : positive := 4;
    constant TAPS_PER_BRANCH : positive := 4;
    constant DATA_WIDTH      : positive := 16;
    constant COEFF_WIDTH     : positive := 16;
    constant ACCUM_WIDTH     : positive := 36;
    constant CLK_PERIOD      : time := 10 ns;
    
    constant TOTAL_COEFFS    : positive := N_CHANNELS * TAPS_PER_BRANCH;
    constant COEFF_ADDR_WIDTH: positive := 4;  -- ceil(log2(16))
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '0';
    signal sample_in      : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal sample_valid   : std_logic := '0';
    signal coeff_addr     : std_logic_vector(COEFF_ADDR_WIDTH - 1 downto 0);
    signal coeff_data     : std_logic_vector(COEFF_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_load     : std_logic;
    signal branch_outputs : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal outputs_valid  : std_logic;
    
    signal running        : boolean := true;
    
    ---------------------------------------------------------------------------
    -- Simulated Coefficient ROM
    ---------------------------------------------------------------------------
    type coeff_rom_t is array (0 to TOTAL_COEFFS - 1) of 
        std_logic_vector(COEFF_WIDTH - 1 downto 0);
    
    -- Simple coefficients: all 1s for easy verification
    -- Each branch will sum its 4 input samples
    signal coeff_rom : coeff_rom_t := (others => std_logic_vector(to_signed(1, COEFF_WIDTH)));
    
    ---------------------------------------------------------------------------
    -- Helper function to extract branch output
    ---------------------------------------------------------------------------
    function get_branch_output(
        outputs : std_logic_vector;
        branch  : natural;
        width   : positive
    ) return signed is
    begin
        return signed(outputs((branch + 1) * width - 1 downto branch * width));
    end function;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- Simulated Coefficient ROM (1-cycle latency)
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            coeff_data <= coeff_rom(to_integer(unsigned(coeff_addr)));
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.polyphase_filterbank
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
            sample_in      => sample_in,
            sample_valid   => sample_valid,
            coeff_addr     => coeff_addr,
            coeff_data     => coeff_data,
            coeff_load     => coeff_load,
            branch_outputs => branch_outputs,
            outputs_valid  => outputs_valid
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable output_val : signed(ACCUM_WIDTH - 1 downto 0);
    begin
        report "=== Polyphase Filterbank Testbench ===" severity note;
        report "Configuration: " & integer'image(N_CHANNELS) & " channels, " &
               integer'image(TAPS_PER_BRANCH) & " taps/branch" severity note;
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -----------------------------------------------------------------------
        -- Wait for coefficient loading to complete
        -----------------------------------------------------------------------
        report "Waiting for coefficient loading..." severity note;
        wait until coeff_load = '0';
        report "  Coefficients loaded" severity note;
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: Feed samples and check outputs
        -- With all coeffs = 1, each branch output = sum of its 4 delay line samples
        -----------------------------------------------------------------------
        report "Test 1: Feeding samples to fill delay lines..." severity note;
        
        -- Feed 16 samples (4 sets of 4, to fill all delay lines)
        -- Samples: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
        for i in 1 to 16 loop
            sample_in <= std_logic_vector(to_signed(i, DATA_WIDTH));
            sample_valid <= '1';
            wait for CLK_PERIOD;
            sample_valid <= '0';
            
            -- Wait a bit between samples (let MAC complete)
            wait for CLK_PERIOD * (TAPS_PER_BRANCH + 2);
        end loop;
        
        report "  Samples fed, waiting for outputs..." severity note;
        
        -- Wait for outputs_valid
        wait until outputs_valid = '1';
        wait for CLK_PERIOD / 2;  -- Sample mid-cycle
        
        report "  outputs_valid asserted" severity note;
        
        -- Check each branch output
        -- Branch 0 saw samples: 1, 5, 9, 13 → sum = 28
        -- Branch 1 saw samples: 2, 6, 10, 14 → sum = 32
        -- Branch 2 saw samples: 3, 7, 11, 15 → sum = 36
        -- Branch 3 saw samples: 4, 8, 12, 16 → sum = 40
        
        for branch in 0 to N_CHANNELS - 1 loop
            output_val := get_branch_output(branch_outputs, branch, ACCUM_WIDTH);
            report "  Branch " & integer'image(branch) & " output: " & 
                   integer'image(to_integer(output_val)) severity note;
        end loop;
        
        -- Verify expected values
        output_val := get_branch_output(branch_outputs, 0, ACCUM_WIDTH);
        assert to_integer(output_val) = 28
            report "Branch 0 expected 28, got " & integer'image(to_integer(output_val))
            severity error;
            
        output_val := get_branch_output(branch_outputs, 1, ACCUM_WIDTH);
        assert to_integer(output_val) = 32
            report "Branch 1 expected 32, got " & integer'image(to_integer(output_val))
            severity error;
            
        output_val := get_branch_output(branch_outputs, 2, ACCUM_WIDTH);
        assert to_integer(output_val) = 36
            report "Branch 2 expected 36, got " & integer'image(to_integer(output_val))
            severity error;
            
        output_val := get_branch_output(branch_outputs, 3, ACCUM_WIDTH);
        assert to_integer(output_val) = 40
            report "Branch 3 expected 40, got " & integer'image(to_integer(output_val))
            severity error;
        
        report "  Test 1 PASSED" severity note;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 2: Feed another round of samples and verify shift
        -----------------------------------------------------------------------
        report "Test 2: Feeding 4 more samples..." severity note;
        
        -- Feed samples 17, 18, 19, 20
        for i in 17 to 20 loop
            sample_in <= std_logic_vector(to_signed(i, DATA_WIDTH));
            sample_valid <= '1';
            wait for CLK_PERIOD;
            sample_valid <= '0';
            wait for CLK_PERIOD * (TAPS_PER_BRANCH + 2);
        end loop;
        
        -- Wait for outputs_valid
        wait until outputs_valid = '1';
        wait for CLK_PERIOD / 2;
        
        -- New delay line contents:
        -- Branch 0: 17, 13, 9, 5 → sum = 44
        -- Branch 1: 18, 14, 10, 6 → sum = 48
        -- Branch 2: 19, 15, 11, 7 → sum = 52
        -- Branch 3: 20, 16, 12, 8 → sum = 56
        
        for branch in 0 to N_CHANNELS - 1 loop
            output_val := get_branch_output(branch_outputs, branch, ACCUM_WIDTH);
            report "  Branch " & integer'image(branch) & " output: " & 
                   integer'image(to_integer(output_val)) severity note;
        end loop;
        
        output_val := get_branch_output(branch_outputs, 0, ACCUM_WIDTH);
        assert to_integer(output_val) = 44
            report "Branch 0 expected 44, got " & integer'image(to_integer(output_val))
            severity error;
        
        report "  Test 2 PASSED" severity note;
        
        report "" severity note;
        report "=== All Tests Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
