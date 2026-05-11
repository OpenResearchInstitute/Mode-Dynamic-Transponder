-------------------------------------------------------------------------------
-- coeff_loader.vhd
-- Coefficient Loader for Polyphase Channelizer
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT / Haifuraiya)
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- Reads filter coefficients from coeff_rom at startup and presents them as
-- a single wide combinational bus for one or more consumer entities (e.g.,
-- multiple polyphase_filterbank instances in an I/Q channelizer).
--
-- The coefficients are stored in flip-flops within this entity, then presented
-- combinationally on branch_coeffs_out (a wide vector packing per-branch
-- coefficient blocks). Consumer entities slice the bus into per-branch coeffs.
--
-- Move #1.5 may later replace the FF storage with sequential block-RAM reads.
-- For now the FF cost is modest: MDT (4 * 16 * 16 bits) = 1024 FFs total.
--
-------------------------------------------------------------------------------
-- TIMING (MDT: N_CHANNELS=4, TAPS_PER_BRANCH=16, TOTAL_COEFFS=64)
-------------------------------------------------------------------------------
-- Cycle 0:    coeff_addr=0 driven. coeff_data not yet valid.
-- Cycle 1:    coeff_addr=1, coeff_data=rom[0]  -> stored at branch 0 / tap 0
-- ...
-- Cycle 63:   coeff_addr=63, coeff_data=rom[62] -> stored at branch 3 / tap 14
--             coeff_load_done set to '1' this cycle (last branch/tap saturated)
-- Cycle 64:   coeff_addr (output) wraps to 0; coeff_addr_reg (internal) holds 64.
--             coeff_data=rom[63] -> stored at branch 3 / tap 15.
--             This is the final write; coeff_load_done_d goes high at the
--             end of this cycle, closing the storage gate.
-- Cycle 65+:  coeffs_ready='1' (asserted and held). No further writes.
--
-------------------------------------------------------------------------------
-- DESIGN NOTES
-------------------------------------------------------------------------------
-- Two details that earned their own attention:
--
--   1) The internal address counter coeff_addr_reg is ONE BIT WIDER than
--      the COEFF_ADDR_WIDTH port to the ROM. The ROM's addr port gets the
--      low COEFF_ADDR_WIDTH bits. The extra bit lets the counter advance
--      cleanly to TOTAL_COEFFS without wrapping (which would happen when
--      TOTAL_COEFFS is a power of 2, such as MDT's 64). This is necessary
--      so the storage process can still index correctly on the final cycle
--      via (coeff_addr_reg - 1).
--
--   2) The storage process is gated by coeff_load_done_d, a 1-cycle-delayed
--      copy of coeff_load_done, NOT by coeff_load_done itself. The reason:
--      ROM has a 1-cycle read latency, so coeff_data for the last address
--      arrives the cycle AFTER coeff_load_done goes high. Gating storage
--      on the delayed signal gives the storage process exactly one extra
--      cycle to capture that final value before closing down.
--
-- Earlier versions of this module (pre-fix) gated storage on coeff_load_done
-- directly, which dropped the final coefficient (branch N-1 / tap M-1).
-- For MDT that meant branch 3 / tap 15 stayed at 0 instead of rom[63]=-97.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity coeff_loader is
    generic (
        N_CHANNELS       : positive := 4;
        TAPS_PER_BRANCH  : positive := 16;
        COEFF_WIDTH      : positive := 16;
        -- Must equal clog2(N_CHANNELS * TAPS_PER_BRANCH).
        -- The internal counter is one bit wider than this (see design notes).
        COEFF_ADDR_WIDTH : positive := 6
    );
    port (
        clk    : in  std_logic;
        reset  : in  std_logic;

        -- Master-side interface to coeff_rom
        coeff_addr : out std_logic_vector(COEFF_ADDR_WIDTH - 1 downto 0);
        coeff_data : in  std_logic_vector(COEFF_WIDTH - 1 downto 0);

        -- Wide coefficient bus for consumer filterbank(s).
        -- Layout: branch 0 in LSBs, branch N-1 in MSBs.
        -- Within each branch: tap 0 in LSBs, tap M-1 in MSBs.
        -- This matches the existing fir_branch.coeffs packing.
        branch_coeffs_out : out std_logic_vector(
            N_CHANNELS * TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);

        -- Asserts (and stays asserted) once loading is complete.
        coeffs_ready      : out std_logic
    );
end entity coeff_loader;

architecture rtl of coeff_loader is

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
    constant BRANCH_IDX_WIDTH : positive := clog2(N_CHANNELS);
    constant TAP_IDX_WIDTH    : positive := clog2(TAPS_PER_BRANCH);
    -- Internal counter width: one wider than ROM addr so we can count to
    -- TOTAL_COEFFS without wrapping. See design notes in file header.
    constant ADDR_REG_WIDTH   : positive := COEFF_ADDR_WIDTH + 1;

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type coeff_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal coeff_addr_reg    : unsigned(ADDR_REG_WIDTH - 1 downto 0)  := (others => '0');
    signal coeff_branch_idx  : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_tap_idx     : unsigned(TAP_IDX_WIDTH - 1 downto 0)    := (others => '0');
    signal coeff_load_done   : std_logic := '0';
    signal coeff_load_done_d : std_logic := '0';  -- 1-cycle delayed; gates storage
    signal coeffs_ready_r    : std_logic := '0';
    signal branch_coeffs     : coeff_array_t := (others => (others => '0'));

begin

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    -- Drive only the low bits to the ROM; the extra MSB is for internal use.
    coeff_addr   <= std_logic_vector(coeff_addr_reg(COEFF_ADDR_WIDTH - 1 downto 0));
    coeffs_ready <= coeffs_ready_r;

    -- Pack the per-branch array into the wide output bus.
    gen_pack : for i in 0 to N_CHANNELS - 1 generate
        branch_coeffs_out(
            (i + 1) * TAPS_PER_BRANCH * COEFF_WIDTH - 1
            downto i * TAPS_PER_BRANCH * COEFF_WIDTH
        ) <= branch_coeffs(i);
    end generate gen_pack;

    ---------------------------------------------------------------------------
    -- LOAD_COEFFS state machine
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                coeff_addr_reg    <= (others => '0');
                coeff_branch_idx  <= (others => '0');
                coeff_tap_idx     <= (others => '0');
                coeff_load_done   <= '0';
                coeff_load_done_d <= '0';
                coeffs_ready_r    <= '0';
            else
                -- One-cycle-delayed copy of coeff_load_done. Used by the
                -- storage process below as its gate, so the final coeff_data
                -- (which arrives the cycle after coeff_load_done goes high)
                -- still gets captured.
                coeff_load_done_d <= coeff_load_done;

                if coeff_load_done = '0' then
                    coeff_addr_reg <= coeff_addr_reg + 1;

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
                    -- Loading complete; latch ready high and hold.
                    coeffs_ready_r <= '1';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Coefficient storage
    ---------------------------------------------------------------------------
    -- ROM returns coeff_data one cycle after the address is presented, so we
    -- index with (coeff_addr_reg - 1). Gating on coeff_load_done_d (rather
    -- than coeff_load_done) keeps the storage process active for one extra
    -- cycle past the FSM completion, capturing the final coefficient.
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
            elsif coeff_load_done_d = '0' then
                if coeff_addr_reg > 0 then
                    branch_idx := to_integer(coeff_addr_reg - 1) / TAPS_PER_BRANCH;
                    tap_idx    := to_integer(coeff_addr_reg - 1) mod TAPS_PER_BRANCH;

                    branch_coeffs(branch_idx)(
                        (tap_idx + 1) * COEFF_WIDTH - 1
                        downto tap_idx * COEFF_WIDTH
                    ) <= coeff_data;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;