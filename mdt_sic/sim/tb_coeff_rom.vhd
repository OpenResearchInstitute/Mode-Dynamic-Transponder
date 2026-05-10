-------------------------------------------------------------------------------
-- tb_coeff_rom.vhd
-- Testbench for Coefficient ROM
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Simple testbench that reads all coefficients from the ROM and prints
--   them to the console. Verifies ROM initialization from hex file.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_coeff_rom is
end entity tb_coeff_rom;

architecture sim of tb_coeff_rom is

    ---------------------------------------------------------------------------
    -- Constants for MDT configuration
    ---------------------------------------------------------------------------
    constant N_CHANNELS      : positive := 4;
    constant TAPS_PER_BRANCH : positive := 16;
    constant COEFF_WIDTH     : positive := 16;
    constant ADDR_WIDTH      : positive := 6;   -- ceil(log2(64))
    constant COEFF_FILE      : string := "mdt_coeffs.hex";
    
    constant ROM_DEPTH       : positive := N_CHANNELS * TAPS_PER_BRANCH;
    constant CLK_PERIOD      : time := 10 ns;
    
    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk   : std_logic := '0';
    signal addr  : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal coeff : std_logic_vector(COEFF_WIDTH - 1 downto 0);
    
    signal running : boolean := true;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.coeff_rom
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ADDR_WIDTH      => ADDR_WIDTH,
            COEFF_FILE      => COEFF_FILE
        )
        port map (
            clk   => clk,
            addr  => addr,
            coeff => coeff
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable coeff_signed : signed(COEFF_WIDTH - 1 downto 0);
        variable coeff_real   : real;
    begin
        report "=== Coefficient ROM Testbench ===" severity note;
        report "Configuration: " & integer'image(N_CHANNELS) & " channels, " &
               integer'image(TAPS_PER_BRANCH) & " taps/branch" severity note;
        report "" severity note;
        
        -- Wait for reset
        wait for CLK_PERIOD * 2;
        
        -- Read all coefficients
        for i in 0 to ROM_DEPTH - 1 loop
            addr <= std_logic_vector(to_unsigned(i, ADDR_WIDTH));
            wait for CLK_PERIOD;  -- Wait for address to register
            wait for CLK_PERIOD;  -- Wait for data to appear (1 cycle latency)
            
            -- Convert to signed and real for display
            coeff_signed := signed(coeff);
            coeff_real := real(to_integer(coeff_signed)) / real(2**(COEFF_WIDTH - 1));
            
            -- Report every coefficient
            report "Addr " & integer'image(i) & 
                   ": 0x" & to_hstring(coeff) &
                   " = " & integer'image(to_integer(coeff_signed)) &
                   " (" & real'image(coeff_real) & ")"
                severity note;
        end loop;
        
        report "" severity note;
        report "=== Testbench Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
