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
-- This extracts the LOAD_COEFFS state machine that previously lived inside
-- polyphase_filterbank, so multiple filterbanks can share a single coeff_rom
-- without contending for its address bus.
--
-- The coefficients are stored in flip-flops within this entity, then presented
-- combinationally on branch_coeffs_out (a wide vector packing per-branch
-- coefficient blocks). Consumer entities slice the bus into per-branch coeffs.
--
-- Move #1.5 may later replace the FF storage with sequential block-RAM reads.
-- For now the FF cost is modest: MDT (4 * 16 * 16 bits) = 1024 FFs total.
--
-------------------------------------------------------------------------------
-- FIXME: KNOWN OFF-BY-ONE - LAST COEFFICIENT NEVER LOADED
-------------------------------------------------------------------------------
-- This module reproduces a pre-existing off-by-one from the original
-- polyphase_filterbank LOAD_COEFFS FSM. The address counter advances
-- 0..N*M-1; coeff_load_done is set the same cycle the address reaches N*M-1;
-- but coeff_data for that last address arrives ONE CYCLE LATER (coeff_rom
-- has 1-cycle read latency). The storage process is gated by
-- coeff_load_done='0', so the final coeff_data is never registered.
--
-- For MDT: branch 3 / tap 15 should hold coeff_rom[63] = 0xFF9F (= -97).
-- Currently it holds 0x0000. Filter response asymmetry is small (the missed
-- coefficient has small magnitude relative to the main lobe) so the channel
-- separation still works, but it's wrong.
--
-- Preserved here so the Move #1 -> Option 3 refactor is purely structural
-- (no functional drift, clean bisection). The fix should land as its own
-- commit: keep the address counter intact, but extend the storage-process
-- gate by one cycle past coeff_load_done to capture the final coeff_data.
--
-------------------------------------------------------------------------------
-- TIMING (MDT, N=4, M=16)
-------------------------------------------------------------------------------
-- Cycle 0:    coeff_addr=0 driven. coeff_data not yet valid.
-- Cycle 1:    coeff_addr=1, coeff_data=rom[0]  -> stored at branch 0 / tap 0
-- ...
-- Cycle 63:   coeff_addr=63, coeff_data=rom[62] -> stored at branch 3 / tap 14
-- Cycle 64:   coeff_load_done='1', coeff_data=rom[63] (NOT stored - see FIXME)
-- Cycle 65+:  coeffs_ready='1' (asserted and held)
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
        -- Must equal clog2(N_CHANNELS * TAPS_PER_BRANCH)
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

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type coeff_array_t is array (0 to N_CHANNELS - 1) of
        std_logic_vector(TAPS_PER_BRANCH * COEFF_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal coeff_addr_reg   : unsigned(COEFF_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_branch_idx : unsigned(BRANCH_IDX_WIDTH - 1 downto 0) := (others => '0');
    signal coeff_tap_idx    : unsigned(TAP_IDX_WIDTH - 1 downto 0)    := (others => '0');
    signal coeff_load_done  : std_logic := '0';
    signal coeffs_ready_r   : std_logic := '0';
    signal branch_coeffs    : coeff_array_t := (others => (others => '0'));

begin

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    coeff_addr   <= std_logic_vector(coeff_addr_reg);
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
    -- FIXME: off-by-one drops the final coefficient. See file header for
    -- details and fix sketch. Preserved here for clean Move #1 -> Option 3
    -- regression testing.
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                coeff_addr_reg   <= (others => '0');
                coeff_branch_idx <= (others => '0');
                coeff_tap_idx    <= (others => '0');
                coeff_load_done  <= '0';
                coeffs_ready_r   <= '0';
            elsif coeff_load_done = '0' then
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
    end process;

    ---------------------------------------------------------------------------
    -- Coefficient storage
    ---------------------------------------------------------------------------
    -- coeff_rom returns coeff_data one cycle after the address is presented,
    -- so we use (coeff_addr_reg - 1) to know where the current data belongs.
    -- See the FIXME at the top of this file regarding the missed final value.
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
            elsif coeff_load_done = '0' then
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
