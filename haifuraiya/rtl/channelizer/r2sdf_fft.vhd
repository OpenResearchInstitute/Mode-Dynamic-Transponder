-------------------------------------------------------------------------------
-- r2sdf_fft.vhd
-- Pipelined radix-2 single-path delay-feedback (R2SDF) FFT, N points.
-------------------------------------------------------------------------------
-- Open Research Institute -- Haifuraiya / Mode-Dynamic-Transponder
-- Polyphase channelizer back end. Replaces the iterative-block fft_n_pt and
-- its dual-FFT round-robin: drop-free by construction (no arbitration, no drop
-- path), one sample in / one sample out every valid cycle.
--
-- N a generic (power of 2). LOG2N delay-feedback stages + bit-reversal reorder.
-- Natural-order input, natural-order output (out_idx = 0..N-1). Bit-exact to
-- model/r2sdf_fft_model.py. First frame after reset is pipeline-fill garbage.
--
-- Tools: Vivado 2022.2 / GHDL, VHDL-93.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity r2sdf_fft is
    generic (
        N             : positive := 64;
        DATA_WIDTH    : positive := 40;
        TWIDDLE_WIDTH : positive := 16
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
end entity r2sdf_fft;

architecture rtl of r2sdf_fft is

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
    -- R2SDF DIF cascade latency = sum of stage feedback depths = N-1.
    constant CASCADE_LATENCY : natural := N - 1;
    constant FRAME_PHASE     : natural := (N - (CASCADE_LATENCY mod N)) mod N;

    type sig_arr is array (0 to LOG2N) of signed(DATA_WIDTH - 1 downto 0);
    signal n_re, n_im : sig_arr;
    signal n_valid    : std_logic_vector(0 to LOG2N);

begin

    n_re(0)    <= in_re;
    n_im(0)    <= in_im;
    n_valid(0) <= in_valid;

    gen_stages : for i in 0 to LOG2N - 1 generate
        u_stage : entity work.r2sdf_stage
            generic map (
                N             => N,
                D             => N / (2 ** (i + 1)),
                DATA_WIDTH    => DATA_WIDTH,
                TWIDDLE_WIDTH => TWIDDLE_WIDTH
            )
            port map (
                clk       => clk,
                rst       => rst,
                in_valid  => n_valid(i),
                in_re     => n_re(i),
                in_im     => n_im(i),
                out_valid => n_valid(i + 1),
                out_re    => n_re(i + 1),
                out_im    => n_im(i + 1)
            );
    end generate gen_stages;

    u_reorder : entity work.r2sdf_reorder
        generic map (
            N           => N,
            DATA_WIDTH  => DATA_WIDTH,
            FRAME_PHASE => FRAME_PHASE
        )
        port map (
            clk       => clk,
            rst       => rst,
            in_valid  => n_valid(LOG2N),
            in_re     => n_re(LOG2N),
            in_im     => n_im(LOG2N),
            out_valid => out_valid,
            out_re    => out_re,
            out_im    => out_im,
            out_idx   => out_idx
        );

end architecture rtl;
