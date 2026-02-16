-------------------------------------------------------------------------------
-- polyphase_filterbank.vhd
-- Polyphase Filterbank for Channelizer
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
--   - Coefficient routing from ROM to each branch
--   - Collection of all branch outputs
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
--                    │  │        │                                        │
--                    │  ├─► [fir_branch 1] ──► branch_out(1)             │
--                    │  │        ▲                                        │
--                    │  │        │ coeffs                                 │
--                    │  │        │                                        │
--                    │  ├─► [fir_branch 2] ──► branch_out(2)             │
--                    │  │        ▲                                        │
--                    │  │        │                                        │
--                    │  └─► [fir_branch N-1] ► branch_out(N-1)           │
--                    │              ▲                                     │
--                    │              │                                     │
--                    │         ┌────┴────┐                                │
--   coeff_data ─────►│────────►│coeff_rom│                                │
--   coeff_addr ◄────►│◄───────►│         │                                │
--                    │         └─────────┘                                │
--                    │                                                    │
--                    │                            outputs_valid ─────────►│
--                    │                            branch_outputs ────────►│
--                    └────────────────────────────────────────────────────┘
--
-- Note: Coefficient ROM is external to this module. This module generates
-- addresses and receives coefficient data, then routes to appropriate branch.
--
-------------------------------------------------------------------------------
-- SAMPLE DISTRIBUTION (COMMUTATOR)
-------------------------------------------------------------------------------
-- Input samples are distributed round-robin to branches:
--
--   Sample #:    0    1    2    3    4    5    6    7    8   ...
--   Branch:      0    1    2    3    0    1    2    3    0   ...  (N=4)
--
-- The branch_select counter cycles 0 → 1 → 2 → ... → N-1 → 0 → ...
--
-- Only one branch receives a sample each clock (when sample_valid=1).
-- After N samples, all branches have new data and begin computing.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
-- For N=4 channels, M=16 taps per branch:
--
--   Cycles 0-3:    Samples arrive, distributed to branches 0-3
--   Cycles 4-19:   All branches compute (M cycles for MAC)
--   Cycle 20:      outputs_valid asserts, branch_outputs ready for FFT
--
-- The outputs_valid signal asserts when ALL branches have completed.
-- This happens every N input samples (after the initial fill).
--
-------------------------------------------------------------------------------
-- COEFFICIENT ORGANIZATION
-------------------------------------------------------------------------------
-- The external coefficient ROM stores all N×M coefficients in polyphase order:
--
--   Addresses 0 to M-1:         Branch 0 coefficients
--   Addresses M to 2M-1:        Branch 1 coefficients
--   ...
--   Addresses (N-1)M to NM-1:   Branch N-1 coefficients
--
-- This module reads coefficients sequentially and latches them for each
-- branch before computation begins.
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE
-------------------------------------------------------------------------------
-- This module instantiates N fir_branch modules:
--
--   MDT (N=4):        4 × (256 FFs + 1 mult) = 1,024 FFs + 4 mults
--   Haifuraiya (N=64): 64 × (384 FFs + 1 mult) = 24,576 FFs + 64 mults
--
-- Plus control logic: branch counter, coefficient loading FSM, output sync.
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
        
        -- Coefficient ROM interface
        -- Active during coefficient loading phase
        coeff_addr      : out std_logic_vector(clog2(N_CHANNELS * TAPS_PER_BRANCH) - 1 downto 0);
        coeff_data      : in  std_logic_vector(COEFF_WIDTH - 1 downto 0);
        coeff_load      : out std_logic;  -- High during coefficient loading
        
        -- Branch outputs (directly to FFT)
        -- All N branches output simultaneously
        branch_outputs  : out std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
        outputs_valid   : out std_logic
    );
    
    -- Function to calculate address width
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
    
end entity polyphase_filterbank;

architecture rtl of polyphase_filterbank is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant COEFF_ADDR_WIDTH : positive := clog2(N_CHANNELS * TAPS_PER_BRANCH);
    constant BRANCH_IDX_WIDTH : positive := clog2(N_CHANNELS);

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type state_t is (
        LOAD_COEFFS,    -- Loading coefficients from ROM
        WAIT_SAMPLES,   -- Waiting for N samples
        COMPUTING,      -- Branches are computing
        OUTPUT_READY    -- All outputs valid
    );
    
    -- Array types for branch signals
    type sample_array_t is array (0 to N_CHANNELS - 1) of 
        std_logic_vector(DATA_WIDTH - 1 downto 0);
    type coeff_array_t is array (0 to N_CHANNELS - 1) of 
        std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);
    type result_array_t is array (0 to N_CHANNELS - 1) of 
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state : state_t := LOAD_COEFFS;
    
    -- Branch selection (commutator)
    signal branch_select : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal samples_loaded : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');
    
    -- Per-branch signals
    signal branch_sample_valid : std_logic_vector(N_CHANNELS - 1 downto 0);
    signal branch_coeffs       : coeff_array_t;
    signal branch_results      : result_array_t;
    signal branch_done         : std_logic_vector(N_CHANNELS - 1 downto 0);
    
    -- Coefficient loading
    signal coeff_addr_reg   : unsigned(COEFF_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_load_done  : std_logic := '0';
    signal coeff_branch_idx : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_tap_idx    : unsigned(clog2(TAPS_PER_BRANCH) - 1 downto 0) := (others => '0');
    
    -- Output synchronization
    signal all_branches_done : std_logic;

begin

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
    -- Route sample_valid to the selected branch
    ---------------------------------------------------------------------------
    process(branch_select, sample_valid, state)
    begin
        branch_sample_valid <= (others => '0');
        if state /= LOAD_COEFFS and sample_valid = '1' then
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
                state           <= LOAD_COEFFS;
                branch_select   <= (others => '0');
                samples_loaded  <= (others => '0');
                coeff_addr_reg  <= (others => '0');
                coeff_branch_idx <= (others => '0');
                coeff_tap_idx   <= (others => '0');
                coeff_load_done <= '0';
                
            else
                case state is
                    
                    when LOAD_COEFFS =>
                        -- Load coefficients from ROM into branch coefficient registers
                        -- Takes N×M cycles (one coefficient per cycle)
                        if coeff_load_done = '0' then
                            coeff_addr_reg <= coeff_addr_reg + 1;
                            
                            -- Track which branch and tap we're loading
                            if coeff_tap_idx = TAPS_PER_BRANCH - 1 then
                                coeff_tap_idx <= (others => '0');
                                if coeff_branch_idx = N_CHANNELS - 1 then
                                    coeff_load_done <= '1';
                                else
                                    coeff_branch_idx <= coeff_branch_idx + 1;
                                end if;
                            else
                                coeff_tap_idx <= coeff_tap_idx + 1;
                            end if;
                        else
                            state <= WAIT_SAMPLES;
                        end if;
                    
                    when WAIT_SAMPLES =>
                        -- Distribute incoming samples to branches
                        if sample_valid = '1' then
                            -- Advance to next branch
                            if branch_select = N_CHANNELS - 1 then
                                branch_select <= (others => '0');
                                state <= COMPUTING;
                            else
                                branch_select <= branch_select + 1;
                            end if;
                        end if;
                    
                    when COMPUTING =>
                        -- Wait for all branches to finish
                        if all_branches_done = '1' then
                            state <= OUTPUT_READY;
                        end if;
                    
                    when OUTPUT_READY =>
                        -- Outputs are valid for one cycle, then back to waiting
                        state <= WAIT_SAMPLES;
                        
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Coefficient Loading
    ---------------------------------------------------------------------------
    -- Shift coefficients into branch registers as they arrive from ROM
    -- ROM has 1-cycle latency, so we pipeline the loading
    ---------------------------------------------------------------------------
    process(clk)
        variable branch_idx : integer;
        variable tap_idx    : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                for i in 0 to N_CHANNELS - 1 loop
                    branch_coeffs(i) <= (others => '0');
                end loop;
            elsif state = LOAD_COEFFS and coeff_load_done = '0' then
                -- Coefficients arrive one cycle after address
                -- Pipeline: use previous address to know where to store
                if coeff_addr_reg > 0 then
                    branch_idx := to_integer(coeff_addr_reg - 1) / TAPS_PER_BRANCH;
                    tap_idx := to_integer(coeff_addr_reg - 1) mod TAPS_PER_BRANCH;
                    
                    -- Store coefficient in the appropriate slot
                    branch_coeffs(branch_idx)(
                        (tap_idx + 1) * COEFF_WIDTH - 1 downto tap_idx * COEFF_WIDTH
                    ) <= coeff_data;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output Logic
    ---------------------------------------------------------------------------
    all_branches_done <= '1' when branch_done = (branch_done'range => '1') else '0';
    
    -- Pack branch outputs into single vector
    gen_outputs : for i in 0 to N_CHANNELS - 1 generate
        branch_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH) 
            <= branch_results(i);
    end generate gen_outputs;
    
    outputs_valid <= '1' when state = OUTPUT_READY else '0';
    
    -- Coefficient ROM interface
    coeff_addr <= std_logic_vector(coeff_addr_reg);
    coeff_load <= '1' when state = LOAD_COEFFS else '0';

end architecture rtl;
