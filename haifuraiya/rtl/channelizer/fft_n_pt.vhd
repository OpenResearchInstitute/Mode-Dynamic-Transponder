-- =========================================================================
-- fft_n_pt: parameterized radix-2 DIF FFT, N samples.
--
-- N is a generic, must be a power of 2 (>= 4).  Input is fed as N samples in
-- natural order (x_idx = 0..N-1).  Output is in natural-order DFT bins
-- (out_idx = 0..N-1).
--
-- Algorithm:
--   1. LOADING   : write input samples to buf_a at x_idx (natural order).
--   2. COMPUTING : LOG2_N decimation-in-frequency stages, ping-pong between
--                  buf_a and buf_b.  Each stage runs N/2 butterflies, one
--                  per clock.  DIF butterflies leave the result in
--                  bit-reversed positions in the destination buffer.
--   3. OUTPUTTING: read the final buffer at bit_reverse(out_cnt) and emit
--                  it with out_idx = out_cnt (natural-order output).
--
-- Total latency: N + LOG2_N * (N/2) + N cycles.
-- For N=64: 64 + 192 + 64 = 320 cycles.
--
-- Pipeline shape (per COMPUTING cycle):
--   pre-edge: stage_cnt, butterfly_cnt define which butterfly we're on
--   combinational: idx_a, idx_b, twiddle_idx -> operand_a, operand_b from
--                  the source buffer -> butterfly result (out_a, out_b)
--   at-edge: write out_a / out_b into the destination buffer
--
-- Verified against numpy.fft via Python reference (machine-precision match
-- on DC, all integer-bin tones, impulse, random complex inputs).
--
-- License: CERN-OHL-S-2.0
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.fft_pkg.all;

entity fft_n_pt is
    generic (
        N           : positive := 64;   -- FFT size, power of 2, >= 4
        DATA_WIDTH  : positive := 40    -- bit-width of re / im components
    );
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Streaming input: N samples per frame, x_idx counts 0..N-1.
        x_re        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        x_im        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        x_idx       : in  std_logic_vector(clog2(N) - 1 downto 0);
        x_valid     : in  std_logic;
        x_last      : in  std_logic;

        -- Streaming output: N samples per frame, out_idx = 0..N-1.
        out_re      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        out_im      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        out_idx     : out std_logic_vector(clog2(N) - 1 downto 0);
        out_valid   : out std_logic;
        out_last    : out std_logic;

        busy        : out std_logic
    );
end entity fft_n_pt;


architecture rtl of fft_n_pt is

    ---------------------------------------------------------------------------
    -- Derived constants
    ---------------------------------------------------------------------------
    constant LOG2_N        : natural  := clog2(N);
    constant TWIDDLE_WIDTH : positive := 16;                  -- Q1.14 format
    constant TWIDDLE_SCALE : positive := 2**(TWIDDLE_WIDTH - 2);  -- = 16384

    ---------------------------------------------------------------------------
    -- Data types
    ---------------------------------------------------------------------------
    type complex_t is record
        re : signed(DATA_WIDTH - 1 downto 0);
        im : signed(DATA_WIDTH - 1 downto 0);
    end record;

    type buffer_t is array (0 to N - 1) of complex_t;

    type twiddle_t is record
        re : signed(TWIDDLE_WIDTH - 1 downto 0);
        im : signed(TWIDDLE_WIDTH - 1 downto 0);
    end record;

    type twiddle_rom_t is array (0 to N/2 - 1) of twiddle_t;

    constant ZERO_COMPLEX : complex_t :=
        (re => (others => '0'), im => (others => '0'));

    constant ZERO_BUFFER : buffer_t := (others => ZERO_COMPLEX);

    ---------------------------------------------------------------------------
    -- Twiddle ROM: W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N), Q1.14 scaled.
    ---------------------------------------------------------------------------
    function init_twiddle_rom return twiddle_rom_t is
        variable rom   : twiddle_rom_t;
        variable angle : real;
    begin
        for k in 0 to N/2 - 1 loop
            angle := 2.0 * MATH_PI * real(k) / real(N);
            rom(k).re := to_signed(integer( cos(angle) * real(TWIDDLE_SCALE - 1)),
                                   TWIDDLE_WIDTH);
            rom(k).im := to_signed(integer(-sin(angle) * real(TWIDDLE_SCALE - 1)),
                                   TWIDDLE_WIDTH);
        end loop;
        return rom;
    end function;

    constant TWIDDLE_ROM : twiddle_rom_t := init_twiddle_rom;

    ---------------------------------------------------------------------------
    -- State machine and counters
    ---------------------------------------------------------------------------
    type state_t is (IDLE, LOADING, COMPUTING, OUTPUTTING);
    signal state : state_t := IDLE;

    -- stage_cnt: 0..LOG2_N-1
    -- butterfly_cnt: 0..N/2-1
    -- out_cnt: 0..N-1
    signal stage_cnt     : unsigned(clog2(LOG2_N + 1) - 1 downto 0)
                           := (others => '0');
    signal butterfly_cnt : unsigned(LOG2_N - 1 downto 0) := (others => '0');
    signal out_cnt       : unsigned(LOG2_N - 1 downto 0) := (others => '0');

    -- src_is_buf_a: which buffer is the *source* for the current/next stage.
    --   Stage 0 reads buf_a (the LOADING dest), so src_is_buf_a starts at '1'.
    --   Toggles after every stage including the final one, so after the FFT
    --   completes it points to the buffer that holds the final result.
    signal src_is_buf_a  : std_logic := '1';

    ---------------------------------------------------------------------------
    -- Buffers and combinational signals
    ---------------------------------------------------------------------------
    signal buf_a : buffer_t := ZERO_BUFFER;
    signal buf_b : buffer_t := ZERO_BUFFER;

    signal idx_a     : natural range 0 to N - 1;
    signal idx_b     : natural range 0 to N - 1;
    signal tw_idx    : natural range 0 to N/2 - 1;

    signal operand_a : complex_t;
    signal operand_b : complex_t;
    signal twiddle   : twiddle_t;
    signal bf_out_a  : complex_t;
    signal bf_out_b  : complex_t;

begin

    ---------------------------------------------------------------------------
    -- FSM and counters.  Owns: state, stage_cnt, butterfly_cnt, out_cnt,
    -- src_is_buf_a.
    ---------------------------------------------------------------------------
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state         <= IDLE;
                stage_cnt     <= (others => '0');
                butterfly_cnt <= (others => '0');
                out_cnt       <= (others => '0');
                src_is_buf_a  <= '1';
            else
                case state is

                    when IDLE =>
                        if x_valid = '1' then
                            state         <= LOADING;
                            src_is_buf_a  <= '1';  -- stage 0 will read buf_a
                        end if;

                    when LOADING =>
                        if x_valid = '1' and x_last = '1' then
                            state         <= COMPUTING;
                            stage_cnt     <= (others => '0');
                            butterfly_cnt <= (others => '0');
                        end if;

                    when COMPUTING =>
                        if butterfly_cnt = N/2 - 1 then
                            butterfly_cnt <= (others => '0');
                            -- Toggle the source buffer for the next stage
                            -- (or, after the final stage, so it points to
                            -- the buffer holding the final result).
                            src_is_buf_a  <= not src_is_buf_a;

                            if to_integer(stage_cnt) = LOG2_N - 1 then
                                state   <= OUTPUTTING;
                                out_cnt <= (others => '0');
                            else
                                stage_cnt <= stage_cnt + 1;
                            end if;
                        else
                            butterfly_cnt <= butterfly_cnt + 1;
                        end if;

                    when OUTPUTTING =>
                        if out_cnt = N - 1 then
                            state <= IDLE;
                        else
                            out_cnt <= out_cnt + 1;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

    -- Busy = high during all active states. We anticipate IDLE by one cycle:
    -- when state=OUTPUTTING and out_cnt=N-1, the FSM transitions to IDLE on
    -- the next edge, and the buffers will be available. Signaling busy='0'
    -- here lets a downstream arbiter pre-arm a new frame, eliminating the
    -- one-cycle gap between back-to-back FFT uses (needed for the dual-FFT
    -- parallel channelizer at M = N_CHANNELS/2 or smaller).
    --
    -- This is safe because:
    --   - The last OUTPUTTING cycle's read of buf is already in flight
    --     (registered via p_output), so the buffer is no longer being read
    --     for the current frame on the next cycle.
    --   - LOADING for the new frame starts two cycles later (1 cycle for
    --     P2S to latch, 1 cycle for the FFT to see x_valid in IDLE), by
    --     which time state has transitioned to IDLE.
    busy <= '0' when state = IDLE else
            '0' when state = OUTPUTTING and out_cnt = N - 1 else
            '1';

    ---------------------------------------------------------------------------
    -- Combinational butterfly address generation.
    --
    -- For DIF stage S, butterfly K:
    --   half_size     = N/2 >> S         = 2^(LOG2_N - 1 - S)
    --   group_idx     = K >> (LOG2_N - 1 - S)
    --   pair_in_group = K mod half_size
    --   idx_a         = group_idx * (2 * half_size) + pair_in_group
    --   idx_b         = idx_a + half_size
    --   twiddle_idx   = pair_in_group * 2^S
    ---------------------------------------------------------------------------
    p_addr : process(stage_cnt, butterfly_cnt)
        variable s         : natural range 0 to LOG2_N - 1;
        variable k         : natural range 0 to N/2 - 1;
        variable hs        : natural range 1 to N/2;
        variable grp       : natural range 0 to N/2 - 1;
        variable pair      : natural range 0 to N/2 - 1;
    begin
        s     := to_integer(stage_cnt);
        k     := to_integer(butterfly_cnt(LOG2_N - 2 downto 0));
        hs    := N / 2 / (2 ** s);
        grp   := k / (2 ** (LOG2_N - 1 - s));
        pair  := k mod hs;

        idx_a  <= grp * (2 * hs) + pair;
        idx_b  <= grp * (2 * hs) + pair + hs;
        tw_idx <= pair * (2 ** s);
    end process p_addr;

    ---------------------------------------------------------------------------
    -- Combinational read mux: pick the source buffer based on src_is_buf_a.
    ---------------------------------------------------------------------------
    p_read : process(src_is_buf_a, idx_a, idx_b, buf_a, buf_b)
    begin
        if src_is_buf_a = '1' then
            operand_a <= buf_a(idx_a);
            operand_b <= buf_a(idx_b);
        else
            operand_a <= buf_b(idx_a);
            operand_b <= buf_b(idx_b);
        end if;
    end process p_read;

    twiddle <= TWIDDLE_ROM(tw_idx);

    ---------------------------------------------------------------------------
    -- Combinational butterfly:
    --   bf_out_a = operand_a + operand_b
    --   bf_out_b = (operand_a - operand_b) * twiddle
    -- Q1.14 twiddle -> drop the bottom (TWIDDLE_WIDTH-2) bits of the product
    -- to scale back into the DATA_WIDTH range.
    ---------------------------------------------------------------------------
    p_butterfly : process(operand_a, operand_b, twiddle)
        variable diff_re, diff_im : signed(DATA_WIDTH - 1 downto 0);
        variable prod_re, prod_im : signed(DATA_WIDTH + TWIDDLE_WIDTH - 1 downto 0);
    begin
        -- Sum half
        bf_out_a.re <= operand_a.re + operand_b.re;
        bf_out_a.im <= operand_a.im + operand_b.im;

        -- Difference, then complex multiply with twiddle
        diff_re := operand_a.re - operand_b.re;
        diff_im := operand_a.im - operand_b.im;

        prod_re := diff_re * twiddle.re - diff_im * twiddle.im;
        prod_im := diff_re * twiddle.im + diff_im * twiddle.re;

        -- Slice off Q1.14 scaling, keep DATA_WIDTH bits
        bf_out_b.re <= prod_re(DATA_WIDTH + TWIDDLE_WIDTH - 3
                               downto TWIDDLE_WIDTH - 2);
        bf_out_b.im <= prod_im(DATA_WIDTH + TWIDDLE_WIDTH - 3
                               downto TWIDDLE_WIDTH - 2);
    end process p_butterfly;

    ---------------------------------------------------------------------------
    -- Buffer A writer.  Owns: buf_a.
    --
    -- buf_a is written from two sources, both mutually exclusive:
    --   LOADING                       -> input sample at x_idx
    --   COMPUTING with src_is_buf_a=0 -> butterfly result (this stage reads
    --                                    buf_b and writes buf_a)
    ---------------------------------------------------------------------------
    p_write_buf_a : process(clk)
    begin
        if rising_edge(clk) then
            if (state = LOADING or state = IDLE) and x_valid = '1' then
                -- IDLE-or-LOADING: the FSM transitions IDLE->LOADING on the
                -- first x_valid edge, so we have to write at IDLE too, or the
                -- first sample (x_idx=0) is dropped on the transition cycle.
                buf_a(to_integer(unsigned(x_idx))).re <= signed(x_re);
                buf_a(to_integer(unsigned(x_idx))).im <= signed(x_im);
            elsif state = COMPUTING and src_is_buf_a = '0' then
                buf_a(idx_a) <= bf_out_a;
                buf_a(idx_b) <= bf_out_b;
            end if;
        end if;
    end process p_write_buf_a;

    ---------------------------------------------------------------------------
    -- Buffer B writer.  Owns: buf_b.
    --
    -- buf_b is written only during COMPUTING when src_is_buf_a='1' (this
    -- stage reads buf_a and writes buf_b).
    ---------------------------------------------------------------------------
    p_write_buf_b : process(clk)
    begin
        if rising_edge(clk) then
            if state = COMPUTING and src_is_buf_a = '1' then
                buf_b(idx_a) <= bf_out_a;
                buf_b(idx_b) <= bf_out_b;
            end if;
        end if;
    end process p_write_buf_b;

    ---------------------------------------------------------------------------
    -- Output mux.  Owns: out_re, out_im, out_idx, out_valid, out_last.
    --
    -- DIF puts the final result in bit-reversed positions, so we unscramble
    -- on the read side: out_cnt=k reads buf[bit_reverse(k)] and emits it as
    -- bin k.
    --
    -- After the final stage's toggle, src_is_buf_a points to the buffer
    -- that holds the final result.
    ---------------------------------------------------------------------------
    p_output : process(clk)
        variable bri : natural range 0 to N - 1;
        variable src : complex_t;
    begin
        if rising_edge(clk) then
            out_valid <= '0';
            out_last  <= '0';

            if state = OUTPUTTING then
                bri := bit_reverse(to_integer(out_cnt), LOG2_N);

                if src_is_buf_a = '1' then
                    src := buf_a(bri);
                else
                    src := buf_b(bri);
                end if;

                out_re    <= std_logic_vector(src.re);
                out_im    <= std_logic_vector(src.im);
                out_idx   <= std_logic_vector(out_cnt);
                out_valid <= '1';
                if out_cnt = N - 1 then
                    out_last <= '1';
                end if;
            end if;
        end if;
    end process p_output;

end architecture rtl;
