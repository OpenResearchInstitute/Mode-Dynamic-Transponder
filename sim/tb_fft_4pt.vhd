-------------------------------------------------------------------------------
-- tb_fft_4pt.vhd
-- Testbench for 4-Point FFT
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies 4-point FFT computation with known inputs:
--     1. DC input (all same value) → all energy in bin 0
--     2. Nyquist input (alternating) → all energy in bin 2
--     3. Complex exponential → energy in one bin
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fft_4pt is
end entity tb_fft_4pt;

architecture sim of tb_fft_4pt is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant DATA_WIDTH : positive := 16;
    constant CLK_PERIOD : time := 10 ns;
    
    constant SAMPLE_WIDTH : positive := 2 * DATA_WIDTH;  -- Complex
    constant TOTAL_WIDTH  : positive := 4 * SAMPLE_WIDTH;

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal reset     : std_logic := '0';
    signal x_in      : std_logic_vector(TOTAL_WIDTH - 1 downto 0) := (others => '0');
    signal valid_in  : std_logic := '0';
    signal X_out     : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    signal valid_out : std_logic;
    
    signal running   : boolean := true;

    ---------------------------------------------------------------------------
    -- Helper: Pack a complex sample
    ---------------------------------------------------------------------------
    function pack_complex(re, im : integer; width : positive) 
        return std_logic_vector is
        variable result : std_logic_vector(2 * width - 1 downto 0);
    begin
        result(width - 1 downto 0) := std_logic_vector(to_signed(re, width));
        result(2*width - 1 downto width) := std_logic_vector(to_signed(im, width));
        return result;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper: Unpack and display a complex output
    ---------------------------------------------------------------------------
    procedure report_output(
        X : std_logic_vector;
        idx : natural;
        width : positive
    ) is
        variable base : natural;
        variable re, im : signed(width - 1 downto 0);
    begin
        base := idx * 2 * width;
        re := signed(X(base + width - 1 downto base));
        im := signed(X(base + 2*width - 1 downto base + width));
        report "  X[" & integer'image(idx) & "] = " & 
               integer'image(to_integer(re)) & " + j" &
               integer'image(to_integer(im)) severity note;
    end procedure;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.fft_4pt
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_in      => x_in,
            valid_in  => valid_in,
            X_out     => X_out,
            valid_out => valid_out
        );
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
    begin
        report "=== 4-Point FFT Testbench ===" severity note;
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -----------------------------------------------------------------------
        -- Test 1: DC Input
        -- x = [1, 1, 1, 1] (all real, same value)
        -- Expected: X[0] = 4, X[1] = 0, X[2] = 0, X[3] = 0
        -----------------------------------------------------------------------
        report "Test 1: DC input [1, 1, 1, 1]" severity note;
        
        x_in((0+1)*SAMPLE_WIDTH-1 downto 0*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((1+1)*SAMPLE_WIDTH-1 downto 1*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((2+1)*SAMPLE_WIDTH-1 downto 2*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((3+1)*SAMPLE_WIDTH-1 downto 3*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        
        wait until valid_out = '1';
        wait for CLK_PERIOD / 2;
        
        for i in 0 to 3 loop
            report_output(X_out, i, DATA_WIDTH);
        end loop;
        
        -- X[0] should be 4 (DC component)
        assert signed(X_out(DATA_WIDTH - 1 downto 0)) = 4
            report "X[0] real expected 4" severity error;
        
        report "  Test 1 PASSED" severity note;
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 2: Nyquist Input  
        -- x = [1, -1, 1, -1] (alternating)
        -- Expected: X[0] = 0, X[1] = 0, X[2] = 4, X[3] = 0
        -----------------------------------------------------------------------
        report "Test 2: Nyquist input [1, -1, 1, -1]" severity note;
        
        x_in((0+1)*SAMPLE_WIDTH-1 downto 0*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((1+1)*SAMPLE_WIDTH-1 downto 1*SAMPLE_WIDTH) <= pack_complex(-1, 0, DATA_WIDTH);
        x_in((2+1)*SAMPLE_WIDTH-1 downto 2*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((3+1)*SAMPLE_WIDTH-1 downto 3*SAMPLE_WIDTH) <= pack_complex(-1, 0, DATA_WIDTH);
        
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        
        wait until valid_out = '1';
        wait for CLK_PERIOD / 2;
        
        for i in 0 to 3 loop
            report_output(X_out, i, DATA_WIDTH);
        end loop;
        
        -- X[2] should be 4 (Nyquist component)
        assert signed(X_out(2*SAMPLE_WIDTH + DATA_WIDTH - 1 downto 2*SAMPLE_WIDTH)) = 4
            report "X[2] real expected 4" severity error;
        
        report "  Test 2 PASSED" severity note;
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 3: Positive frequency complex exponential
        -- x[n] = e^(j*2*pi*n/4) = [1, j, -1, -j]
        -- x = [(1,0), (0,1), (-1,0), (0,-1)]
        -- Expected: X[1] = 4, others = 0
        -----------------------------------------------------------------------
        report "Test 3: Complex exponential [1, j, -1, -j]" severity note;
        
        x_in((0+1)*SAMPLE_WIDTH-1 downto 0*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((1+1)*SAMPLE_WIDTH-1 downto 1*SAMPLE_WIDTH) <= pack_complex(0, 1, DATA_WIDTH);
        x_in((2+1)*SAMPLE_WIDTH-1 downto 2*SAMPLE_WIDTH) <= pack_complex(-1, 0, DATA_WIDTH);
        x_in((3+1)*SAMPLE_WIDTH-1 downto 3*SAMPLE_WIDTH) <= pack_complex(0, -1, DATA_WIDTH);
        
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        
        wait until valid_out = '1';
        wait for CLK_PERIOD / 2;
        
        for i in 0 to 3 loop
            report_output(X_out, i, DATA_WIDTH);
        end loop;
        
        -- X[1] should be 4 (bin 1 = positive frequency)
        assert signed(X_out(1*SAMPLE_WIDTH + DATA_WIDTH - 1 downto 1*SAMPLE_WIDTH)) = 4
            report "X[1] real expected 4" severity error;
        
        report "  Test 3 PASSED" severity note;
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 4: Negative frequency complex exponential
        -- x[n] = e^(-j*2*pi*n/4) = [1, -j, -1, j]
        -- x = [(1,0), (0,-1), (-1,0), (0,1)]
        -- Expected: X[3] = 4, others = 0
        -----------------------------------------------------------------------
        report "Test 4: Complex exponential [1, -j, -1, j]" severity note;
        
        x_in((0+1)*SAMPLE_WIDTH-1 downto 0*SAMPLE_WIDTH) <= pack_complex(1, 0, DATA_WIDTH);
        x_in((1+1)*SAMPLE_WIDTH-1 downto 1*SAMPLE_WIDTH) <= pack_complex(0, -1, DATA_WIDTH);
        x_in((2+1)*SAMPLE_WIDTH-1 downto 2*SAMPLE_WIDTH) <= pack_complex(-1, 0, DATA_WIDTH);
        x_in((3+1)*SAMPLE_WIDTH-1 downto 3*SAMPLE_WIDTH) <= pack_complex(0, 1, DATA_WIDTH);
        
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        
        wait until valid_out = '1';
        wait for CLK_PERIOD / 2;
        
        for i in 0 to 3 loop
            report_output(X_out, i, DATA_WIDTH);
        end loop;
        
        -- X[3] should be 4 (bin 3 = negative frequency)
        assert signed(X_out(3*SAMPLE_WIDTH + DATA_WIDTH - 1 downto 3*SAMPLE_WIDTH)) = 4
            report "X[3] real expected 4" severity error;
        
        report "  Test 4 PASSED" severity note;
        
        report "" severity note;
        report "=== All Tests Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
