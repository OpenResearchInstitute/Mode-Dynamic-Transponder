------------------------------------------------------------------------------------------------------
-- esi_loop_pkg -- how a 32-bit I/Q sample rides an ESIstream lane in the tier-2 digital loopback
------------------------------------------------------------------------------------------------------
-- Tier 2 (see ESISTREAM_NOTES.md §4) splices the ESIstream serial link into the
-- memory-loopback sample path:  DDR -> DMA -> pacer -> [packer -> TX -> link ->
-- RX -> reassembler] -> receiver.  Both ends of the link are ours, so the frame
-- payload layout is ours.  It is a TEST FIXTURE: lossless 16-bit I and Q, a
-- valid flag, a fixed marker, and a sequence number, so that a lane-order or
-- alignment fault scrambles the sample order and shows up as a counted error
-- (and as a failed grade), not as silent noise.  The ADC's own 12-bit frame
-- format (tier 3) is a different layout handled by the downconverter, not by
-- anything in this file.
--
-- One lane carries DESER_WIDTH/16 = 4 ESIstream frames of 14 payload bits per
-- frame clock, i.e. one 56-bit "slot" per lane per clock.  Layout (frame k =
-- data(k), bit 13 = MSB of each 14-bit frame):
--
--   frame 0 : [13] VALID  [12:0]  I[15:3]
--   frame 1 : [13:11] I[2:0]      [10:0] Q[15:5]
--   frame 2 : [13:9]  Q[4:0]      [8:0]  MARKER (0x155 = 1 0101 0101)
--   frame 3 : [13:0]  SEQ (14-bit sequence number, wraps)
--
-- An idle slot is all zeros (VALID = 0).  The packer emits at most ONE sample
-- per frame clock, rotating over the lanes (sample n on lane n mod NB_LANES);
-- the reassembler therefore expects at most one VALID slot per clock and
-- counts any clock with two or more as an error.
--
-- Public-domain Teledyne e2v ESIstream IP provides tx_esistream/rx_esistream
-- (haifuraiya/third_party/esistream_vck190/); this package only defines the
-- slot encoding on top of their 14-bit data arrays (esistream_pkg types).
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.esistream_pkg.all;

package esi_loop_pkg is

    constant ESI_MARKER   : std_logic_vector(8 downto 0) := "101010101";   -- 0x155
    constant ESI_SEQ_BITS : natural := 14;

    -- one lane's worth of frames for one clock (4 x 14 bits with DESER_WIDTH = 64)
    subtype esi_slot_t is slv_14_array_n(DESER_WIDTH/16 - 1 downto 0);

    function esi_idle_slot return esi_slot_t;

    function esi_pack_slot(i_val : std_logic_vector(15 downto 0);
                           q_val : std_logic_vector(15 downto 0);
                           seq   : unsigned(ESI_SEQ_BITS-1 downto 0)) return esi_slot_t;

    function esi_slot_valid (s : esi_slot_t) return std_logic;
    function esi_slot_i     (s : esi_slot_t) return std_logic_vector;   -- 16 bits
    function esi_slot_q     (s : esi_slot_t) return std_logic_vector;   -- 16 bits
    function esi_slot_seq   (s : esi_slot_t) return unsigned;           -- ESI_SEQ_BITS
    function esi_slot_marker_ok (s : esi_slot_t) return std_logic;

end package esi_loop_pkg;

package body esi_loop_pkg is

    function esi_idle_slot return esi_slot_t is
        variable s : esi_slot_t;
    begin
        for k in s'range loop
            s(k) := (others => '0');
        end loop;
        return s;
    end function;

    function esi_pack_slot(i_val : std_logic_vector(15 downto 0);
                           q_val : std_logic_vector(15 downto 0);
                           seq   : unsigned(ESI_SEQ_BITS-1 downto 0)) return esi_slot_t is
        variable s : esi_slot_t := esi_idle_slot;
    begin
        s(0) := '1' & i_val(15 downto 3);
        s(1) := i_val(2 downto 0) & q_val(15 downto 5);
        s(2) := q_val(4 downto 0) & ESI_MARKER;
        s(3) := std_logic_vector(seq);
        return s;
    end function;

    function esi_slot_valid (s : esi_slot_t) return std_logic is
    begin
        return s(0)(13);
    end function;

    function esi_slot_i (s : esi_slot_t) return std_logic_vector is
    begin
        return s(0)(12 downto 0) & s(1)(13 downto 11);
    end function;

    function esi_slot_q (s : esi_slot_t) return std_logic_vector is
    begin
        return s(1)(10 downto 0) & s(2)(13 downto 9);
    end function;

    function esi_slot_seq (s : esi_slot_t) return unsigned is
    begin
        return unsigned(s(3));
    end function;

    function esi_slot_marker_ok (s : esi_slot_t) return std_logic is
    begin
        if s(2)(8 downto 0) = ESI_MARKER then
            return '1';
        else
            return '0';
        end if;
    end function;

end package body esi_loop_pkg;
