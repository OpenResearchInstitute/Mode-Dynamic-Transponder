------------------------------------------------------------------------------------------------------
-- rx_xpm_async_fifo (SIMULATION STAND-IN for simulators without Xilinx XPM, e.g. nvc)
------------------------------------------------------------------------------------------------------
-- Same entity as Teledyne's src_rx/rx_xpm_async_fifo.vhd, which wraps
-- xpm_fifo_async (a Xilinx parameterized macro).  xsim on chococat has XPM and
-- uses the real file; this behavioural model exists only so the ESIstream IP
-- can be exercised in nvc for the quick link-level bench.  Standard read mode,
-- read latency 1, wr_rst_busy for a few clocks after rst -- the behaviours the
-- RX decoder depends on.  NOT a synthesis file; never both this and the real
-- file in one project.
------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_xpm_async_fifo is
  generic (
    DATA_WIDTH : integer := 8;
    FIFO_DEPTH : integer := 10
    );
  port (
    rst          : in  std_logic;
    wr_en        : in  std_logic;
    wr_clk       : in  std_logic;
    wr_rst_busy  : out std_logic;
    rd_en        : in  std_logic;
    rd_clk       : in  std_logic;
    rd_rst_busy  : out std_logic;
    din          : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    dout         : out std_logic_vector(DATA_WIDTH-1 downto 0);
    full         : out std_logic;
    empty        : out std_logic
    );
end rx_xpm_async_fifo;

architecture sim of rx_xpm_async_fifo is
  type mem_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
  signal mem    : mem_t := (others => (others => '0'));
  signal wp, rp : natural range 0 to FIFO_DEPTH-1 := 0;
  signal count  : natural range 0 to FIFO_DEPTH := 0;
  signal busy_cnt : natural range 0 to 7 := 0;
  signal empty_i, full_i : std_logic := '1';
begin
  -- single process on wr_clk; the ESIstream RX uses rd_clk = wr_clk, which is
  -- the documented recommendation and the only case this model covers.
  assert false report "rx_xpm_async_fifo: SIMULATION STAND-IN (no XPM); same-clock only" severity note;

  p : process(wr_clk)
    variable c : natural;
  begin
    if rising_edge(wr_clk) then
      if rst = '1' then
        wp <= 0; rp <= 0; count <= 0; busy_cnt <= 7;
        dout <= (others => '0');
      else
        if busy_cnt /= 0 then
          busy_cnt <= busy_cnt - 1;
        else
          c := count;
          if wr_en = '1' and c < FIFO_DEPTH then
            mem(wp) <= din;
            wp <= (wp + 1) mod FIFO_DEPTH;
            c := c + 1;
          end if;
          if rd_en = '1' and count > 0 then
            dout <= mem(rp);
            rp <= (rp + 1) mod FIFO_DEPTH;
            c := c - 1;
          end if;
          count <= c;
        end if;
      end if;
    end if;
  end process;

  empty_i <= '1' when count = 0 else '0';
  full_i  <= '1' when count = FIFO_DEPTH else '0';
  empty <= empty_i;
  full  <= full_i;
  wr_rst_busy <= '1' when busy_cnt /= 0 else '0';
  rd_rst_busy <= '1' when busy_cnt /= 0 else '0';
end architecture sim;
