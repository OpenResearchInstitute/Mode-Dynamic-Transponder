-------------------------------------------------------------------------------
-- This is free and unencumbered software released into the public domain.
--
-- Anyone is free to copy, modify, publish, use, compile, sell, or distribute
-- this software, either in source code form or as a compiled bitstream, for 
-- any purpose, commercial or non-commercial, and by any means.
--
-- In jurisdictions that recognize copyright laws, the author or authors of 
-- this software dedicate any and all copyright interest in the software to 
-- the public domain. We make this dedication for the benefit of the public at
-- large and to the detriment of our heirs and successors. We intend this 
-- dedication to be an overt act of relinquishment in perpetuity of all present
-- and future rights to this software under copyright law.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
-- ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- THIS DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES. 
-------------------------------------------------------------------------------
-- Version      Date            Author       Description
-- 1.0          2020            Teledyne e2v Creation
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library std;
use std.textio.all;
use std.env.all;

entity tb_rx_xpm_async_fifo is
end tb_rx_xpm_async_fifo;

architecture behavioral of tb_rx_xpm_async_fifo is
  constant DATA_WIDTH : integer := 16;
  constant FIFO_DEPTH : integer := 512;
  signal rst         : std_logic                               := '0';
  signal wr_en       : std_logic                               := '0';
  signal wr_clk      : std_logic                               := '0';
  signal wr_rst_busy : std_logic                               := '0';
  signal rd_en       : std_logic                               := '0';
  signal rd_clk      : std_logic                               := '1';
  signal rd_rst_busy : std_logic                               := '0';
  signal din         : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
  signal dout        : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
  signal full        : std_logic;
  signal empty       : std_logic;

begin
  rx_xpm_async_fifo_1 : entity work.rx_xpm_async_fifo
    generic map (
      DATA_WIDTH => DATA_WIDTH,
      FIFO_DEPTH => FIFO_DEPTH)
    port map (
      rst         => rst,
      wr_en       => wr_en,
      wr_clk      => wr_clk,
      wr_rst_busy => wr_rst_busy,
      rd_en       => rd_en,
      rd_clk      => rd_clk,
      rd_rst_busy => rd_rst_busy,
      din         => din,
      dout        => dout,
      full        => full,
      empty       => empty);

  wr_clk <= not wr_clk after 2.5 ns;  -- 200 MHz
  rd_clk <= not rd_clk after 2.5 ns;  -- 200 MHz

  my_tb : process
  begin
    rst <= '1';
    wait for 100 ns;
    wait until rising_edge(wr_clk);
    rst <= '0';
    wait until falling_edge(wr_rst_busy);
    --
    wait until rising_edge(wr_clk);
    wr_en <= '1';
    din   <= x"5555";      
    wait for 1000 ns;   
    wait until rising_edge(wr_clk);
    wr_en <= '0';
    rst <= '1';
    wait until rising_edge(wr_clk);
    rst <= '0';
    wait;
  end process;
end behavioral;
