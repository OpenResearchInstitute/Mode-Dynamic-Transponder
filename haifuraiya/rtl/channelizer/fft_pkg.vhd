-- =========================================================================
-- fft_pkg: small helper package for the parameterized FFT.
--
-- Holds the `clog2` function so it is visible in the entity's port clause
-- (port widths for x_idx / out_idx are derived from the N generic).
--
-- License: CERN-OHL-S-2.0
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package fft_pkg is

    -- Integer ceiling of log2.  clog2(1)=0, clog2(2)=1, clog2(64)=6, etc.
    function clog2(x : positive) return natural;

    -- Bit-reverse the LSB `width` bits of x.  width >= 1.
    function bit_reverse(x : natural; width : positive) return natural;

end package;

package body fft_pkg is

    function clog2(x : positive) return natural is
        variable r : natural := 0;
        variable t : natural := x - 1;
    begin
        while t > 0 loop
            r := r + 1;
            t := t / 2;
        end loop;
        return r;
    end function;

    function bit_reverse(x : natural; width : positive) return natural is
        variable r : natural := 0;
        variable t : natural := x;
    begin
        for i in 0 to width - 1 loop
            if (t mod 2) = 1 then
                r := r + (2 ** (width - 1 - i));
            end if;
            t := t / 2;
        end loop;
        return r;
    end function;

end package body;
