-------------------------------------------------------------------------------
-- r2sdf_reorder.vhd
-- Bit-reversal reorder buffer for the R2SDF FFT output.
-------------------------------------------------------------------------------
-- Open Research Institute -- Haifuraiya / Mode-Dynamic-Transponder
--
-- The R2SDF cascade emits one frame of N bins in bit-reversed order. This
-- ping-pong buffer restores natural order so out_idx = 0..N-1 is the natural
-- frequency bin, matching the convention the channelizer expects.
--
-- Verified mapping (model/r2sdf_fft_model.py): natural[bit_reverse(k)] = in(k).
-- So sample k is written at address bit_reverse(k); reading 0..N-1 is natural.
-- One frame (N samples) of latency: frame f is read out while frame f+1 fills
-- the other buffer. The first frame after reset is pipeline-fill garbage.
--
-- Tools: Vivado 2022.2 / GHDL, VHDL-93.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity r2sdf_reorder is
    generic (
        N           : positive := 64;
        DATA_WIDTH  : positive := 40;
        -- wcnt start phase = (N - (cascade_latency mod N)) mod N. The R2SDF DIF
        -- cascade latency is sum of feedback depths = N-1, so this is 1 for the
        -- production N. Aligns wcnt=0 to the real output frame boundary instead
        -- of the first pipeline-fill sample. Verified by tb_r2sdf_fft.
        FRAME_PHASE : natural := 0
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        in_valid  : in  std_logic;
        in_re     : in  signed(DATA_WIDTH - 1 downto 0);
        in_im     : in  signed(DATA_WIDTH - 1 downto 0);
        out_valid : out std_logic;
        out_re    : out signed(DATA_WIDTH - 1 downto 0);
        out_im    : out signed(DATA_WIDTH - 1 downto 0);
        out_idx   : out unsigned(integer(ceil(log2(real(N)))) - 1 downto 0)
    );
end entity r2sdf_reorder;

architecture rtl of r2sdf_reorder is

    function clog2(x : positive) return natural is
        variable r : natural := 0;
        variable v : positive := 1;
    begin
        while v < x loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function;

    constant LOG2N : natural := clog2(N);

    function bit_rev(v : unsigned) return unsigned is
        variable r : unsigned(v'range);
    begin
        -- reverse bit order: new bit i = old bit at the mirrored position.
        -- written over v'range (not 0 to v'length-1) for VHDL-93 strictness.
        for i in v'range loop
            r(i) := v(v'high + v'low - i);
        end loop;
        return r;
    end function;

    type buf_t is array (0 to N - 1) of signed(DATA_WIDTH - 1 downto 0);
    signal buf0_re, buf0_im : buf_t := (others => (others => '0'));
    signal buf1_re, buf1_im : buf_t := (others => (others => '0'));

    signal wcnt : unsigned(LOG2N - 1 downto 0) := to_unsigned(FRAME_PHASE, LOG2N);
    signal sel  : std_logic := '0';   -- which buffer is being written

begin

    p_reorder : process(clk)
        variable waddr : integer range 0 to N - 1;
        variable raddr : integer range 0 to N - 1;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wcnt      <= to_unsigned(FRAME_PHASE, LOG2N);
                sel       <= '0';
                out_valid <= '0';
            else
                out_valid <= in_valid;
                if in_valid = '1' then
                    waddr := to_integer(bit_rev(wcnt));   -- write bit-reversed
                    raddr := to_integer(wcnt);            -- read natural
                    out_idx <= wcnt;

                    if sel = '0' then
                        buf0_re(waddr) <= in_re;
                        buf0_im(waddr) <= in_im;
                        out_re <= buf1_re(raddr);
                        out_im <= buf1_im(raddr);
                    else
                        buf1_re(waddr) <= in_re;
                        buf1_im(waddr) <= in_im;
                        out_re <= buf0_re(raddr);
                        out_im <= buf0_im(raddr);
                    end if;

                    if wcnt = N - 1 then
                        wcnt <= (others => '0');
                        sel  <= not sel;
                    else
                        wcnt <= wcnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_reorder;

end architecture rtl;
