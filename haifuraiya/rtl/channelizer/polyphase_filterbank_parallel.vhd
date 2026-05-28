-------------------------------------------------------------------------------
-- polyphase_filterbank_parallel.vhd
-- Polyphase Filterbank using parallel-MAC branches (ZCU102 path)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the streaming-friendly counterpart of polyphase_filterbank.vhd
-- using fir_branch_parallel branches that hold their coefficients in
-- elaboration-time constants. Compared to the iCE40 serial-MAC version
-- this entity drops:
--
--   * The LOAD_COEFFS state machine (no run-time coefficient loading)
--   * The coeff_addr / coeff_data / coeff_load ports
--   * The COMPUTING / OUTPUT_READY 2-state output dance
--   * All branch-coefficient packed registers
--
-- Each branch finishes its MAC 4 clocks after its sample arrives (a
-- 4-stage pipeline: taps -> four 6-tap quarter-MACs -> combine quarters
-- into two halves -> final add).  The filterbank pulses outputs_valid 4
-- clocks after the Nth sample of a frame (one for the d0 wrap-detect,
-- three more to let the last branch's MAC pipeline drain into mac_reg).
--
-- The output interface (branch_outputs packed bus + outputs_valid
-- pulse) is identical to polyphase_filterbank.vhd, so the downstream
-- parallel-to-sequential adapter and FFT need no changes -- the one
-- extra branch-pipeline clock simply shifts the outputs_valid pulse one
-- cycle later, and the consumers key off that pulse rather than a fixed
-- cycle count.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
--   Latency from first sample to first outputs_valid: N + 4 clocks
--     (N samples to fill the commutator, 4 for the pipelined MAC
--      stages: quarter-MACs, combine to halves, then mac_reg)
--
--   With Haifuraiya at 100 MHz / 10 Msps (10 clk/sample):
--     - Sample period:        100 ns
--     - Commutator round:     N * 100 ns = 6.4 us (per output frame)
--     - Branch MAC:           10 ns (1 clock) per sample, fully overlapped
--     - First output frame:   ~6.4 us after first sample (ignoring
--                             1536-sample delay-line fill for steady
--                             state; that is a filter-theory concern,
--                             not a pipeline concern)
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                       +---------------------------------------------+
--                       |       polyphase_filterbank_parallel         |
--                       |                                             |
--                       |   +---------------------+                   |
--    sample_in -------->|-->|                     |                   |
--    sample_valid ----->|-->|   commutator FSM    |                   |
--                       |   |   (branch_select)   |                   |
--                       |   +----------+----------+                   |
--                       |              | branch_sample_valid(i)       |
--                       |              v                              |
--                       |   +---------------------+                   |
--                       |   |  N branches, each   |-- result(i) ------|--> branch_outputs (packed)
--                       |   |  fir_branch_parallel|                   |
--                       |   |  with own COEFFS    |                   |
--                       |   +---------------------+                   |
--                       |                                             |
--                       |   wrap-detect -> d0 -> d1 -> d2 -> d3 ------|--> outputs_valid
--                       |                                             |
--                       +---------------------------------------------+
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity polyphase_filterbank_parallel is
    generic (
        N_CHANNELS       : positive := 64;
        -- Decimation factor M (samples consumed per output frame).
        --   M = N_CHANNELS: critically sampled (original behavior).
        --   M < N_CHANNELS: oversampled / guard-band mode.
        -- For cleanest channel response, M should divide N_CHANNELS.
        M_DECIMATION     : positive := 64;
        TAPS_PER_BRANCH  : positive := 24;
        DATA_WIDTH       : positive := 16;
        COEFF_WIDTH      : positive := 16;
        ACCUM_WIDTH      : positive := 40
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        sample_in       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid    : in  std_logic;

        branch_outputs  : out std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
        outputs_valid   : out std_logic
    );

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

end entity polyphase_filterbank_parallel;

architecture rtl of polyphase_filterbank_parallel is

    constant BRANCH_IDX_WIDTH : positive := clog2(N_CHANNELS);
    constant M_IDX_WIDTH      : positive := clog2(M_DECIMATION);

    type result_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);

    -- Per-branch result wires (driven by individual branch instances)
    signal branch_results       : result_array_t;
    -- One-hot sample_valid distribution (commutator output)
    signal branch_sample_valid  : std_logic_vector(N_CHANNELS - 1 downto 0);
    -- Commutator counter: free-runs 0..N-1, wraps independently of M.
    -- Drives which branch receives each input sample.
    signal branch_select        : unsigned(BRANCH_IDX_WIDTH - 1 downto 0)
                                  := (others => '0');
    -- Frame counter: counts 0..M-1, wraps and fires frame_complete.
    -- Independent of branch_select; drives output frame timing.
    signal samples_since_fc     : unsigned(M_IDX_WIDTH - 1 downto 0)
                                  := (others => '0');
    -- Frame-complete pipeline.  Four stages (d0..d3) so outputs_valid
    -- fires exactly when the last branch's mac_reg latches, matching the
    -- now-4-cycle MAC pipeline inside fir_branch_parallel (quarter-MAC).
    signal frame_complete_d0    : std_logic := '0';
    signal frame_complete_d1    : std_logic := '0';
    signal frame_complete_d2    : std_logic := '0';
    signal frame_complete_d3    : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Commutator: route sample_valid to the currently-selected branch
    -- (combinational one-hot decoder)
    ---------------------------------------------------------------------------
    p_commutator : process(branch_select, sample_valid)
    begin
        branch_sample_valid <= (others => '0');
        if sample_valid = '1' then
            branch_sample_valid(to_integer(branch_select)) <= '1';
        end if;
    end process p_commutator;

    ---------------------------------------------------------------------------
    -- Branch instances (each reads its own coefficient slice at elaboration)
    ---------------------------------------------------------------------------
    gen_branches : for i in 0 to N_CHANNELS - 1 generate
        u_branch : entity work.fir_branch_parallel
            generic map (
                TAPS_PER_BRANCH => TAPS_PER_BRANCH,
                DATA_WIDTH      => DATA_WIDTH,
                COEFF_WIDTH     => COEFF_WIDTH,
                ACCUM_WIDTH     => ACCUM_WIDTH,
                BRANCH_INDEX    => i
            )
            port map (
                clk          => clk,
                reset        => reset,
                sample_in    => sample_in,
                sample_valid => branch_sample_valid(i),
                result       => branch_results(i),
                result_valid => open  -- not used at filterbank level
            );
    end generate gen_branches;

    ---------------------------------------------------------------------------
    -- Counters and frame-complete pipeline
    --
    --   branch_select   : free-runs 0..N-1, wrapping naturally.  Decoupled
    --                     from frame_complete because for M<N the commutator
    --                     does not align with frame boundaries.
    --
    --   samples_since_fc: counts 0..M-1.  When it wraps (was M-1 and a new
    --                     sample arrives) we fire frame_complete_d0.
    --
    --   frame_complete_d1..d3: three-clock pipeline of d0 so outputs_valid
    --                     fires exactly when the last branch's mac_reg
    --                     latches the final MAC sum.  With
    --                     fir_branch_parallel's 4-stage quarter-MAC
    --                     pipeline the last branch's MAC settles 4 clocks
    --                     after its sample arrives, so outputs_valid lives
    --                     4 clocks downstream of the d0 wrap pulse.
    --
    -- For M = N_CHANNELS the two counters wrap on the same cycle, giving
    -- behaviour identical to the original M=N implementation.
    ---------------------------------------------------------------------------
    p_select : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                branch_select     <= (others => '0');
                samples_since_fc  <= (others => '0');
                frame_complete_d0 <= '0';
                frame_complete_d1 <= '0';
                frame_complete_d2 <= '0';
                frame_complete_d3 <= '0';
            else
                -- Default deassertion (gets overridden on wrap)
                frame_complete_d0 <= '0';

                if sample_valid = '1' then
                    -- Commutator wheel: wraps at N
                    if branch_select = N_CHANNELS - 1 then
                        branch_select <= (others => '0');
                    else
                        branch_select <= branch_select + 1;
                    end if;

                    -- Frame counter: wraps at M, asserts frame_complete
                    if samples_since_fc = M_DECIMATION - 1 then
                        samples_since_fc  <= (others => '0');
                        frame_complete_d0 <= '1';
                    else
                        samples_since_fc <= samples_since_fc + 1;
                    end if;
                end if;

                -- Three-stage pulse pipeline so outputs_valid fires 4
                -- clocks after the M-th sample (last branch's pipelined
                -- quarter-MAC has settled by then).
                frame_complete_d1 <= frame_complete_d0;
                frame_complete_d2 <= frame_complete_d1;
                frame_complete_d3 <= frame_complete_d2;
            end if;
        end if;
    end process p_select;

    ---------------------------------------------------------------------------
    -- Pack branch outputs into a single bus (LSB = branch 0)
    ---------------------------------------------------------------------------
    gen_pack : for i in 0 to N_CHANNELS - 1 generate
        branch_outputs((i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH)
            <= branch_results(i);
    end generate gen_pack;

    outputs_valid <= frame_complete_d3;

end architecture rtl;
