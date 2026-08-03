-- elastic_channel_store.vhd
-- Open Research Institute / Haifuraiya -- CERN-OHL-W
--
-- THE SAMPLE STORE OF RECORD (2026-08-03). One module, both eras:
-- bring-up (one channel lit) and the documented 64-channel time-shared
-- scale-up (SOW_demod_1_to_64_channels.md) use THIS geometry. Nothing
-- here is scaffolding; N=1 is the 64-channel design with one lane lit.
--
-- LAW (the invariant this module exists to enforce):
--   No sample the demod has not yet consumed is ever overwritten
--   silently. Elasticity is deep enough that the walls are unreachable
--   in normal operation; any approach to a wall is a COUNTED, sticky,
--   readable fault -- never corruption that decodes as plausible data.
--
-- STRUCTURE:
--   BRAM store : 2**(G_CH_AW+G_DEPTH_AW) x 32, simple dual port,
--                registered read (infers block RAM). Channel index in
--                the upper address bits; per-channel regions of
--                2**G_DEPTH_AW samples; per-channel write pointers.
--                The writer is REAL TIME and never stalls.
--   Window     : 2**G_WIN_AW x 32 LUTRAM, asynchronous read -- the
--                engine's verified same-cycle two-tap interpolated
--                fetch reads THIS, addressed by absolute sample index
--                mod window size, exactly as it read the old ring.
--   Filler     : walks the BRAM region copying samples into the window
--                ahead of the reader: keeps [reader_pos, reader_pos+
--                C_FILL_AHEAD) resident. Two clocks per sample
--                (issue/capture), far exceeding one channel's 625 kHz;
--                the scale-up interleave pipelines this to 1/clock and
--                swaps fill state per channel tag alongside all other
--                per-channel state (the SOW's channel-indexed RAM
--                pattern).
--
-- ELASTICITY (what prevents the stomp): the distance the writer may
-- run ahead of the reader is the per-channel region depth (default
-- 2**10 = 1024 samples = 1.64 ms), not a fetch-window dimension. At
-- the measured lead wander (~6 samples/s) a wall is >2 minutes of
-- SUSTAINED one-way drift away; under zero-mean wander, unreachable.
--
-- FAULTS (both sticky until init):
--   starve_sticky : hold was asserted outside reset -- the reader
--                   caught the writer (dead air / TX stop). Benign
--                   when stimulus stops; a bug if it fires mid-signal.
--   stomp_sticky  : writer lapped the reader's UNREAD data in BRAM
--                   (occupancy > region depth). The old silent-
--                   corruption case, now detected and counted. The
--                   deliberate forward re-anchor response is queued
--                   (needs an engine pos-load port); until then the
--                   flag is the tripwire that the 2040-wall class of
--                   failure can never again occur without a witness.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity elastic_channel_store is
  generic (
    G_CH_AW    : natural := 6;    -- 2**6 = 64 channels (design of record)
    G_DEPTH_AW : natural := 10;   -- 2**10 = 1024 samples per channel
    G_WIN_AW   : natural := 6     -- 2**6 = 64-slot fetch window (as ever)
  );
  port (
    clk        : in  std_logic;
    init       : in  std_logic;

    -- writer side (real-time, never stalled)
    wr_ch      : in  unsigned(G_CH_AW-1 downto 0);
    wr_valid   : in  std_logic;
    wr_data    : in  std_logic_vector(31 downto 0);

    -- reader side (one engine; scale-up time-shares by swapping rd_ch
    -- plus filler state per the SOW's channel-indexed pattern)
    rd_ch      : in  unsigned(G_CH_AW-1 downto 0);
    reader_pos : in  unsigned(23 downto 0);  -- engine e_pos(39:16), absolute
    hold       : out std_logic;              -- window not yet valid at pos

    -- engine fetch (the verified combinational two-tap contract)
    win_addr   : in  unsigned(23 downto 0);  -- absolute sample index
    win_data0  : out std_logic_vector(31 downto 0);  -- [addr]
    win_data1  : out std_logic_vector(31 downto 0);  -- [addr+1]

    -- telemetry + faults
    occupancy     : out unsigned(23 downto 0);  -- wr_ptr(rd_ch) - reader_pos
    starve_sticky : out std_logic;
    stomp_sticky  : out std_logic
  );
end entity;

architecture rtl of elastic_channel_store is

  constant C_DEPTH      : natural := 2**G_DEPTH_AW;
  constant C_WIN        : natural := 2**G_WIN_AW;
  -- window residency target ahead of the reader. Engine touches
  -- [pos, pos+17] (16-wide correlation window + the +1 interp tap);
  -- 48 ahead leaves 16 slots of lap margin inside the window.
  constant C_FILL_AHEAD : natural := 48;
  constant C_NEED       : natural := 18;   -- pos..pos+17 must be resident

  -- BRAM store: registered read -> block RAM inference
  type store_t is array (0 to 2**(G_CH_AW+G_DEPTH_AW)-1)
    of std_logic_vector(31 downto 0);
  signal store : store_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of store : signal is "block";
  signal store_rdata : std_logic_vector(31 downto 0);
  signal store_raddr : unsigned(G_CH_AW+G_DEPTH_AW-1 downto 0);

  -- per-channel write pointers (absolute 24-bit sample indices)
  type wptr_t is array (0 to 2**G_CH_AW-1) of unsigned(23 downto 0);
  signal wr_ptr : wptr_t := (others => (others => '0'));
  signal wr_ptr_rd : unsigned(23 downto 0);   -- wr_ptr(rd_ch), registered view

  -- fetch window: LUTRAM, async read (the engine's same-cycle contract)
  type win_t is array (0 to C_WIN-1) of std_logic_vector(31 downto 0);
  signal window : win_t := (others => (others => '0'));
  attribute ram_style of window : signal is "distributed";

  -- filler state
  signal fill_ptr  : unsigned(23 downto 0) := (others => '0');
  signal fill_pend : std_logic := '0';        -- issue/capture toggle
  signal fill_addr_q : unsigned(G_WIN_AW-1 downto 0);

  signal fill_lead : unsigned(23 downto 0);   -- fill_ptr - reader_pos
  signal occ       : unsigned(23 downto 0);   -- wr_ptr_rd - reader_pos
  signal hold_i    : std_logic;
  signal starve_r  : std_logic := '0';
  signal stomp_r   : std_logic := '0';
  signal armed_r   : std_logic := '0';  -- set once primed; boot-time hold
                                        -- is lawful and must not count
  signal primed_r  : std_logic := '0';  -- PRIMING (caught by the law tb):
                                        -- releasing on mere window
                                        -- residency starts the reader at
                                        -- ~18 samples occupancy -- floor-
                                        -- skating, the tiny-buffer disease
                                        -- reborn at boot. Hold instead
                                        -- until the store holds DEPTH/2
                                        -- (0.82 ms once), then run mid-
                                        -- region where wander reaches
                                        -- neither wall.

begin

  ------------------------------------------------------------------
  -- writer: real time, never stalled, per-channel region + pointer
  ------------------------------------------------------------------
  writer : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        wr_ptr <= (others => (others => '0'));
      elsif wr_valid = '1' then
        store(to_integer(wr_ch &
              wr_ptr(to_integer(wr_ch))(G_DEPTH_AW-1 downto 0)))
          <= wr_data;
        wr_ptr(to_integer(wr_ch)) <= wr_ptr(to_integer(wr_ch)) + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- BRAM read port: registered (block-RAM timing), address from filler
  ------------------------------------------------------------------
  store_rd : process(clk)
  begin
    if rising_edge(clk) then
      store_rdata <= store(to_integer(store_raddr));
      wr_ptr_rd   <= wr_ptr(to_integer(rd_ch));
    end if;
  end process;
  store_raddr <= rd_ch & fill_ptr(G_DEPTH_AW-1 downto 0);

  ------------------------------------------------------------------
  -- filler: keep window[pos .. pos+C_FILL_AHEAD) resident.
  -- Two-cycle issue/capture; mod-2^24 arithmetic throughout, with the
  -- MSB-as-sign guard (same wrap discipline as the retired ring).
  ------------------------------------------------------------------
  fill_lead <= fill_ptr - reader_pos;

  filler : process(clk)
    variable want : std_logic;
    variable have : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      if init = '1' then
        fill_ptr  <= (others => '0');
        fill_pend <= '0';
      else
        -- want: fill_ptr has not reached pos + C_FILL_AHEAD
        --       (true also at startup, when fill_ptr trails pos)
        if (fill_lead(23) = '1') or
           (fill_lead < to_unsigned(C_FILL_AHEAD, 24)) then
          want := '1';
        else
          want := '0';
        end if;
        -- have: the writer has produced sample fill_ptr
        have := wr_ptr_rd - fill_ptr;
        if fill_pend = '0' then
          if want = '1' and have /= 0 and have(23) = '0' then
            -- issue: store_raddr is combinational from fill_ptr;
            -- data arrives next cycle. Latch the window slot now.
            fill_addr_q <= fill_ptr(G_WIN_AW-1 downto 0);
            fill_pend   <= '1';
          end if;
        else
          -- capture
          window(to_integer(fill_addr_q)) <= store_rdata;
          fill_ptr  <= fill_ptr + 1;
          fill_pend <= '0';
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- engine fetch: async LUTRAM, absolute index mod window size --
  -- byte-for-byte the retired ring's addressing contract
  ------------------------------------------------------------------
  win_data0 <= window(to_integer(win_addr(G_WIN_AW-1 downto 0)));
  win_data1 <= window(to_integer(win_addr(G_WIN_AW-1 downto 0) + 1));

  ------------------------------------------------------------------
  -- hold: engine's needed span [pos, pos+C_NEED) not yet resident
  ------------------------------------------------------------------
  hold_i <= '1' when primed_r = '0' else
            '1' when (fill_lead(23) = '1') or
                     (fill_lead < to_unsigned(C_NEED, 24)) else '0';
  hold <= hold_i;

  priming : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        primed_r <= '0';
      elsif occ(23) = '0' and occ >= to_unsigned(C_DEPTH/2, 24) then
        primed_r <= '1';
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- telemetry + faults
  ------------------------------------------------------------------
  occ <= wr_ptr_rd - reader_pos;
  occupancy <= occ;

  faults : process(clk)
  begin
    if rising_edge(clk) then
      if init = '1' then
        starve_r <= '0';
        stomp_r  <= '0';
        armed_r  <= '0';
      else
        if hold_i = '0' then
          armed_r <= '1';
        elsif armed_r = '1' then
          starve_r <= '1';
        end if;
        -- writer lapped unread data: occupancy exceeds the region
        if occ(23) = '0' and occ > to_unsigned(C_DEPTH, 24) then
          stomp_r <= '1';
        end if;
      end if;
    end if;
  end process;
  starve_sticky <= starve_r;
  stomp_sticky  <= stomp_r;

end architecture;
