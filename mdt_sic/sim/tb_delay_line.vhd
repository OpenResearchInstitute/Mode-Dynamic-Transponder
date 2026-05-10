-------------------------------------------------------------------------------
-- tb_delay_line.vhd
-- Testbench for Delay Line
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies delay line shift operation and tap outputs.
--   Loads sequential values and checks they appear at correct tap positions.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_delay_line is
end entity tb_delay_line;

architecture sim of tb_delay_line is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant DELAY_DEPTH : positive := 4;   -- Small for easy verification
    constant DATA_WIDTH  : positive := 16;
    constant CLK_PERIOD  : time := 10 ns;
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal reset    : std_logic := '0';
    signal shift_en : std_logic := '0';
    signal data_in  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal taps     : std_logic_vector(DELAY_DEPTH * DATA_WIDTH - 1 downto 0);
    
    signal running  : boolean := true;
    
    ---------------------------------------------------------------------------
    -- Helper function to extract a tap from the packed output
    ---------------------------------------------------------------------------
    function get_tap(
        taps_vec : std_logic_vector;
        tap_idx  : natural;
        width    : positive
    ) return std_logic_vector is
    begin
        return taps_vec((tap_idx + 1) * width - 1 downto tap_idx * width);
    end function;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.delay_line
        generic map (
            DELAY_DEPTH => DELAY_DEPTH,
            DATA_WIDTH  => DATA_WIDTH
        )
        port map (
            clk      => clk,
            reset    => reset,
            shift_en => shift_en,
            data_in  => data_in,
            taps     => taps
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable tap_val : std_logic_vector(DATA_WIDTH - 1 downto 0);
    begin
        report "=== Delay Line Testbench ===" severity note;
        report "Configuration: " & integer'image(DELAY_DEPTH) & " taps, " &
               integer'image(DATA_WIDTH) & "-bit" severity note;
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -- Verify all taps are zero after reset
        report "After reset - checking all taps are zero..." severity note;
        for i in 0 to DELAY_DEPTH - 1 loop
            tap_val := get_tap(taps, i, DATA_WIDTH);
            assert tap_val = x"0000"
                report "Tap " & integer'image(i) & " not zero after reset!"
                severity error;
        end loop;
        report "  All taps zero - PASS" severity note;
        
        -- Shift in values 1, 2, 3, 4
        report "Shifting in values 1, 2, 3, 4..." severity note;
        for val in 1 to 4 loop
            data_in <= std_logic_vector(to_unsigned(val, DATA_WIDTH));
            shift_en <= '1';
            wait for CLK_PERIOD;
            shift_en <= '0';
            wait for CLK_PERIOD;
            
            -- Report current state
            report "  After shifting in " & integer'image(val) & ":" severity note;
            for i in 0 to DELAY_DEPTH - 1 loop
                tap_val := get_tap(taps, i, DATA_WIDTH);
                report "    tap[" & integer'image(i) & "] = " & 
                       integer'image(to_integer(unsigned(tap_val))) severity note;
            end loop;
        end loop;
        
        -- Verify final state: tap[0]=4, tap[1]=3, tap[2]=2, tap[3]=1
        report "Verifying final tap values..." severity note;
        for i in 0 to DELAY_DEPTH - 1 loop
            tap_val := get_tap(taps, i, DATA_WIDTH);
            assert to_integer(unsigned(tap_val)) = (DELAY_DEPTH - i)
                report "Tap " & integer'image(i) & " expected " & 
                       integer'image(DELAY_DEPTH - i) & " but got " &
                       integer'image(to_integer(unsigned(tap_val)))
                severity error;
        end loop;
        report "  Final values correct - PASS" severity note;
        
        -- Test hold behavior (shift_en = 0)
        report "Testing hold behavior (shift_en=0)..." severity note;
        data_in <= x"FFFF";  -- This should NOT be loaded
        shift_en <= '0';
        wait for CLK_PERIOD * 3;
        
        tap_val := get_tap(taps, 0, DATA_WIDTH);
        assert to_integer(unsigned(tap_val)) = 4
            report "Tap 0 changed during hold!"
            severity error;
        report "  Hold behavior correct - PASS" severity note;
        
        -- Shift one more value to confirm operation continues
        report "Shifting in value 5..." severity note;
        data_in <= std_logic_vector(to_unsigned(5, DATA_WIDTH));
        shift_en <= '1';
        wait for CLK_PERIOD;
        shift_en <= '0';
        wait for CLK_PERIOD;
        
        -- Now should be: tap[0]=5, tap[1]=4, tap[2]=3, tap[3]=2
        -- (value 1 has fallen off the end)
        tap_val := get_tap(taps, 0, DATA_WIDTH);
        assert to_integer(unsigned(tap_val)) = 5
            report "Tap 0 expected 5 after fifth shift"
            severity error;
        tap_val := get_tap(taps, DELAY_DEPTH - 1, DATA_WIDTH);
        assert to_integer(unsigned(tap_val)) = 2
            report "Oldest tap expected 2 (value 1 should have fallen off)"
            severity error;
        report "  Shift and discard correct - PASS" severity note;
        
        report "" severity note;
        report "=== Testbench Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
