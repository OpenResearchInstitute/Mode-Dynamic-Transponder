-------------------------------------------------------------------------------
-- tb_sync_fill_guard.vhd
-- Unit testbench for the frame-sync HUNTING fill guard
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Opulent Voice receiver (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-------------------------------------------------------------------------------
-- SCOPE
-------------------------------------------------------------------------------
-- Focused unit test of frame_sync_detector_soft, exercising ONE property: the
-- normalised HUNTING correlation must not declare a lock over a partially-filled
-- correlation window.
--
-- frame_sync_detector_soft zeroes its 24-tap soft correlator on the rising edge
-- of demod_sync_lock. The normalised test corr_prev >= (PCT/100)*energy_prev is
-- only meaningful over a FULL window: over a single non-zero tap, corr_prev ==
-- energy_prev and the ratio is trivially 1.0. Without a fill guard HUNTING locks
-- on the first post-clear symbol -- an insta-lock ~34 ms before the real sync
-- word. The C++ golden reference opv_demod.hpp guards this exactly:
--     if (total_symbols_ < SYNC_BITS) break;
--
-- Stimulus after the clear (symbol index since clear):
--   s1      : -TRAP_MAG   one-tap primer (SYNC_WORD(0)='1' expects negative)
--   s2      : +SMALL      2-tap correlation falls -> buggy peak fires here
--   s3..s30 : +/-BENIGN    low energy (< MIN_SYNC_ENERGY); flushes s1/s2 out
--   s31..s54: the 24-symbol sync word, MSB-first, +/-SYNC_MAG per bit
--   s55     : +BENIGN      correlation falls off the true peak -> real lock
--   tail    : +/-BENIGN
--
-- Test 1 : no partial-window lock  (first LOCKED entry, if any, at sym >= 24)
-- Test 2 : real-sync acquisition   (a lock is eventually declared)
--
-- Pass/fail is tallied and reported NOTE/WARNING, with an ALL TESTS PASSED /
-- TESTS FAILED summary, matching the channelizer bench. Keyed on debug_state
-- only, so this one bench binds to the buggy or the fixed RTL unchanged; the
-- fill counter (fill_prev / debug_sync_fill) is observed in the waveform.
--
-- Run from Vivado xsim via run_sync_fill_guard_test.tcl.
-------------------------------------------------------------------------------

library std;
use std.textio.all;
use std.env.all;

library ieee;
use ieee.std_logic_textio.all;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_sync_fill_guard is
    generic (
        -- Clocks the stimulus idles between symbols. The frame sync only cares
        -- about rx_bit_valid pulses, not their spacing; a small value keeps the
        -- run short.
        SYM_GAP : integer := 2
    );
end entity tb_sync_fill_guard;

architecture sim of tb_sync_fill_guard is

    ---------------------------------------------------------------------------
    -- Parameters
    ---------------------------------------------------------------------------
    constant CLK_PERIOD   : time     := 10 ns;    -- 100 MHz
    constant SYNC_WORD_C  : std_logic_vector(23 downto 0) := x"02B8DB";
    constant SYNC_BITS    : integer  := 24;

    -- Soft magnitudes (16-bit signed; operating |soft| ~ 17740 at Eb/N0 = 8 dB)
    constant TRAP_MAG     : integer := 20000;  -- one-tap primer, clears MIN_ENERGY
    constant SMALL_MAG    : integer :=   100;  -- makes 2-tap corr fall below 1-tap
    constant BENIGN_MAG   : integer :=   300;  -- 24*300 = 7200 < MIN_SYNC_ENERGY
    constant SYNC_MAG     : integer := 20000;  -- real sync-word symbol level

    constant LOCKED_STATE : std_logic_vector(2 downto 0) := "010";

    ---------------------------------------------------------------------------
    -- Pass/fail tally
    ---------------------------------------------------------------------------
    shared variable tests_pass : integer := 0;
    shared variable tests_fail : integer := 0;

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal clk               : std_logic := '0';
    signal running           : std_logic := '1';

    signal reset             : std_logic := '1';
    signal rx_bit            : std_logic := '0';
    signal rx_bit_valid      : std_logic := '0';
    signal s_axis_soft_tdata : signed(15 downto 0) := (others => '0');

    signal m_axis_tdata      : std_logic_vector(7 downto 0);
    signal m_axis_tvalid     : std_logic;
    signal m_axis_tready      : std_logic := '1';
    signal m_axis_tlast      : std_logic;

    signal m_axis_soft_bit_tdata  : std_logic_vector(2 downto 0);
    signal m_axis_soft_bit_tvalid : std_logic;
    signal m_axis_soft_bit_tready : std_logic := '1';
    signal m_axis_soft_bit_tlast  : std_logic;

    signal frame_sync_locked     : std_logic;
    signal frames_received       : std_logic_vector(31 downto 0);
    signal frame_sync_errors     : std_logic_vector(31 downto 0);
    signal frame_buffer_overflow : std_logic;

    signal demod_sync_lock     : std_logic := '0';
    signal hunting_threshold_i : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(85, 32));
    signal locked_threshold_i  : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(70, 32));

    signal quant_thr_1_i : std_logic_vector(15 downto 0) := std_logic_vector(to_signed(500, 16));
    signal quant_thr_2_i : std_logic_vector(15 downto 0) := std_logic_vector(to_signed(1400, 16));
    signal quant_thr_3_i : std_logic_vector(15 downto 0) := std_logic_vector(to_signed(2800, 16));

    signal debug_state          : std_logic_vector(2 downto 0);
    signal debug_correlation    : signed(31 downto 0);
    signal debug_corr_peak      : signed(31 downto 0);
    signal debug_bit_count      : std_logic_vector(31 downto 0);
    signal debug_missed_syncs   : std_logic_vector(3 downto 0);
    signal debug_consecutive_good : std_logic_vector(3 downto 0);
    signal debug_soft_current   : signed(15 downto 0);
    signal debug_soft_quantized : std_logic_vector(2 downto 0);
    signal debug_byte_v         : std_logic_vector(7 downto 0);

    ---------------------------------------------------------------------------
    -- Observation
    ---------------------------------------------------------------------------
    signal sym_since_clear : integer := 0;   -- symbols fed since the clear event
    signal first_lock_sym  : integer := -1;  -- sym index of first LOCKED entry

begin

    ---------------------------------------------------------------------------
    -- Clock
    ---------------------------------------------------------------------------
    p_clk : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    ---------------------------------------------------------------------------
    -- DUT. debug_sync_fill (fixed RTL only) is intentionally left OPEN so this
    -- port map binds to the buggy or the fixed entity without edits. The fill
    -- count is observed in the waveform via the internal fill_prev signal.
    ---------------------------------------------------------------------------
    u_fsync : entity work.frame_sync_detector_soft
        generic map (
            SYNC_WORD     => SYNC_WORD_C,
            PAYLOAD_BYTES => 268
        )
        port map (
            clk               => clk,
            reset             => reset,
            rx_bit            => rx_bit,
            rx_bit_valid      => rx_bit_valid,
            s_axis_soft_tdata => s_axis_soft_tdata,
            m_axis_tdata      => m_axis_tdata,
            m_axis_tvalid     => m_axis_tvalid,
            m_axis_tready     => m_axis_tready,
            m_axis_tlast      => m_axis_tlast,
            m_axis_soft_bit_tdata  => m_axis_soft_bit_tdata,
            m_axis_soft_bit_tvalid => m_axis_soft_bit_tvalid,
            m_axis_soft_bit_tready => m_axis_soft_bit_tready,
            m_axis_soft_bit_tlast  => m_axis_soft_bit_tlast,
            frame_sync_locked     => frame_sync_locked,
            frames_received       => frames_received,
            frame_sync_errors     => frame_sync_errors,
            frame_buffer_overflow => frame_buffer_overflow,
            demod_sync_lock       => demod_sync_lock,
            hunting_threshold_i   => hunting_threshold_i,
            locked_threshold_i    => locked_threshold_i,
            quant_thr_1_i         => quant_thr_1_i,
            quant_thr_2_i         => quant_thr_2_i,
            quant_thr_3_i         => quant_thr_3_i,
            debug_state           => debug_state,
            debug_correlation     => debug_correlation,
            debug_corr_peak       => debug_corr_peak,
            debug_bit_count       => debug_bit_count,
            debug_missed_syncs    => debug_missed_syncs,
            debug_consecutive_good => debug_consecutive_good,
            debug_soft_current    => debug_soft_current,
            debug_soft_quantized  => debug_soft_quantized,
            debug_byte_v          => debug_byte_v
        );

    ---------------------------------------------------------------------------
    -- Capture the first entry into LOCKED and the symbol index it happened at.
    ---------------------------------------------------------------------------
    p_watch : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' and debug_state = LOCKED_STATE and first_lock_sym < 0 then
                first_lock_sym <= sym_since_clear;
                report "LOCKED first observed at sym_since_clear = "
                     & integer'image(sym_since_clear) severity note;
            end if;
        end if;
    end process p_watch;

    ---------------------------------------------------------------------------
    -- Stimulus + checks
    ---------------------------------------------------------------------------
    p_stim : process

        -- Feed one symbol: hold soft/rx_bit, pulse rx_bit_valid one clock, then
        -- idle SYM_GAP clocks so the 3-stage input pipeline settles.
        procedure feed_symbol(constant soft_val : in integer) is
        begin
            s_axis_soft_tdata <= to_signed(soft_val, 16);
            if soft_val < 0 then rx_bit <= '1'; else rx_bit <= '0'; end if;
            rx_bit_valid <= '1';
            wait until rising_edge(clk);
            rx_bit_valid <= '0';
            sym_since_clear <= sym_since_clear + 1;
            for i in 1 to SYM_GAP loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure pass(constant msg : in string) is
        begin
            tests_pass := tests_pass + 1;
            report "PASS: " & msg severity note;
        end procedure;

        procedure fail(constant msg : in string) is
        begin
            tests_fail := tests_fail + 1;
            report "FAIL: " & msg severity warning;
        end procedure;

        variable bit_val : std_logic;
        variable mag     : integer;
    begin
        report "================================================";
        report "Frame-Sync Fill-Guard Unit Test";
        report "================================================";

        -- Reset
        reset <= '1';
        demod_sync_lock <= '0';
        wait for 5 * CLK_PERIOD;
        wait until rising_edge(clk);
        reset <= '0';
        wait for 5 * CLK_PERIOD;

        -- Clear event: rising edge of demod_sync_lock zeroes soft_sr.
        wait until rising_edge(clk);
        demod_sync_lock <= '1';
        sym_since_clear <= 0;
        wait for 4 * CLK_PERIOD;         -- let demod_sync_lock_d arm HUNTING
        report "MILESTONE 1: demod_sync_lock asserted; correlator cleared" severity note;

        -- s1..s2: the partial-window trap that fires the unguarded peak detector.
        feed_symbol(-TRAP_MAG);
        feed_symbol(+SMALL_MAG);

        -- s3..s30: benign low-energy fill (flushes the trap out; cannot lock).
        for k in 3 to 30 loop
            if (k mod 2) = 0 then feed_symbol(+BENIGN_MAG);
            else                  feed_symbol(-BENIGN_MAG); end if;
        end loop;

        -- s31..s54: the real 24-symbol sync word, MSB-first (SYNC_WORD(23) first).
        -- bit '1' -> negative soft, bit '0' -> positive soft.
        for k in 0 to SYNC_BITS - 1 loop
            bit_val := SYNC_WORD_C(23 - k);
            if bit_val = '1' then mag := -SYNC_MAG; else mag := +SYNC_MAG; end if;
            feed_symbol(mag);
        end loop;

        -- s55: benign, so correlation falls off the true peak and the peak
        -- detector (corr_v <= corr_prev) fires on the aligned window.
        feed_symbol(+BENIGN_MAG);
        for k in 56 to 70 loop
            if (k mod 2) = 0 then feed_symbol(+BENIGN_MAG);
            else                  feed_symbol(-BENIGN_MAG); end if;
        end loop;
        report "MILESTONE 2: stimulus complete; first_lock_sym = "
             & integer'image(first_lock_sym) severity note;

        wait for 20 * CLK_PERIOD;

        ---------------------------------------------------------------------
        -- Test 1: no lock on a partial (< SYNC_BITS) window
        ---------------------------------------------------------------------
        report "--- Test 1: no partial-window lock ---";
        if first_lock_sym >= 0 and first_lock_sym < SYNC_BITS then
            fail("HUNTING locked on a partial window at sym "
                 & integer'image(first_lock_sym) & " (< " & integer'image(SYNC_BITS) & ")");
        else
            pass("no partial-window lock");
        end if;

        ---------------------------------------------------------------------
        -- Test 2: acquisition on the real sync word
        ---------------------------------------------------------------------
        report "--- Test 2: real-sync acquisition ---";
        if first_lock_sym >= SYNC_BITS then
            pass("acquired on the real sync word at sym " & integer'image(first_lock_sym));
        else
            fail("did not acquire on the real sync word (first_lock_sym = "
                 & integer'image(first_lock_sym) & ")");
        end if;

        ---------------------------------------------------------------------
        -- Summary
        ---------------------------------------------------------------------
        report "================================================";
        report "Frame-Sync Fill-Guard Unit Test COMPLETE";
        report "  PASS: " & integer'image(tests_pass);
        report "  FAIL: " & integer'image(tests_fail);
        report "================================================";

        if tests_fail = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "TESTS FAILED: " & integer'image(tests_fail) severity error;
        end if;

        running <= '0';
        wait for 5 * CLK_PERIOD;
        finish;
    end process p_stim;

end architecture sim;
