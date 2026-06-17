-------------------------------------------------------------------------------
-- polyphase_filterbank_parallel.vhd
-- Polyphase Filterbank using parallel-MAC branches (ZCU102 path)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
--
-------------------------------------------------------------------------------
-- WHAT CHANGED AND WHY  ("Cast REVERSE GRAVITY on the commutator wheel")
-------------------------------------------------------------------------------
-- The previous architecture gave each branch its own delay line and a
-- forward commutator (branch_select counted UP: sample s -> branch s mod N).
-- That feeds branch k the data of polyphase phase k.  A *decimating*
-- polyphase channelizer needs the commutator to run the other way: branch k
-- must be married to phase (N-k), i.e. the samples x[mN - k].  Only then does
-- FFT bin 0 equal the prototype low-pass of the input, which is the
-- definition of the DC channel.
--
-- The forward direction makes bin 0's effective response droop ~11 dB across
-- the passband (the FM-to-AM that rippled constant-envelope inputs) AND leak
-- adjacent channels in at ~-4 dB instead of rejecting them by >60 dB.  It is
-- survivable for a single signal (the demod keys on frequency, not envelope)
-- but it breaks channel isolation, so it would sink real 64-channel
-- operation.  This was present at EVERY M, including the M=N critically
-- sampled default.
--
-- Two coupled defects, one fix:
--   1. Direction.  Each branch now reads its taps at the MIRROR phase from a
--      shared buffer:  branch k, tap i  <-  xbuf(k + N*i).  With xbuf(0) the
--      newest sample, that is x[G - k - N*i] -- the backward commutator.
--   2. Staleness (M<N only).  The old per-branch lines advanced only when the
--      commutator landed on them (every N samples), but outputs fire every M.
--      For M<N that left N-M branches holding stale, time-misaligned MACs.
--      A single shared sliding buffer (advances every sample) means every
--      branch reads CURRENT data every frame.  No staleness at any M.
--
-- Model-verified (docs Model C): for the Haifuraiya coeffs this takes channel
-- 0 from 23%/35% envelope ripple back to the ~7% band-edge floor, bit-for-bit
-- identical to a textbook prototype-low-pass-then-decimate-by-M.
--
-------------------------------------------------------------------------------
-- SCOPE / FOLLOW-ON (read before trusting non-zero channels)
-------------------------------------------------------------------------------
--   * For channels k != 0, the oversampled output phase rotation now lives in
--     the parent (top): haifuraiya_channelizer_top.vhd applies the per-channel
--     twiddle e^{-j2*pi*k*M*m/N} at the FFT output (channel_re/im). For
--     M=16, N=64 this collapses to (-j)^(k*m mod 4) -- a swap/negate, no
--     multiplier. k = r2_out_idx, m = per-frame block counter; k=0 -> identity,
--     so the DC channel is untouched. The bin-order mirror folds into the
--     rotation's sign (mirror == conjugate == sign-flip here), so it is one
--     knob, pinned by measurement: ch59's baseband offset collapses to ~0 with
--     the correct sign and doubles with the wrong one.
--   * With the rotation in place, the built-in channelizer CW self-tests that
--     probe specific non-zero bins are now correct and should be re-baselined
--     to the rotated (centered) outputs.
--
-------------------------------------------------------------------------------
-- INTERFACE / RESOURCES
-------------------------------------------------------------------------------
--   * Entity, generics, ports, and outputs_valid timing are UNCHANGED -- drop
--     in for the existing parallel-to-sequential adapter and FFT.  Latency
--     from the M-th sample of a frame to outputs_valid is still 4 clocks.
--   * Storage is unchanged: one N*TAPS_PER_BRANCH sample buffer is exactly the
--     same depth as the old N branches x TAPS_PER_BRANCH delay lines.
--   * DSP cost unchanged: N*TAPS_PER_BRANCH (1,536) multipliers, still split
--     into four 6-tap quarter-MACs per branch so each combinational cascade is
--     6 DSPs deep and stays inside one DSP column (the prior "Cast HASTE"
--     timing fix is preserved verbatim, just fed from the shared buffer).
--
-------------------------------------------------------------------------------
-- TIMING (per branch, identical pipeline depth to the prior fir_branch_parallel)
-------------------------------------------------------------------------------
--   M-th sample edge
--     -> fc_d0 : xbuf now holds the M-th sample; quarter-MACs read strided taps
--     -> fc_d1 : four 6-tap quarter results registered; combine to two halves
--     -> fc_d2 : two half results registered; final add
--     -> fc_d3 : final MAC registered into branch_results; outputs_valid = 1
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.haifuraiya_coeffs_pkg.all;

entity polyphase_filterbank_parallel is
    generic (
        N_CHANNELS       : positive := 64;
        -- Decimation factor M (samples consumed per output frame).
        --   M = N_CHANNELS: critically sampled.
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

    constant M_IDX_WIDTH : positive := clog2(M_DECIMATION);
    constant BUF_DEPTH   : positive := N_CHANNELS * TAPS_PER_BRANCH;
    constant Q_TAPS      : positive := TAPS_PER_BRANCH / 4;

    subtype sample_t is signed(DATA_WIDTH  - 1 downto 0);
    subtype coeff_t  is signed(COEFF_WIDTH - 1 downto 0);
    subtype accum_t  is signed(ACCUM_WIDTH - 1 downto 0);

    type buf_t          is array (0 to BUF_DEPTH - 1) of sample_t;
    type coeff_array_t  is array (0 to TAPS_PER_BRANCH - 1) of coeff_t;
    type quarter_t      is array (0 to 3) of accum_t;
    type result_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Shared sliding input buffer.  xbuf(0) = newest sample, xbuf(p) = the
    -- sample p inputs ago.  Advances one position on every sample_valid, so at
    -- any frame boundary every branch reads current data (no staleness at M<N).
    -- Same total storage as the old N per-branch delay lines.
    ---------------------------------------------------------------------------
    signal xbuf : buf_t := (others => (others => '0'));

    -- Frame counter (0..M-1) and the 4-stage valid pipeline.  fc_d0 fires the
    -- cycle after the M-th sample (when xbuf already holds it); fc_d1..d3 track
    -- the three remaining quarter-MAC pipeline stages.  For M=N these wrap once
    -- per commutator round, same cadence as before.
    signal samples_since_fc : unsigned(M_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal fc_d0 : std_logic := '0';
    signal fc_d1 : std_logic := '0';
    signal fc_d2 : std_logic := '0';
    signal fc_d3 : std_logic := '0';

    signal branch_results : result_array_t;

    ---------------------------------------------------------------------------
    -- Slice a branch's coefficients out of ALL_COEFFS (branch-major layout:
    -- branch k owns indices k*TAPS_PER_BRANCH .. (k+1)*TAPS_PER_BRANCH - 1).
    -- Branch k, tap i carries prototype coefficient h[k + N*i] -- the same
    -- pairing the per-branch fir_branch_parallel used; only the DATA phase the
    -- tap is multiplied against has been mirrored (k+N*i, the backward phase).
    ---------------------------------------------------------------------------
    function get_branch_coeffs(idx : natural) return coeff_array_t is
        constant FIRST : natural := idx * TAPS_PER_BRANCH;
        variable r     : coeff_array_t;
    begin
        for i in 0 to TAPS_PER_BRANCH - 1 loop
            r(i) := signed(ALL_COEFFS(FIRST + i));
        end loop;
        return r;
    end function;

begin

    ---------------------------------------------------------------------------
    -- Shared buffer shift (one process owns xbuf).
    ---------------------------------------------------------------------------
    p_buffer : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                xbuf <= (others => (others => '0'));
            elsif sample_valid = '1' then
                xbuf(0) <= signed(sample_in);
                for p in 1 to BUF_DEPTH - 1 loop
                    xbuf(p) <= xbuf(p - 1);
                end loop;
            end if;
        end if;
    end process p_buffer;

    ---------------------------------------------------------------------------
    -- Frame counter + valid pipeline (one process owns the fc_* chain).
    ---------------------------------------------------------------------------
    p_frame : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                samples_since_fc <= (others => '0');
                fc_d0 <= '0';
                fc_d1 <= '0';
                fc_d2 <= '0';
                fc_d3 <= '0';
            else
                fc_d0 <= '0';  -- default; pulsed on frame wrap
                if sample_valid = '1' then
                    if samples_since_fc = M_DECIMATION - 1 then
                        samples_since_fc <= (others => '0');
                        fc_d0 <= '1';
                    else
                        samples_since_fc <= samples_since_fc + 1;
                    end if;
                end if;
                fc_d1 <= fc_d0;
                fc_d2 <= fc_d1;
                fc_d3 <= fc_d2;
            end if;
        end if;
    end process p_frame;

    ---------------------------------------------------------------------------
    -- Per-branch parallel quarter-MAC, fed strided taps from the shared buffer.
    -- Each stage latches only on its frame-pulse phase so the frame's result
    -- propagates intact (and holds between frames).  Pipeline depth and the
    -- 6-tap quarter split match the prior fir_branch_parallel exactly.
    ---------------------------------------------------------------------------
    gen_branches : for k in 0 to N_CHANNELS - 1 generate
        constant CK : coeff_array_t := get_branch_coeffs(k);
        signal q       : quarter_t := (others => (others => '0'));
        signal half_a  : accum_t   := (others => '0');
        signal half_b  : accum_t   := (others => '0');
        signal mac_reg : accum_t   := (others => '0');
    begin
        -- Stage 1: four 6-tap quarter-MACs over the mirror-phase taps
        --          xbuf(k + N*i).  Read on fc_d0 (xbuf holds the M-th sample).
        p_quarters : process(clk)
            variable acc : accum_t;
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    q <= (others => (others => '0'));
                elsif fc_d0 = '1' then
                    for qi in 0 to 3 loop
                        acc := (others => '0');
                        for i in qi * Q_TAPS to (qi + 1) * Q_TAPS - 1 loop
                            acc := acc + resize(
                                xbuf(k + N_CHANNELS * i) * CK(i), ACCUM_WIDTH);
                        end loop;
                        q(qi) <= acc;
                    end loop;
                end if;
            end if;
        end process p_quarters;

        -- Stage 2: combine quarters into two halves (on fc_d1)
        p_halves : process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    half_a <= (others => '0');
                    half_b <= (others => '0');
                elsif fc_d1 = '1' then
                    half_a <= q(0) + q(1);
                    half_b <= q(2) + q(3);
                end if;
            end if;
        end process p_halves;

        -- Stage 3: final add (on fc_d2) -> branch result
        p_final : process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    mac_reg <= (others => '0');
                elsif fc_d2 = '1' then
                    mac_reg <= half_a + half_b;
                end if;
            end if;
        end process p_final;

        branch_results(k) <= std_logic_vector(mac_reg);
    end generate gen_branches;

    ---------------------------------------------------------------------------
    -- Pack branch outputs into a single bus (LSB = branch 0).  Branch->slot
    -- mapping is unchanged; only each branch's input data phase moved.
    ---------------------------------------------------------------------------
    gen_pack : for k in 0 to N_CHANNELS - 1 generate
        branch_outputs((k + 1) * ACCUM_WIDTH - 1 downto k * ACCUM_WIDTH)
            <= branch_results(k);
    end generate gen_pack;

    outputs_valid <= fc_d3;

end architecture rtl;
