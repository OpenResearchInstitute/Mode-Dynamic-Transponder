-------------------------------------------------------------------------------
-- fir_branch_parallel.vhd
-- Parallel-MAC FIR Branch for Polyphase Channelizer (ZCU102 path)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is a drop-in replacement for fir_branch.vhd that exploits the
-- abundance of DSP slices on the ZU9EG (2,520 DSP48E2). Where the iCE40
-- version uses a single multiplier walked across taps over M cycles,
-- this version instantiates all TAPS_PER_BRANCH multipliers in parallel
-- and sums them through an adder tree that synthesis builds from the
-- expression. Per-branch DSP cost: TAPS_PER_BRANCH (24 for Haifuraiya).
-- Total filterbank DSP cost: N_CHANNELS * TAPS_PER_BRANCH = 1,536, well
-- under the 2,520 budget.
--
-- This entity is also self-contained on coefficients: it reads its own
-- slice of the prototype filter from COEFF_FILE at elaboration time,
-- using the same branch-major file layout the iCE40 ROM-loader assumes
-- (branch k's TAPS_PER_BRANCH coefficients live at file lines
-- BRANCH_INDEX*TAPS_PER_BRANCH .. (BRANCH_INDEX+1)*TAPS_PER_BRANCH - 1).
-- This means: no coeff_rom instance, no LOAD_COEFFS state at the
-- filterbank, no ready latency. Each branch owns its data path end to end.
--
-------------------------------------------------------------------------------
-- TIMING
-------------------------------------------------------------------------------
--   Latency: 1 clock from sample_valid to result_valid
--
--   Cycle T   : sample arrives (sample_valid=1, sample_in=X)
--               -> delay line shift queued
--               -> valid_d <= 1
--   Cycle T+1 : taps register reflects new sample
--               -> mac_comb (combinational MAC) settles to MAC of new taps
--               -> mac_reg <= mac_comb at T+1's edge
--               -> valid_q <= valid_d (=1) at T+1's edge
--   Cycle T+1 (after edge) : result_valid='1', result=MAC of new taps
--
-- For Haifuraiya at 100 MHz with 10 Msps input (10 clk/sample), each
-- branch sees its sample once every N*10 = 640 clocks. 1-clock MAC
-- latency is comfortable in that envelope.
--
-------------------------------------------------------------------------------
-- BLOCK DIAGRAM
-------------------------------------------------------------------------------
--
--                         ┌──────────────────────────────────────────┐
--                         │            fir_branch_parallel           │
--                         │                                          │
--    sample_in ──────────►│──┐                                       │
--                         │  │   ┌─────────────────┐                 │
--    sample_valid ───────►│──┴──►│   delay line    │                 │
--                         │      │   M registers   │                 │
--                         │      └────────┬────────┘                 │
--                         │               │ M parallel taps          │
--                         │               ▼                          │
--                         │      ┌─────────────────┐                 │
--                         │      │ M parallel mults│  (DSP48E2)      │
--                         │      │  taps × COEFFS  │                 │
--                         │      └────────┬────────┘                 │
--                         │               │                          │
--                         │      ┌─────────────────┐                 │
--                         │      │   adder tree    │  (DSP cascade   │
--                         │      │   (synth-built) │   or LUT)       │
--                         │      └────────┬────────┘                 │
--                         │               │                          │
--                         │      ┌────────▼────────┐                 │
--                         │      │ output register │────► result     │
--                         │      └─────────────────┘                 │
--                         │                                          │
--                         │   COEFFS read from COEFF_FILE at         │
--                         │   elaboration; constant after that       │
--                         │                                          │
--                         └──────────────────────────────────────────┘
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.textio.all;
use ieee.std_logic_textio.all;

entity fir_branch_parallel is
    generic (
        -- Number of taps in this branch
        TAPS_PER_BRANCH : positive := 24;

        -- Sample width (signed)
        DATA_WIDTH      : positive := 16;

        -- Coefficient width (signed)
        COEFF_WIDTH     : positive := 16;

        -- Accumulator/output width
        -- Need DATA_WIDTH + COEFF_WIDTH + ceil(log2(TAPS_PER_BRANCH))
        -- For Haifuraiya: 16 + 16 + 5 = 37 minimum; using 40 with margin
        ACCUM_WIDTH     : positive := 40;

        -- Coefficient hex file (one coefficient per line, branch-major)
        COEFF_FILE      : string;

        -- This branch's index within the filterbank.
        -- Coefficients are read from file lines:
        --   BRANCH_INDEX*TAPS_PER_BRANCH .. (BRANCH_INDEX+1)*TAPS_PER_BRANCH - 1
        BRANCH_INDEX    : natural
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;

        sample_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        sample_valid : in  std_logic;

        result       : out std_logic_vector(ACCUM_WIDTH - 1 downto 0);
        result_valid : out std_logic
    );
end entity fir_branch_parallel;

architecture rtl of fir_branch_parallel is

    ---------------------------------------------------------------------------
    -- Local types
    ---------------------------------------------------------------------------
    type sample_array_t is array (0 to TAPS_PER_BRANCH - 1) of
        signed(DATA_WIDTH - 1 downto 0);
    type coeff_array_t is array (0 to TAPS_PER_BRANCH - 1) of
        signed(COEFF_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Read this branch's coefficient slice at elaboration
    --
    -- The hex file is branch-major: branch k's TAPS_PER_BRANCH coefficients
    -- occupy lines k*TAPS_PER_BRANCH .. (k+1)*TAPS_PER_BRANCH - 1.
    -- We skip earlier branches' lines, then read our taps in order.
    ---------------------------------------------------------------------------
    impure function read_branch_coeffs return coeff_array_t is
        file f             : text;
        variable line_v    : line;
        variable hex_v     : std_logic_vector(COEFF_WIDTH - 1 downto 0);
        variable result_v  : coeff_array_t := (others => (others => '0'));
        variable status    : file_open_status;
        constant SKIP_LINES : natural := BRANCH_INDEX * TAPS_PER_BRANCH;
    begin
        file_open(status, f, COEFF_FILE, read_mode);
        assert status = open_ok
            report "fir_branch_parallel(BRANCH_INDEX=" &
                   integer'image(BRANCH_INDEX) &
                   "): cannot open coefficient file '" & COEFF_FILE & "'"
            severity failure;

        -- Skip lines belonging to earlier branches
        for i in 0 to SKIP_LINES - 1 loop
            assert not endfile(f)
                report "fir_branch_parallel(BRANCH_INDEX=" &
                       integer'image(BRANCH_INDEX) &
                       "): unexpected EOF while skipping to slice"
                severity failure;
            readline(f, line_v);
        end loop;

        -- Read this branch's taps
        for i in 0 to TAPS_PER_BRANCH - 1 loop
            assert not endfile(f)
                report "fir_branch_parallel(BRANCH_INDEX=" &
                       integer'image(BRANCH_INDEX) &
                       "): unexpected EOF while reading taps"
                severity failure;
            readline(f, line_v);
            hread(line_v, hex_v);
            result_v(i) := signed(hex_v);
        end loop;

        file_close(f);
        return result_v;
    end function read_branch_coeffs;

    constant COEFFS : coeff_array_t := read_branch_coeffs;

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    signal taps     : sample_array_t := (others => (others => '0'));
    signal mac_comb : signed(ACCUM_WIDTH - 1 downto 0);
    signal mac_reg  : signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');
    signal valid_d  : std_logic := '0';
    signal valid_q  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Stage 1: Delay line shift on each new sample
    -- Owns: taps array. No cross-process writes.
    ---------------------------------------------------------------------------
    p_shift : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                taps <= (others => (others => '0'));
            elsif sample_valid = '1' then
                taps(0) <= signed(sample_in);
                for i in 1 to TAPS_PER_BRANCH - 1 loop
                    taps(i) <= taps(i - 1);
                end loop;
            end if;
        end if;
    end process p_shift;

    ---------------------------------------------------------------------------
    -- Stage 2: Combinational parallel MAC
    -- Synthesis flattens the for-loop into TAPS_PER_BRANCH multipliers and
    -- an adder tree. Vivado folds mult+add pairs into DSP48E2 slices
    -- automatically when patterns match (use_dsp = "yes" attribute can be
    -- added if the tool gets shy).
    ---------------------------------------------------------------------------
    p_mac : process(taps)
        variable acc_v : signed(ACCUM_WIDTH - 1 downto 0);
    begin
        acc_v := (others => '0');
        for i in 0 to TAPS_PER_BRANCH - 1 loop
            acc_v := acc_v + resize(taps(i) * COEFFS(i), ACCUM_WIDTH);
        end loop;
        mac_comb <= acc_v;
    end process p_mac;

    ---------------------------------------------------------------------------
    -- Stage 3: Register output and pipeline valid
    -- Owns: mac_reg, valid_d, valid_q
    ---------------------------------------------------------------------------
    p_out : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mac_reg <= (others => '0');
                valid_d <= '0';
                valid_q <= '0';
            else
                mac_reg <= mac_comb;
                valid_d <= sample_valid;
                valid_q <= valid_d;
            end if;
        end if;
    end process p_out;

    result       <= std_logic_vector(mac_reg);
    result_valid <= valid_q;

end architecture rtl;
