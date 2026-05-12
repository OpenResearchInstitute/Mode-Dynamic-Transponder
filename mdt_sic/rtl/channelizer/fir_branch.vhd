-------------------------------------------------------------------------------
-- fir_branch.vhd
-- Single FIR Filter Branch for Polyphase Channelizer
-- (Move #1: EBR-backed delay_line + sequential-tap MAC)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- A FIR branch combines a delay line and MAC unit to implement one branch
-- of the polyphase filterbank. Each branch:
--
--   1. Receives input samples (one every N clock cycles, where N = channels)
--   2. Stores sample history in a delay line (block-RAM ring buffer)
--   3. Multiplies all taps by their coefficients and sums (sequential MAC)
--   4. Outputs the filter result
--
-- The polyphase channelizer instantiates N of these branches (4 for MDT,
-- 64 for Haifuraiya), each processing every Nth input sample.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                         ┌─────────────────────────────────────┐
--                         │           fir_branch                │
--                         │                                     │
--    sample_in ──────────►│──┐                                  │
--                         │  │    ┌────────────┐                │
--    sample_valid ───────►│──┼───►│ delay_line │                │
--                         │  │    │            │                │
--                         │  │    │ shift_en   │                │
--                         │  │    │            │                │
--                         │  │    │ tap_idx ◄──┼─┐              │
--                         │  │    │ tap_out ───┼─┼─┐            │
--                         │  │    └────────────┘ │ │            │
--                         │  │                   │ │            │
--                         │  │    ┌────────────┐ │ │            │
--    coeffs ─────────────►│──┼───►│    mac     │ │ │            │
--                         │  │    │            │ │ │            │
--                         │  │    │ tap_idx_out┼─┘ │            │
--                         │  │    │ sample_in ◄┼───┘            │
--                         │  │    │            │                │
--                         │  │    │ start      │                │
--                         │  │    │       done │────────────────►│ result_valid
--                         │  │    │     result │────────────────►│ result
--                         │  │    └────────────┘                │
--                         │                                     │
--                         └─────────────────────────────────────┘
--
--   Internal wires:
--     mac_tap_idx  (clog2(TAPS) wide) -- MAC drives, delay_line reads
--     mac_sample   (DATA_WIDTH wide)  -- delay_line drives, MAC reads
--                                        1-cycle latency from EBR
--
-------------------------------------------------------------------------------
-- OPERATION TIMING
-------------------------------------------------------------------------------
-- When a new sample arrives (sample_valid=1):
--
--   1. Sample enters the delay line's ring buffer (write pointer advances)
--   2. MAC computation starts automatically one cycle later
--   3. MAC drives tap_idx 0 -> TAPS_PER_BRANCH-1 sequentially
--   4. delay_line returns each sample with 1-cycle EBR read latency;
--      MAC pipelines coefficient selection by 1 cycle to match
--   5. After TAPS_PER_BRANCH + 2 cycles, result_valid asserts
--
-------------------------------------------------------------------------------
-- COEFFICIENTS
-------------------------------------------------------------------------------
-- Coefficients are provided as an input port, not stored internally.
-- The coeffs input must remain stable during MAC computation
-- (TAPS_PER_BRANCH + 2 cycles).
--
-- Note for Move #1.5: the MAC still muxes coeffs internally by tap_idx_d.
-- A future refactor (after we validate Option 3) may move coefficient
-- storage into the same sequential block-RAM pattern used here for samples.
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE (per branch, after Move #1)
-------------------------------------------------------------------------------
--   Delay line: 1 block RAM (EBR on iCE40, BRAM on Xilinx)
--   MAC:        1 multiplier + 1 accumulator + small FSM + coeff mux
--
--   Was (per branch):   TAPS_PER_BRANCH * DATA_WIDTH FFs + TAPS-way LUT mux
--   Now (per branch):   1 block RAM + small address arithmetic
--
--   MDT (4 branches):        4 EBRs (of 30 on iCE40UP5K)
--   Haifuraiya (64 branches): 64 BRAMs (well within ZCU102 budget)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fir_branch is
    generic (
        -- Number of taps in this branch
        -- MDT: 16, Haifuraiya: 24
        TAPS_PER_BRANCH : positive := 16;

        -- Width of input samples (signed)
        DATA_WIDTH      : positive := 16;

        -- Width of coefficients (signed)
        COEFF_WIDTH     : positive := 16;

        -- Width of accumulator/output
        -- Must be >= DATA_WIDTH + COEFF_WIDTH + ceil(log2(TAPS_PER_BRANCH))
        ACCUM_WIDTH     : positive := 36
    );
    port (
        -- Clock and reset
        clk          : in  std_logic;
        reset        : in  std_logic;

        -- Sample input
        sample_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid : in  std_logic;  -- Assert for one cycle when new sample arrives

        -- Coefficients for this branch (from coefficient ROM or external source)
        -- Must remain stable during computation (TAPS_PER_BRANCH + 2 cycles)
        -- Packed format: coeff[0] in LSBs, coeff[TAPS_PER_BRANCH-1] in MSBs
        coeffs       : in  std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);

        -- Filter output
        result       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        result_valid : out std_logic   -- Asserts when result is valid
    );
end entity fir_branch;

architecture rtl of fir_branch is

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
    constant TAP_IDX_WIDTH : positive := clog2(TAPS_PER_BRANCH);

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------

    -- Tap interface between MAC (driver) and delay_line (responder)
    signal mac_tap_idx : std_logic_vector(TAP_IDX_WIDTH - 1 downto 0);
    signal mac_sample  : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- MAC control and output
    signal mac_start  : std_logic;
    signal mac_done   : std_logic;
    signal mac_result : std_logic_vector(ACCUM_WIDTH - 1 downto 0);

    -- State for coordinating delay line and MAC
    signal computing  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Delay Line Instance
    ---------------------------------------------------------------------------
    -- EBR-backed ring buffer. MAC drives tap_idx; tap_out returns one cycle
    -- later. The 'taps' wide-vector port is GONE in this version.
    ---------------------------------------------------------------------------
    u_delay_line : entity work.delay_line
        generic map (
            DELAY_DEPTH => TAPS_PER_BRANCH,
            DATA_WIDTH  => DATA_WIDTH
        )
        port map (
            clk      => clk,
            reset    => reset,
            shift_en => sample_valid,
            data_in  => sample_in,
            tap_idx  => mac_tap_idx,
            tap_out  => mac_sample
        );

    ---------------------------------------------------------------------------
    -- MAC Instance
    ---------------------------------------------------------------------------
    -- Sequentially drives tap_idx_out (0..TAPS-1) and accumulates the products
    -- of coeff[k] with the sample[k] returned by delay_line one cycle later.
    -- Coefficient mux still lives inside the MAC (candidate for Move #1.5).
    ---------------------------------------------------------------------------
    u_mac : entity work.mac
        generic map (
            NUM_TAPS    => TAPS_PER_BRANCH,
            DATA_WIDTH  => DATA_WIDTH,
            COEFF_WIDTH => COEFF_WIDTH,
            ACCUM_WIDTH => ACCUM_WIDTH
        )
        port map (
            clk         => clk,
            reset       => reset,
            start       => mac_start,
            done        => mac_done,
            coeffs      => coeffs,
            tap_idx_out => mac_tap_idx,
            sample_in   => mac_sample,
            result      => mac_result
        );

    ---------------------------------------------------------------------------
    -- Control Logic
    ---------------------------------------------------------------------------
    -- Start MAC computation when a new sample arrives. The delay_line's write
    -- pointer advances on the same clock edge as sample_valid='1'. The MAC
    -- begins one cycle later, so the new sample is already in the ring when
    -- the MAC issues tap_idx=0.
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mac_start <= '0';
                computing <= '0';
            else
                -- Default: don't start
                mac_start <= '0';

                if sample_valid = '1' and computing = '0' then
                    -- New sample arrived, start MAC on next cycle
                    -- (delay line will have shifted by then)
                    mac_start <= '1';
                    computing <= '1';
                elsif mac_done = '1' then
                    -- Computation complete, ready for next sample
                    computing <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    result       <= mac_result;
    result_valid <= mac_done;

end architecture rtl;