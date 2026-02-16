-------------------------------------------------------------------------------
-- channelizer_pkg.vhd
-- Package for Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
-- 
-- Description:
--   Shared types, constants, and utility functions for the polyphase 
--   channelizer design. Defines configuration records for MDT and Haifuraiya.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package channelizer_pkg is

    ---------------------------------------------------------------------------
    -- Utility Functions
    ---------------------------------------------------------------------------
    
    -- Ceiling of log base 2
    -- Returns minimum number of bits needed to represent values 0 to n-1
    function clog2(n : positive) return positive;
    
    ---------------------------------------------------------------------------
    -- Configuration Record
    ---------------------------------------------------------------------------
    type channelizer_config_t is record
        n_channels      : positive;     -- Number of channels (N)
        taps_per_branch : positive;     -- Taps per polyphase branch (M)
        data_width      : positive;     -- Input/output data width
        coeff_width     : positive;     -- Coefficient width
        accum_width     : positive;     -- Accumulator width
    end record channelizer_config_t;
    
    ---------------------------------------------------------------------------
    -- Pre-defined Configurations
    ---------------------------------------------------------------------------
    
    -- MDT Configuration
    -- 4 channels, 64 total taps, for iCE40 UltraPlus
    -- Usage: Linear transponder spectrum monitoring (30 kHz passband)
    constant MDT_CONFIG : channelizer_config_t := (
        n_channels      => 4,
        taps_per_branch => 16,      -- 64 total taps
        data_width      => 16,
        coeff_width     => 16,
        accum_width     => 36       -- 16 + 16 + ceil(log2(16)) = 36
    );
    
    -- Haifuraiya Configuration  
    -- 64 channels, 1536 total taps, for Xilinx ZCU102
    -- Usage: Opulent Voice FDMA (10 MHz bandwidth)
    constant HAIFURAIYA_CONFIG : channelizer_config_t := (
        n_channels      => 64,
        taps_per_branch => 24,      -- 1536 total taps
        data_width      => 16,
        coeff_width     => 16,
        accum_width     => 40       -- 16 + 16 + ceil(log2(24)) + margin = 40
    );
    
    ---------------------------------------------------------------------------
    -- Derived Constants Functions
    ---------------------------------------------------------------------------
    
    -- Calculate total number of taps
    function total_taps(cfg : channelizer_config_t) return positive;
    
    -- Calculate coefficient ROM address width
    function coeff_addr_width(cfg : channelizer_config_t) return positive;
    
    -- Calculate branch index width  
    function branch_addr_width(cfg : channelizer_config_t) return positive;
    
    -- Calculate tap index width
    function tap_addr_width(cfg : channelizer_config_t) return positive;

end package channelizer_pkg;

package body channelizer_pkg is

    ---------------------------------------------------------------------------
    -- Function Implementations
    ---------------------------------------------------------------------------
    
    function clog2(n : positive) return positive is
        variable result : positive := 1;
        variable value  : positive := 2;
    begin
        while value < n loop
            result := result + 1;
            value := value * 2;
        end loop;
        return result;
    end function clog2;
    
    function total_taps(cfg : channelizer_config_t) return positive is
    begin
        return cfg.n_channels * cfg.taps_per_branch;
    end function total_taps;
    
    function coeff_addr_width(cfg : channelizer_config_t) return positive is
    begin
        return clog2(cfg.n_channels * cfg.taps_per_branch);
    end function coeff_addr_width;
    
    function branch_addr_width(cfg : channelizer_config_t) return positive is
    begin
        return clog2(cfg.n_channels);
    end function branch_addr_width;
    
    function tap_addr_width(cfg : channelizer_config_t) return positive is
    begin
        return clog2(cfg.taps_per_branch);
    end function tap_addr_width;

end package body channelizer_pkg;
