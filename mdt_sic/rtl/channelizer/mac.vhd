-------------------------------------------------------------------------------
-- mac.vhd
-- Multiply-Accumulate Unit for Polyphase Channelizer
-- (EBR-aware version, drives delay_line via tap_idx)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- Computes the dot product of NUM_TAPS coefficients with NUM_TAPS samples
-- from an external delay_line. The delay_line stores samples in block RAM
-- (EBR/BRAM) and exposes them through a tap_idx -> tap_out interface with
-- 1-cycle read latency.
--
-- This MAC drives tap_idx (0 -> NUM_TAPS-1) sequentially while accumulating
-- the products of coefficients with the samples returned by the delay_line.
-- A one-cycle coefficient pipeline aligns coeff[k] with sample[k] at the
-- multiplier, absorbing the EBR's read latency.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
-- One full pass through the filter takes NUM_TAPS + 2 cycles from start to
-- done (was NUM_TAPS + 1 with the previous wide-vector samples interface).
-- The extra cycle is the pipeline-fill delay at the start of COMPUTING.
--
-- For NUM_TAPS = 16:
--
--   Cycle 0 (entered COMPUTING from IDLE on previous edge):
--     - tap_idx_int = 0, drives external delay_line read for sample[0].
--     - tap_idx_d   = 0, but accum_en_d = 0 -> no accumulation yet.
--
--   Cycle 1:
--     - tap_idx_int = 1, drives delay_line for sample[1].
--     - delay_line.tap_out = sample[0] (registered at cycle 0's edge).
--     - tap_idx_d   = 0  -> coeff_arr[0] selected.
--     - First accumulation: accum += coeff[0] * sample[0].
--
--   Cycle k (1 <= k <= NUM_TAPS-1):
--     - tap_idx_int = k, tap_idx_d = k-1.
--     - sample = sample[k-1] (from previous cycle's read).
--     - accum += coeff[k-1] * sample[k-1].
--
--   Cycle NUM_TAPS (state -> DRAINING):
--     - tap_idx_int held at NUM_TAPS-1, tap_idx_d = NUM_TAPS-1.
--     - sample = sample[NUM_TAPS-1] (last read).
--     - Final accumulation: accum += coeff[NUM_TAPS-1] * sample[NUM_TAPS-1].
--
--   Cycle NUM_TAPS+1: state = DONE_STATE, done = '1', result valid.
--
-- At Fs = 40 kHz and clk_sys = 12 MHz, the MAC has ~300 cycles between
-- samples. Using 17-18 of them is comfortable.
--
-------------------------------------------------------------------------------
-- RESOURCE NOTES
-------------------------------------------------------------------------------
-- The previous version unpacked the wide 'samples' input into an array and
-- selected one element per cycle via tap_idx -- a NUM_TAPS:1 LUT mux that
-- ran every cycle. That mux is GONE here: the delay_line's block RAM read
-- port replaces it.
--
-- The 'coeffs' input is still a wide vector and is still muxed by tap_idx_d
-- inside this entity. That mux remains as a candidate for Move #1.5 (a
-- follow-up refactor moving coefficient storage / loading into the same
-- block-RAM-style pattern). For now, the coefficient mux survives because
-- the coefficient storage (in branch_coeffs registers in the parent
-- polyphase_filterbank) is small (NUM_TAPS * COEFF_WIDTH bits per branch)
-- and the LUT cost is dominated by the sample-mux that we just removed.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac is
    generic (
        NUM_TAPS    : positive := 16;
        DATA_WIDTH  : positive := 16;
        COEFF_WIDTH : positive := 16;
        ACCUM_WIDTH : positive := 36
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        start   : in  std_logic;
        done    : out std_logic;

        -- Coefficients (still parallel input, muxed internally by tap_idx_d)
        coeffs  : in  std_logic_vector(NUM_TAPS * COEFF_WIDTH - 1 downto 0);

        -- Tap interface to external delay_line:
        --   tap_idx_out drives delay_line.tap_idx (combinational from internal counter)
        --   sample_in   receives delay_line.tap_out (1-cycle read latency)
        tap_idx_out : out std_logic_vector;
        sample_in   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);

        result  : out std_logic_vector(ACCUM_WIDTH - 1 downto 0)
    );
end entity mac;

architecture rtl of mac is

    ---------------------------------------------------------------------------
    -- Functions
    ---------------------------------------------------------------------------
    function clog2(n : positive) return positive is
        variable r : positive := 1;
        variable v : positive := 2;
    begin
        while v < n loop
            r := r + 1;
            v := v * 2;
        end loop;
        return r;
    end function;

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant TAP_IDX_WIDTH : positive := clog2(NUM_TAPS);
    constant PRODUCT_WIDTH : positive := DATA_WIDTH + COEFF_WIDTH;

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    -- IDLE       : waiting for start
    -- COMPUTING  : issuing tap_idx values 0..NUM_TAPS-1; accumulating products
    -- DRAINING   : pipeline drain (one cycle to accumulate the last product)
    -- DONE_STATE : result valid for one cycle (or until start re-asserts)
    type state_t is (IDLE, COMPUTING, DRAINING, DONE_STATE);

    type coeff_array_t is array (0 to NUM_TAPS - 1) of
        signed(COEFF_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state       : state_t := IDLE;

    -- tap_idx_int drives the external delay_line (advanced each cycle in
    -- COMPUTING). tap_idx_d is tap_idx_int delayed by one cycle, used to
    -- index the coefficient array so coeff[k] meets sample[k] at the mult.
    signal tap_idx_int : unsigned(TAP_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal tap_idx_d   : unsigned(TAP_IDX_WIDTH - 1 downto 0) := (others => '0');

    -- accum_en_d is asserted one cycle after entering COMPUTING (after
    -- pipeline is filled) and remains asserted through DRAINING.
    signal accum_en_d  : std_logic := '0';

    signal accum       : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');

    signal coeff_arr   : coeff_array_t;
    signal curr_coeff  : signed(COEFF_WIDTH - 1 downto 0);
    signal curr_sample : signed(DATA_WIDTH - 1 downto 0);
    signal product     : signed(PRODUCT_WIDTH - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Unpack coefficient vector into array (combinational, at boundary)
    ---------------------------------------------------------------------------
    gen_unpack : for i in 0 to NUM_TAPS - 1 generate
        coeff_arr(i) <= signed(coeffs((i + 1) * COEFF_WIDTH - 1
                                      downto i * COEFF_WIDTH));
    end generate;

    ---------------------------------------------------------------------------
    -- Combinational mult path
    ---------------------------------------------------------------------------
    -- coeff is selected by tap_idx_d (one cycle behind the EBR read address)
    -- so coeff[k] arrives at the multiplier simultaneously with sample[k].
    ---------------------------------------------------------------------------
    curr_coeff  <= coeff_arr(to_integer(tap_idx_d));
    curr_sample <= signed(sample_in);
    product     <= curr_coeff * curr_sample;

    ---------------------------------------------------------------------------
    -- State machine + pipeline + accumulator (all in one clocked process)
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state       <= IDLE;
                tap_idx_int <= (others => '0');
                tap_idx_d   <= (others => '0');
                accum_en_d  <= '0';
                accum       <= (others => '0');
            else

                -- Pipeline tap_idx_int by one cycle for coefficient indexing.
                -- This MUST run every cycle (not gated by state) so that
                -- transitioning DRAINING->DONE_STATE leaves tap_idx_d at its
                -- final value for the last accumulation.
                tap_idx_d <= tap_idx_int;

                -- Accumulate when the pipeline is valid. accum_en_d is set
                -- one cycle into COMPUTING and cleared on entry to DONE_STATE.
                if accum_en_d = '1' then
                    accum <= accum + resize(product, ACCUM_WIDTH);
                end if;

                case state is

                    when IDLE =>
                        accum_en_d <= '0';
                        if start = '1' then
                            tap_idx_int <= (others => '0');
                            accum       <= (others => '0');
                            state       <= COMPUTING;
                            -- accum_en_d stays '0' for the first COMPUTING
                            -- cycle (pipeline not yet filled).
                        end if;

                    when COMPUTING =>
                        -- Pipeline is filled from cycle 1 of COMPUTING onward.
                        accum_en_d <= '1';

                        if tap_idx_int = NUM_TAPS - 1 then
                            -- All tap_idx values have been issued. Wait one
                            -- more cycle for the last sample to come back
                            -- from the delay_line and accumulate.
                            state <= DRAINING;
                        else
                            tap_idx_int <= tap_idx_int + 1;
                        end if;

                    when DRAINING =>
                        -- Final product accumulates THIS cycle (via the
                        -- accum_en_d='1' path above). Stop accumulating
                        -- after this cycle.
                        accum_en_d <= '0';
                        state      <= DONE_STATE;

                    when DONE_STATE =>
                        if start = '1' then
                            tap_idx_int <= (others => '0');
                            accum       <= (others => '0');
                            state       <= COMPUTING;
                            accum_en_d  <= '0';
                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    tap_idx_out <= std_logic_vector(tap_idx_int);
    done        <= '1' when state = DONE_STATE else '0';
    result      <= std_logic_vector(accum);

end architecture rtl;