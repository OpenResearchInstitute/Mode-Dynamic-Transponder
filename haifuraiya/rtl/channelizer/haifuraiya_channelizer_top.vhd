-------------------------------------------------------------------------------
-- haifuraiya_channelizer_top.vhd
-- Top-Level Polyphase Channelizer for Haifuraiya (Opulent Voice uplinks)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2.  RTL is VHDL-93-clean; compiles under -2008 too
--          (the surrounding filterbank/FIR files are -2008).
--
-- PIPELINED-FFT BACK END (drop-free by construction)
-- ---------------------------------------------------
-- The output stage is a single pipelined R2SDF FFT (r2sdf_fft) fed by the
-- existing parallel-to-sequential adapter. This REPLACES the previous
-- dual fft_n_pt round-robin + frame-drop path. The R2SDF ingests one frame
-- in N cycles against the >= N-cycle inter-frame interval at the production
-- M_DECIMATION, with no arbitration and no drop path to fire -- so frames
-- cannot be dropped by construction. r2sdf_fft is bit-exact to fft_n_pt
-- (verified: r2sdf == golden model == fft_n_pt), so OUTPUT_SHIFT, the power
-- detectors, EQ and m_axis are unaffected.
--
--   I/Q -> 2x polyphase_filterbank_parallel -> P2S adapter -> r2sdf_fft
--          -> channel_re/im/idx/valid/last
--
-- frame_dropped is retained as a health monitor: it can only assert if a new
-- filterbank frame arrives while the P2S is still streaming the previous one
-- (a "miss"), which does not occur at the production cadence. Structurally 0.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity haifuraiya_channelizer_top is
    generic (
        N_CHANNELS       : positive := 64;
        M_DECIMATION     : positive := 64;
        TAPS_PER_BRANCH  : positive := 24;
        DATA_WIDTH       : positive := 16;
        COEFF_WIDTH      : positive := 16;
        ACCUM_WIDTH      : positive := 40
    );
    port (
        clk              : in  std_logic;
        reset            : in  std_logic;

        sample_re        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_im        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid     : in  std_logic;

        channel_re       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        channel_im       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        channel_idx      : out std_logic_vector(5 downto 0);
        channel_valid    : out std_logic;
        channel_last     : out std_logic;

        ready            : out std_logic;
        frame_dropped    : out std_logic
    );

    function clog2(n : positive) return positive is
        variable result : positive := 1;
        variable value  : positive := 2;
    begin
        while value < n loop
            result := result + 1;
            value  := value * 2;
        end loop;
        return result;
    end function;

end entity haifuraiya_channelizer_top;

architecture rtl of haifuraiya_channelizer_top is

    constant CHANNEL_IDX_WIDTH : positive := clog2(N_CHANNELS);

    -- Pipeline-fill output frames to suppress before channel_valid goes live.
    -- The R2SDF latency is the cascade (N-1 samples) plus the reorder's
    -- one-frame ping-pong; the first real bin emerges after the initial
    -- partial sweep plus one full fill frame. Exact value confirmed in
    -- simulation against the iterative core (tb_channelizer_equiv).
    constant FILL_FRAMES : natural := 2;

    ---------------------------------------------------------------------------
    -- Filterbank outputs (packed buses + valid pulses)
    ---------------------------------------------------------------------------
    signal fb_i_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_i_outputs_valid : std_logic;
    signal fb_q_outputs       : std_logic_vector(N_CHANNELS * ACCUM_WIDTH - 1 downto 0);
    signal fb_q_outputs_valid : std_logic;

    ---------------------------------------------------------------------------
    -- Parallel-to-sequential adapter state
    ---------------------------------------------------------------------------
    type bin_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(ACCUM_WIDTH - 1 downto 0);
    signal latched_re : bin_array_t;
    signal latched_im : bin_array_t;

    type p2s_state_t is (P2S_WAITING, P2S_STREAMING);
    signal p2s_state : p2s_state_t := P2S_WAITING;
    signal p2s_idx   : unsigned(CHANNEL_IDX_WIDTH - 1 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Single pipelined FFT (R2SDF) I/O
    ---------------------------------------------------------------------------
    signal r2_in_re    : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal r2_in_im    : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal r2_in_valid : std_logic := '0';
    signal r2_out_re   : signed(ACCUM_WIDTH - 1 downto 0);
    signal r2_out_im   : signed(ACCUM_WIDTH - 1 downto 0);
    signal r2_out_idx  : unsigned(CHANNEL_IDX_WIDTH - 1 downto 0);
    signal r2_out_valid: std_logic;

    ---------------------------------------------------------------------------
    -- Priming / status
    ---------------------------------------------------------------------------
    signal out_frame_cnt   : natural range 0 to FILL_FRAMES := 0;
    signal primed          : std_logic;
    signal ready_r         : std_logic := '0';
    signal frame_dropped_r : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank: I path
    ---------------------------------------------------------------------------
    u_filterbank_i : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS      => N_CHANNELS,
            M_DECIMATION    => M_DECIMATION,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => sample_re,
            sample_valid   => sample_valid,
            branch_outputs => fb_i_outputs,
            outputs_valid  => fb_i_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Polyphase Filterbank: Q path
    ---------------------------------------------------------------------------
    u_filterbank_q : entity work.polyphase_filterbank_parallel
        generic map (
            N_CHANNELS      => N_CHANNELS,
            M_DECIMATION    => M_DECIMATION,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH
        )
        port map (
            clk            => clk,
            reset          => reset,
            sample_in      => sample_im,
            sample_valid   => sample_valid,
            branch_outputs => fb_q_outputs,
            outputs_valid  => fb_q_outputs_valid
        );

    ---------------------------------------------------------------------------
    -- Ready
    ---------------------------------------------------------------------------
    p_ready : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ready_r <= '0';
            else
                ready_r <= '1';
            end if;
        end if;
    end process p_ready;

    ---------------------------------------------------------------------------
    -- P2S adapter -> single FFT
    --
    -- Latch all N branch outputs on a filterbank frame, then stream them
    -- (idx 0..N-1) into the R2SDF, one per clock. No FFT arbitration, no
    -- round-robin, no drop path. frame_dropped flags only the impossible-at-
    -- production "new frame while still streaming" miss.
    ---------------------------------------------------------------------------
    p_p2s : process(clk)
    begin
        if rising_edge(clk) then
            r2_in_valid     <= '0';
            frame_dropped_r <= '0';

            if reset = '1' then
                p2s_state <= P2S_WAITING;
                p2s_idx   <= (others => '0');
            else
                case p2s_state is

                    when P2S_WAITING =>
                        if fb_i_outputs_valid = '1' then
                            for i in 0 to N_CHANNELS - 1 loop
                                latched_re(i) <= fb_i_outputs(
                                    (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                                latched_im(i) <= fb_q_outputs(
                                    (i + 1) * ACCUM_WIDTH - 1 downto i * ACCUM_WIDTH);
                            end loop;
                            p2s_state <= P2S_STREAMING;
                            p2s_idx   <= (others => '0');
                        end if;

                    when P2S_STREAMING =>
                        r2_in_valid <= '1';
                        r2_in_re    <= signed(latched_re(to_integer(p2s_idx)));
                        r2_in_im    <= signed(latched_im(to_integer(p2s_idx)));
                        if fb_i_outputs_valid = '1' then
                            frame_dropped_r <= '1';   -- miss (cannot happen at production M)
                        end if;
                        if p2s_idx = N_CHANNELS - 1 then
                            p2s_state <= P2S_WAITING;
                            p2s_idx   <= (others => '0');
                        else
                            p2s_idx <= p2s_idx + 1;
                        end if;

                end case;
            end if;
        end if;
    end process p_p2s;

    ---------------------------------------------------------------------------
    -- Single pipelined R2SDF FFT (drop-free by construction)
    ---------------------------------------------------------------------------
    u_fft : entity work.r2sdf_fft
        generic map (
            N             => N_CHANNELS,
            DATA_WIDTH    => ACCUM_WIDTH,
            TWIDDLE_WIDTH => 16
        )
        port map (
            clk       => clk,
            rst       => reset,
            in_valid  => r2_in_valid,
            in_re     => r2_in_re,
            in_im     => r2_in_im,
            out_valid => r2_out_valid,
            out_re    => r2_out_re,
            out_im    => r2_out_im,
            out_idx   => r2_out_idx
        );

    ---------------------------------------------------------------------------
    -- Priming: suppress channel_valid during the pipeline-fill frames so the
    -- first frame the downstream sees is real (matching the old core's
    -- contract, where the iterative FFT only emitted complete frames).
    ---------------------------------------------------------------------------
    p_prime : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                out_frame_cnt <= 0;
            elsif r2_out_valid = '1' and to_integer(r2_out_idx) = N_CHANNELS - 1 then
                if out_frame_cnt < FILL_FRAMES then
                    out_frame_cnt <= out_frame_cnt + 1;
                end if;
            end if;
        end if;
    end process p_prime;

    primed <= '1' when out_frame_cnt >= FILL_FRAMES else '0';

    ---------------------------------------------------------------------------
    -- Output mapping (40-bit, same scale as fft_n_pt)
    ---------------------------------------------------------------------------
    channel_re    <= std_logic_vector(r2_out_re);
    channel_im    <= std_logic_vector(r2_out_im);
    channel_idx   <= std_logic_vector(r2_out_idx);
    channel_valid <= r2_out_valid and primed;
    channel_last  <= '1' when (r2_out_valid = '1' and primed = '1'
                               and to_integer(r2_out_idx) = N_CHANNELS - 1)
                     else '0';

    ready         <= ready_r;
    frame_dropped <= frame_dropped_r;

end architecture rtl;
