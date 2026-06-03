-------------------------------------------------------------------------------
-- r2sdf_stage.vhd
-- One radix-2 single-path delay-feedback (R2SDF) DIF stage.
-------------------------------------------------------------------------------
-- Open Research Institute -- Haifuraiya / Mode-Dynamic-Transponder
-- Pipelined-FFT back end for the polyphase channelizer.
--
-- One stage of the streaming FFT. Feedback depth D = N / 2^(stage_index+1).
-- One valid sample in -> one valid sample out, registered (1-cycle latency).
-- Arithmetic is bit-identical to the iterative core (fft_n_pt.vhd) and to the
-- Python golden model (model/r2sdf_fft_model.py): 40-bit wrap on sum/diff,
-- Q1.14 twiddle, truncating un-scale via bit slice [.. : TW_FRAC].
--
--   phase A (local count <  D): load input into FB, pass FB output forward
--   phase B (local count >= D): forward = z + din   (DIF sum, untwiddled)
--                               FB_in   = (z - din) * W   (twiddled difference)
--   twiddle exponent = (count - D) * STRIDE,  STRIDE = N/(2D) = 2^stage_index
--
-- Tools: Vivado 2022.2 / GHDL, VHDL-93.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity r2sdf_stage is
    generic (
        N             : positive := 64;   -- full FFT size (for ROM + stride)
        D             : positive := 32;   -- feedback depth of THIS stage
        DATA_WIDTH    : positive := 40;
        TWIDDLE_WIDTH : positive := 16
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;        -- synchronous, active high
        in_valid  : in  std_logic;
        in_re     : in  signed(DATA_WIDTH - 1 downto 0);
        in_im     : in  signed(DATA_WIDTH - 1 downto 0);
        out_valid : out std_logic;
        out_re    : out signed(DATA_WIDTH - 1 downto 0);
        out_im    : out signed(DATA_WIDTH - 1 downto 0)
    );
end entity r2sdf_stage;

architecture rtl of r2sdf_stage is

    constant TW_FRAC  : integer := TWIDDLE_WIDTH - 2;          -- Q1.14 -> 14
    constant TW_SCALE : real    := real(2 ** TW_FRAC - 1);     -- 16383.0
    constant STRIDE   : integer := N / (2 * D);                -- 2^stage_index

    -- Twiddle ROM: W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N), Q1.14.
    -- round() ties-away matches the golden model's verified ROM for N=64.
    type tw_t is record
        re : signed(TWIDDLE_WIDTH - 1 downto 0);
        im : signed(TWIDDLE_WIDTH - 1 downto 0);
    end record;
    type tw_rom_t is array (0 to N/2 - 1) of tw_t;

    function init_rom return tw_rom_t is
        variable rom : tw_rom_t;
        variable a   : real;
    begin
        for k in 0 to N/2 - 1 loop
            a := 2.0 * MATH_PI * real(k) / real(N);
            rom(k).re := to_signed(integer(round(cos(a) * TW_SCALE)), TWIDDLE_WIDTH);
            rom(k).im := to_signed(integer(round(-sin(a) * TW_SCALE)), TWIDDLE_WIDTH);
        end loop;
        return rom;
    end function;
    constant TW_ROM : tw_rom_t := init_rom;

    -- Feedback shift register (depth D), real and imag.
    type fb_arr_t is array (0 to D - 1) of signed(DATA_WIDTH - 1 downto 0);
    signal fb_re : fb_arr_t := (others => (others => '0'));
    signal fb_im : fb_arr_t := (others => (others => '0'));

    signal cnt : integer range 0 to 2*D - 1 := 0;

begin

    p_stage : process(clk)
        variable zr, zi   : signed(DATA_WIDTH - 1 downto 0);
        variable dr, di   : signed(DATA_WIDTH - 1 downto 0);
        variable diff_re  : signed(DATA_WIDTH - 1 downto 0);
        variable diff_im  : signed(DATA_WIDTH - 1 downto 0);
        variable pr, pi   : signed(DATA_WIDTH + TWIDDLE_WIDTH - 1 downto 0);
        variable tw       : tw_t;
        variable fbin_re  : signed(DATA_WIDTH - 1 downto 0);
        variable fbin_im  : signed(DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cnt       <= 0;
                out_valid <= '0';
                out_re    <= (others => '0');
                out_im    <= (others => '0');
            else
                out_valid <= in_valid;
                if in_valid = '1' then
                    zr := fb_re(0);          -- value delayed by D
                    zi := fb_im(0);
                    dr := in_re;
                    di := in_im;

                    if cnt < D then
                        -- phase A: pass z forward, load din into FB
                        out_re   <= zr;
                        out_im   <= zi;
                        fbin_re  := dr;
                        fbin_im  := di;
                    else
                        -- phase B: butterfly. sum = z + din (40-bit wrap).
                        out_re <= zr + dr;
                        out_im <= zi + di;
                        diff_re := zr - dr;
                        diff_im := zi - di;
                        tw      := TW_ROM((cnt - D) * STRIDE);
                        -- complex multiply, then truncating un-scale (slice
                        -- [DATA_WIDTH+TW_FRAC-1 : TW_FRAC]) == golden model >>14
                        pr := diff_re * tw.re - diff_im * tw.im;
                        pi := diff_re * tw.im + diff_im * tw.re;
                        fbin_re := pr(DATA_WIDTH + TW_FRAC - 1 downto TW_FRAC);
                        fbin_im := pi(DATA_WIDTH + TW_FRAC - 1 downto TW_FRAC);
                    end if;

                    -- shift the feedback register: drop head, append new tail
                    for i in 0 to D - 2 loop
                        fb_re(i) <= fb_re(i + 1);
                        fb_im(i) <= fb_im(i + 1);
                    end loop;
                    fb_re(D - 1) <= fbin_re;
                    fb_im(D - 1) <= fbin_im;

                    if cnt = 2*D - 1 then
                        cnt <= 0;
                    else
                        cnt <= cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_stage;

end architecture rtl;
