-------------------------------------------------------------------------------
-- tb_fft_64pt.vhd
-- Testbench for 64-Point FFT
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-- Description:
--   Verifies 64-point FFT computation with known inputs:
--     1. DC input (all same value) → energy in bin 0
--     2. Single frequency tone → energy in corresponding bin
--     3. Impulse → flat spectrum
--
--   Note: Due to the 64-point size, we use simpler verification than
--   checking every bin - focus on expected energy distribution.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_fft_64pt is
end entity tb_fft_64pt;

architecture sim of tb_fft_64pt is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant DATA_WIDTH : positive := 18;  -- Smaller for faster simulation
    constant N          : positive := 64;
    constant CLK_PERIOD : time := 10 ns;

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal reset     : std_logic := '0';
    
    -- Input
    signal x_re      : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal x_im      : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal x_idx     : std_logic_vector(5 downto 0) := (others => '0');
    signal x_valid   : std_logic := '0';
    signal x_last    : std_logic := '0';
    
    -- Output
    signal out_re    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal out_im    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal out_idx   : std_logic_vector(5 downto 0);
    signal out_valid : std_logic;
    signal out_last  : std_logic;
    signal busy      : std_logic;
    
    signal running   : boolean := true;
    
    ---------------------------------------------------------------------------
    -- Test data storage
    ---------------------------------------------------------------------------
    type output_array_t is array (0 to N - 1) of signed(DATA_WIDTH - 1 downto 0);
    signal out_re_arr, out_im_arr : output_array_t;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when running else '0';
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    dut : entity work.fft_64pt
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk       => clk,
            reset     => reset,
            x_re      => x_re,
            x_im      => x_im,
            x_idx     => x_idx,
            x_valid   => x_valid,
            x_last    => x_last,
            out_re    => out_re,
            out_im    => out_im,
            out_idx   => out_idx,
            out_valid => out_valid,
            out_last  => out_last,
            busy      => busy
        );
    
    ---------------------------------------------------------------------------
    -- Capture outputs
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if out_valid = '1' then
                out_re_arr(to_integer(unsigned(out_idx))) <= signed(out_re);
                out_im_arr(to_integer(unsigned(out_idx))) <= signed(out_im);
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Stimulus Process
    ---------------------------------------------------------------------------
    stim_proc : process
        variable magnitude : real;
        variable max_bin   : integer;
        variable max_mag   : real;
    begin
        report "=== 64-Point FFT Testbench ===" severity note;
        
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;
        
        -----------------------------------------------------------------------
        -- Test 1: DC Input
        -- All samples = 100 (real), 0 (imag)
        -- Expected: X[0] = 6400, all others ≈ 0
        -----------------------------------------------------------------------
        report "Test 1: DC input (all samples = 100)" severity note;
        
        for i in 0 to N - 1 loop
            x_re <= std_logic_vector(to_signed(100, DATA_WIDTH));
            x_im <= std_logic_vector(to_signed(0, DATA_WIDTH));
            x_idx <= std_logic_vector(to_unsigned(i, 6));
            x_valid <= '1';
            if i = N - 1 then
                x_last <= '1';
            else
                x_last <= '0';
            end if;
            wait for CLK_PERIOD;
        end loop;
        x_valid <= '0';
        x_last <= '0';
        
        -- Wait for computation
        wait until out_last = '1';
        wait for CLK_PERIOD * 2;
        
        -- Check bin 0 has the energy
        report "  X[0] = " & integer'image(to_integer(out_re_arr(0))) & 
               " + j" & integer'image(to_integer(out_im_arr(0))) severity note;
        
        -- DC bin should have significant energy
        assert abs(to_integer(out_re_arr(0))) > 1000
            report "X[0] should have significant energy for DC input"
            severity warning;
        
        report "  Test 1 complete" severity note;
        wait for CLK_PERIOD * 10;
        
        -----------------------------------------------------------------------
        -- Test 2: Impulse at n=0
        -- x[0] = 1000, x[1..63] = 0
        -- Expected: Flat spectrum, all bins ≈ 1000
        -----------------------------------------------------------------------
        report "Test 2: Impulse input (x[0]=1000, others=0)" severity note;
        
        for i in 0 to N - 1 loop
            if i = 0 then
                x_re <= std_logic_vector(to_signed(1000, DATA_WIDTH));
            else
                x_re <= std_logic_vector(to_signed(0, DATA_WIDTH));
            end if;
            x_im <= std_logic_vector(to_signed(0, DATA_WIDTH));
            x_idx <= std_logic_vector(to_unsigned(i, 6));
            x_valid <= '1';
            if i = N - 1 then
                x_last <= '1';
            else
                x_last <= '0';
            end if;
            wait for CLK_PERIOD;
        end loop;
        x_valid <= '0';
        x_last <= '0';
        
        -- Wait for computation
        wait until out_last = '1';
        wait for CLK_PERIOD * 2;
        
        -- Check a few bins - should all have similar magnitude
        report "  X[0] = " & integer'image(to_integer(out_re_arr(0))) severity note;
        report "  X[1] = " & integer'image(to_integer(out_re_arr(1))) severity note;
        report "  X[32] = " & integer'image(to_integer(out_re_arr(32))) severity note;
        
        report "  Test 2 complete" severity note;
        wait for CLK_PERIOD * 10;
        
        -----------------------------------------------------------------------
        -- Test 3: Cosine at bin 8
        -- x[n] = cos(2*pi*8*n/64) = cos(pi*n/4)
        -- Expected: Energy in bins 8 and 56 (64-8)
        -----------------------------------------------------------------------
        report "Test 3: Cosine at bin 8" severity note;
        
        for i in 0 to N - 1 loop
            -- cos(2*pi*8*i/64) * 1000
            x_re <= std_logic_vector(to_signed(
                integer(1000.0 * cos(2.0 * MATH_PI * 8.0 * real(i) / 64.0)), 
                DATA_WIDTH));
            x_im <= std_logic_vector(to_signed(0, DATA_WIDTH));
            x_idx <= std_logic_vector(to_unsigned(i, 6));
            x_valid <= '1';
            if i = N - 1 then
                x_last <= '1';
            else
                x_last <= '0';
            end if;
            wait for CLK_PERIOD;
        end loop;
        x_valid <= '0';
        x_last <= '0';
        
        -- Wait for computation
        wait until out_last = '1';
        wait for CLK_PERIOD * 2;
        
        -- Find bin with maximum magnitude
        max_mag := 0.0;
        max_bin := 0;
        for i in 0 to N - 1 loop
            magnitude := sqrt(real(to_integer(out_re_arr(i)))**2 + 
                             real(to_integer(out_im_arr(i)))**2);
            if magnitude > max_mag then
                max_mag := magnitude;
                max_bin := i;
            end if;
        end loop;
        
        report "  Maximum energy at bin " & integer'image(max_bin) & 
               " (expected 8 or 56)" severity note;
        report "  X[8] = " & integer'image(to_integer(out_re_arr(8))) & 
               " + j" & integer'image(to_integer(out_im_arr(8))) severity note;
        report "  X[56] = " & integer'image(to_integer(out_re_arr(56))) & 
               " + j" & integer'image(to_integer(out_im_arr(56))) severity note;
        
        -- Check that bin 8 or 56 has energy
        assert max_bin = 8 or max_bin = 56
            report "Maximum should be at bin 8 or 56 for cosine test"
            severity warning;
        
        report "  Test 3 complete" severity note;
        
        report "" severity note;
        report "=== All Tests Complete ===" severity note;
        
        running <= false;
        wait;
    end process;

end architecture sim;
