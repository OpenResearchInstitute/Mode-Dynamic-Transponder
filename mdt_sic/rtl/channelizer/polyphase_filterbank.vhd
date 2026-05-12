-------------------------------------------------------------------------------
-- polyphase_filterbank.vhd
-- Polyphase Filterbank for Channelizer
-- (Option 3: pure datapath; coefficient loading now external)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- The polyphase filterbank is the core of the channelizer. It:
--
--   1. Distributes input samples round-robin across N branches
--   2. Filters each branch with its portion of the prototype filter
--   3. Outputs all N branch results simultaneously (ready for FFT)
--
-- This module instantiates N fir_branch modules and manages:
--   - Sample distribution (commutator)
--   - Sequencing of the COMPUTING / OUTPUT_READY phases
--   - Collection of all branch outputs
--
-- Coefficient LOADING is no longer this module's responsibility: an external
-- coeff_loader entity handles the LOAD_COEFFS state machine and presents
-- pre-loaded coefficients via branch_coeffs_in. This enables a single
-- coeff_loader to feed multiple filterbank instances (e.g., one for I and
-- one for Q in a complex channelizer) without bus contention on coeff_rom.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                    ┌────────────────────────────────────────────────────┐
--                    │              polyphase_filterbank                  │
--                    │                                                    │
--   sample_in ──────►│──┬─► [fir_branch 0] ──► branch_out(0)             │
--                    │  │        ▲                                        │
--   sample_valid ───►│  │        │ coeffs                                 │
--                    │  ├─► [fir_branch 1] ──► branch_out(1)             │
--                    │  │        ▲                                        │
--                    │  ├─► [fir_branch 2] ──► branch_out(2)             │
--                    │  │        ▲                                        │
--                    │  └─► [fir_branch N-1] ► branch_out(N-1)           │
--                    │              ▲                                     │
--                    │       (per-branch slice)                           │
--   branch_coeffs_in │              ▲                                     │
--   ────────────────►│──────────────┘                                     │
--   (wide bus from   │                                                    │
--    coeff_loader)   │                                                    │
--                    │                                                    │
--   coeffs_ready ───►│ (gates state machine startup)                      │
--                    │                                                    │
--                    │                            outputs_valid ─────────►│
--                    │                            branch_outputs ────────►│
--                    └────────────────────────────────────────────────────┘
--
-------------------------------------------------------------------------------
-- STATE MACHINE
-------------------------------------------------------------------------------
--   WAIT_FOR_COEFFS  : initial state; transitions when coeffs_ready = '1'
--   WAIT_SAMPLES     : distributing incoming samples to branches
--   COMPUTING        : all branches running their MAC passes
--   OUTPUT_READY     : outputs_valid asserts for one cycle
--
-- Reset always returns to WAIT_FOR_COEFFS. Note that runtime reset will not
-- re-load coefficients in this entity (the loader is external) -- the loader
-- must also be reset to re-trigger a load.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity polyphase_filterbank is
    generic (
        -- Number of channels/branches
        -- MDT: 4, Haifuraiya: 64
        N_CHANNELS      : positive := 4;

        -- Taps per branch
        -- MDT: 16, Haifuraiya: 24
        TAPS_PER_BRANCH : positive := 16;

        -- Data widths
        DATA_WIDTH      : positive := 16;
        COEFF_WIDTH     : positive := 16;
        ACCUM_WIDTH     : positive := 36
    );
    port (
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Sample input (one sample at a time, distributed round-robin)
        sample_in       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid    : in  std_logic;

        -- Pre-loaded coefficients from external coeff_loader (wide bus).
        -- Layout: branch 0 in LSBs, branch N-1 in MSBs.
        -- Within each branch: tap 0 in LSBs, tap M-1 in MSBs.
        branch_coeffs_in : in  std_logic_vector(
            N_CHANNELS * TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
        coeffs_ready     : in  std_logic;

        -- Branch outputs (directly to FFT)
        -- All N branches output simultaneously
        branch_outputs  : out std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
        outputs_valid   : out std_logic
    );

end entity polyphase_filterbank;

architecture rtl of polyphase_filterbank is

    ---------------------------------------------------------------------------
    -- Functions
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
    end function;

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant BRANCH_IDX_WIDTH : positive := clog2(N_CHANNELS);

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type state_t is (
        WAIT_FOR_COEFFS,  -- Waiting for external coeff_loader to finish
        WAIT_SAMPLES,     -- Waiting for N samples
        COMPUTING,        -- Branches are computing
        OUTPUT_READY      -- All outputs valid
    );

    -- Array types for branch signals
    type coeff_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
    type result_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state : state_t := WAIT_FOR_COEFFS;

    -- Branch selection (commutator)
    signal branch_select : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');

    -- Per-branch signals
    signal branch_sample_valid : std_logic_vector(N_CHANNELS - 1 downto 0);
    signal branch_coeffs       : coeff_array_t;
    signal branch_results      : result_array_t;
    signal branch_done         : std_logic_vector(N_CHANNELS - 1 downto 0);

    -- Output synchronization
    signal all_branches_done : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Slice the wide branch_coeffs_in bus into per-branch coefficient blocks
    ---------------------------------------------------------------------------
    -- Purely combinational. branch_coeffs is no longer state held in this
    -- entity -- it's a view onto the external loader's storage.
    ---------------------------------------------------------------------------
    gen_branch_coeffs : for i in 0 to N_CHANNELS - 1 generate
        branch_coeffs(i) <= branch_coeffs_in(
            (i + 1) * TAPS_PER_BRANCH * COEFF_WIDTH - 1
            downto i * TAPS_PER_BRANCH * COEFF_WIDTH
        );
    end generate gen_branch_coeffs;

    ---------------------------------------------------------------------------
    -- Generate FIR Branches
    ---------------------------------------------------------------------------
    gen_branches : for i in 0 to N_CHANNELS - 1 generate
        u_branch : entity work.fir_branch
            generic map (
                TAPS_PER_BRANCH => TAPS_PER_BRANCH,
                DATA_WIDTH      => DATA_WIDTH,
                COEFF_WIDTH     => COEFF_WIDTH,
                ACCUM_WIDTH     => ACCUM_WIDTH
            )
            port map (
                clk          => clk,
                reset        => reset,
                sample_in    => sample_in,
                sample_valid => branch_sample_valid(i),
                coeffs       => branch_coeffs(i),
                result       => branch_results(i),
                result_valid => branch_done(i)
            );
    end generate gen_branches;

    ---------------------------------------------------------------------------
    -- Sample Distribution (Commutator)
    ---------------------------------------------------------------------------
    -- Route sample_valid to the selected branch.
    -- Gated by state /= WAIT_FOR_COEFFS so samples are dropped until the
    -- external loader has finished.
    ---------------------------------------------------------------------------
    process(branch_select, sample_valid, state)
    begin
        branch_sample_valid <= (others => '0');
        if state /= WAIT_FOR_COEFFS and sample_valid = '1' then
            branch_sample_valid(to_integer(branch_select)) <= '1';
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state         <= WAIT_FOR_COEFFS;
                branch_select <= (others => '0');
            else
                case state is

                    when WAIT_FOR_COEFFS =>
                        -- Hold until the external coeff_loader signals ready.
                        if coeffs_ready = '1' then
                            state <= WAIT_SAMPLES;
                        end if;

                    when WAIT_SAMPLES =>
                        -- Distribute incoming samples to branches via commutator.
                        if sample_valid = '1' then
                            if branch_select = N_CHANNELS - 1 then
                                branch_select <= (others => '0');
                                state <= COMPUTING;
                            else
                                branch_select <= branch_select + 1;
                            end if;
                        end if;

                    when COMPUTING =>
                        -- Wait for all branches to finish their MAC pass.
                        if all_branches_done = '1' then
                            state <= OUTPUT_READY;
                        end if;

                    when OUTPUT_READY =>
                        -- Outputs are valid for one cycle, then back to waiting.
                        state <= WAIT_SAMPLES;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output Logic
    ---------------------------------------------------------------------------
    all_branches_done <= '1' when branch_done = (branch_done'range => '1') else '0';

    -- Pack branch outputs into single vector for FFT consumption.
    gen_outputs : for i in 0 to N_CHANNELS - 1 generate
        branch_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH)
            <= branch_results(i);
    end generate gen_outputs;

    outputs_valid <= '1' when state = OUTPUT_READY else '0';

end architecture rtl;