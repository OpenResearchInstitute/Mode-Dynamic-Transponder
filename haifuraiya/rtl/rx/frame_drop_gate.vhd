----------------------------------------------------------------------------
-- frame_drop_gate.vhd -- whole-frame drop policy in front of a standard
-- backpressure FIFO. THE WEDGE CURE, part 1 of 2.
-- (Part 2 is axis_async_fifo.vhd from pluto_msk, reused as proven storage;
--  see docs/WP_SOFTBIT_DROP_FIFO.md.)
--
-- Governing principle: THE DEMODULATOR NEVER SEES DOWNSTREAM TREADY.
-- This gate has no upstream tready. It accepts every beat the frame_sync
-- detector emits. Its only decision, made once per frame at the FIRST
-- beat: pass this whole frame into the FIFO, or swallow it whole.
--
-- Why decide-at-start is safe: the FIFO's prog_full contract (pluto_msk
-- axis_async_fifo, header line 72) asserts when remaining space < one
-- frame (PROG_FULL_THRESHOLD = FRAME_SIZE). prog_full LOW at frame start
-- therefore guarantees the entire frame fits; the reader can only FREE
-- space during the fill, never consume write space. No rewind, no
-- partial frames, ever. Downstream opv-decode -3 has no resync: frame
-- alignment outranks everything.
--
-- The gate trusts the detector to emit well-formed 2144-beat frames
-- (sim-proven, seam-gated). A beat counter re-arms frame-start detection
-- if tlast ever goes missing, so one malformed frame cannot poison the
-- gate's framing forever.
--
-- Witnesses (wire to demod regs; Bouro displays):
--   dropped_count : frames swallowed (monotonic)
--   ovf_sticky    : any swallow since stats_clear (SOFT_OVF_EVENT)
--
-- Field evidence this answers: measured ~1-frame elastic slack; any
-- unposted-DMA window froze the whole demod until DEMOD_INIT (bench
-- 2026-07-21..27, reproducible on demand). After this gate + FIFO, a
-- dead consumer costs counted payload, never lock.
----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity frame_drop_gate is
  generic (
    G_FRAME_BEATS : positive := 2144
  );
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- from frame_sync_detector_soft m_axis_soft_bit: no tready exists
    s_tdata       : in  std_logic_vector(2 downto 0);
    s_tvalid      : in  std_logic;
    s_tlast       : in  std_logic;
    -- to axis_async_fifo s_axis (its tready ignored by design; see note)
    m_tdata       : out std_logic_vector(2 downto 0);
    m_tvalid      : out std_logic;
    m_tlast       : out std_logic;
    -- from the FIFO
    prog_full     : in  std_logic;
    fifo_tready   : in  std_logic;   -- monitored only: violation witness
    -- witnesses
    dropped_count : out unsigned(31 downto 0);
    ovf_sticky    : out std_logic;
    tready_viol   : out std_logic;   -- sticky: invariant breach (never expected)
    stats_clear   : in  std_logic
  );
end entity;

architecture rtl of frame_drop_gate is
  signal in_frame : std_logic := '0';
  signal dropping : std_logic := '0';
  signal beat     : unsigned(15 downto 0) := (others => '0');
  signal drops    : unsigned(31 downto 0) := (others => '0');
  signal sticky   : std_logic := '0';
  signal viol     : std_logic := '0';
begin
  -- combinational pass-through when not dropping: zero added latency,
  -- decision resolves on the same first beat it gates.
  m_tdata  <= s_tdata;
  m_tlast  <= s_tlast;
  m_tvalid <= s_tvalid and not (dropping or (not in_frame and prog_full));

  dropped_count <= drops;
  ovf_sticky    <= sticky;
  tready_viol   <= viol;

  process(clk)
    variable drop_this : std_logic;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        in_frame <= '0'; dropping <= '0';
        beat <= (others => '0');
        drops <= (others => '0'); sticky <= '0'; viol <= '0';
      else
        if s_tvalid = '1' then
          -- frame-start decision (registered mirror of the comb gate above)
          if in_frame = '0' then
            drop_this := prog_full;
            dropping  <= drop_this;
            in_frame  <= '1';
          else
            drop_this := dropping;
          end if;

          -- invariant monitor: we only ever present beats when a full
          -- frame was guaranteed; the FIFO refusing one is a design bug.
          if (drop_this = '0') and (fifo_tready = '0') then
            viol <= '1';
          end if;

          -- frame bookkeeping
          if (s_tlast = '1') or (beat = G_FRAME_BEATS-1) then
            if drop_this = '1' then
              drops  <= drops + 1;
              sticky <= '1';
            end if;
            in_frame <= '0';
            dropping <= '0';
            beat     <= (others => '0');
          else
            beat <= beat + 1;
          end if;
        end if;

        if stats_clear = '1' then
          sticky <= '0'; viol <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
