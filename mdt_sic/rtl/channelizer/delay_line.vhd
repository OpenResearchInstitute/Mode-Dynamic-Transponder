-------------------------------------------------------------------------------
-- delay_line.vhd
-- Sample Delay Line for Polyphase Channelizer (EBR/BRAM ring buffer)
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- Stores the last DELAY_DEPTH samples in a ring buffer backed by block RAM
-- (EBR on iCE40, BRAM on Xilinx). Replaces the previous shift-register
-- implementation that stored all taps in flip-flops and exposed them as a
-- wide parallel 'taps' vector.
--
-- The parent fir_branch's MAC unit already accesses taps sequentially (one
-- per cycle, indexed by tap_idx). The previous parallel-taps interface forced
-- the MAC to instantiate a DELAY_DEPTH:1 multiplexer in LUTs to do that
-- sequential selection. This module exposes the natural sequential read
-- directly: the MAC drives tap_idx, this module returns one tap_out per cycle
-- with 1-cycle read latency.
--
-- The net architectural win: both the FF storage AND the wide LUT mux that
-- were sitting in the MAC's inner loop disappear. The storage moves to one
-- block RAM per branch (cheap, plentiful on iCE40 EBR and Xilinx BRAM).
--
-------------------------------------------------------------------------------
-- INTERFACE
-------------------------------------------------------------------------------
-- Write side (sample insertion):
--   On rising_edge(clk) with shift_en='1', data_in is stored at the current
--   write pointer and the pointer advances (modulo DELAY_DEPTH).
--
-- Read side (tap access by index):
--   tap_idx is sampled on rising_edge(clk). The block-RAM read result appears
--   on tap_out one cycle later (1-cycle synchronous read latency, mandatory
--   on both iCE40 EBR and Xilinx BRAM — no async-read block RAM exists on
--   either platform).
--
--   Convention:
--     tap_idx = 0             -> newest sample (most recently written)
--     tap_idx = 1             -> previous sample
--     tap_idx = DELAY_DEPTH-1 -> oldest sample still in the ring
--
-------------------------------------------------------------------------------
-- RESET BEHAVIOR
-------------------------------------------------------------------------------
-- Synchronous reset clears the write pointer to 0. The RAM contents themselves
-- are not cleared at runtime — block RAMs on iCE40/Xilinx don't have a runtime
-- reset for their storage. Initial RAM contents are zero, set at bitstream-
-- configuration time via the signal-level initializer (see 'ram' below).
--
-- Behavioral difference from the previous shift-register version:
--   - Cold boot:  identical behavior (RAM initialized to zero in bitstream).
--   - Hot reset:  previous version cleared taps to zero immediately. This
--                 version retains EBR contents but restarts the write pointer.
--                 Any pre-reset data will be overwritten by the next
--                 DELAY_DEPTH samples.
--
-- For the polyphase channelizer, a hot reset always coincides with the parent
-- filterbank entering LOAD_COEFFS state, during which no taps are read.
-- By the time the filterbank begins computing again, the ring has been
-- refilled or the stale data has been overwritten, so the difference is
-- invisible at the channel outputs.
--
-------------------------------------------------------------------------------
-- RESOURCE USAGE
-------------------------------------------------------------------------------
-- One block RAM per instance. For DELAY_DEPTH=16, DATA_WIDTH=16, the actual
-- storage is 256 bits, or about 6% of one 4-kbit iCE40 EBR. Remaining EBR
-- capacity is unused for simplicity (granularity = one EBR per branch).
--
-- Previous version (per branch):  16 FFs * 16 bits = 256 FFs + parent's 16:1 mux
-- This version (per branch):      1 EBR + tiny address arithmetic
--
--   MDT (4 branches):       trades 4 * 256 = 1024 FFs + 4 muxes for 4 EBRs
--                           (4 of 30 EBRs used on iCE40UP5K)
--   Haifuraiya (64 branches): 64 EBRs (well within ZCU102 BRAM budget)
--
-- Net effect on iCE40: significant LUT4 and slice-register reduction (the
-- bottleneck), trading abundant EBR for scarce LUTs.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity delay_line is
    generic (
        -- Number of taps (delay depth)
        -- MDT: 16, Haifuraiya: 24
        DELAY_DEPTH : positive := 16;

        -- Width of each sample (bits)
        DATA_WIDTH  : positive := 16
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;

        -- Write side: insert new sample
        shift_en : in  std_logic;
        data_in  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);

        -- Read side: tap index in, sample out (1-cycle read latency)
        -- tap_idx width is unconstrained; the connecting signal sets it.
        -- The caller is responsible for passing a vector of clog2(DELAY_DEPTH)
        -- bits or wider.
        tap_idx  : in  std_logic_vector;
        tap_out  : out std_logic_vector(DATA_WIDTH - 1 downto 0)
    );
end entity delay_line;

architecture rtl of delay_line is

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
    constant ADDR_WIDTH : positive := clog2(DELAY_DEPTH);

    ---------------------------------------------------------------------------
    -- Storage
    ---------------------------------------------------------------------------
    -- The ring buffer. Canonical pattern for inferring synchronous-read block
    -- RAM on both Lattice LSE (iCE40 EBR) and Xilinx Vivado (BRAM):
    --   - Single clocked process containing both write and registered read.
    --   - No reset on the storage itself.
    --   - Initial value via signal initializer (set in bitstream).
    --
    -- Synthesis attributes below are hints to each toolchain's RAM inference.
    -- LSE looks at syn_ramstyle; Vivado looks at ram_style. They coexist
    -- harmlessly; each tool ignores the attribute meant for the other.
    ---------------------------------------------------------------------------
    type ram_t is array (0 to DELAY_DEPTH - 1) of
        std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    attribute syn_ramstyle : string;
    attribute syn_ramstyle of ram : signal is "block_ram";
    attribute ram_style    : string;
    attribute ram_style    of ram : signal is "block";

    ---------------------------------------------------------------------------
    -- Pointers
    ---------------------------------------------------------------------------
    signal wr_ptr  : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal rd_addr : unsigned(ADDR_WIDTH - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Read address calculation (combinational)
    ---------------------------------------------------------------------------
    -- After a write, wr_ptr has advanced past the newly-written slot. So the
    -- most-recent sample sits at wr_ptr - 1, and the sample N positions older
    -- sits at wr_ptr - 1 - N. Modulo-DELAY_DEPTH is implicit in unsigned
    -- wrap-around for power-of-two depths; for non-power-of-two depths the
    -- caller must use a depth that matches the address width.
    ---------------------------------------------------------------------------
    rd_addr <= wr_ptr - resize(unsigned(tap_idx), ADDR_WIDTH) - 1;

    ---------------------------------------------------------------------------
    -- Block-RAM process: write port + registered read port
    ---------------------------------------------------------------------------
    -- Canonical inference pattern. Both write and read inside one clocked
    -- process. No reset on 'ram'. Read result lands on tap_out one cycle
    -- after rd_addr is presented.
    --
    -- Note on write/read collision: write and read may occur in the same
    -- cycle to the same address only if the MAC reads the slot we're
    -- currently writing. In the polyphase channelizer, the MAC's COMPUTING
    -- pass and the parent's commutator-driven write to this branch are
    -- temporally separated (writes happen during WAIT_SAMPLES, reads happen
    -- during COMPUTING). So the collision case doesn't occur and the RAM's
    -- write-first vs read-first mode doesn't matter.
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if shift_en = '1' then
                ram(to_integer(wr_ptr)) <= data_in;
            end if;
            tap_out <= ram(to_integer(rd_addr));
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Write pointer
    ---------------------------------------------------------------------------
    -- Kept in a separate process so it can have synchronous-reset semantics
    -- without contaminating the RAM-inference pattern above.
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                wr_ptr <= (others => '0');
            elsif shift_en = '1' then
                wr_ptr <= wr_ptr + 1;
            end if;
        end if;
    end process;

end architecture rtl;