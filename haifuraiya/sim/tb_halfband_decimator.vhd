-------------------------------------------------------------------------------
-- tb_halfband_decimator.vhd  (dual-oracle, revamped)
-- Proves halfband_decimator two independent ways:
--   ORACLE 1 (analytic, no files): unity DC gain. A constant input must appear
--     unchanged at the output (coeff sum = 2^17, >>17 => gain 1.000).
--   ORACLE 2 (bit-exact, file-driven): stream <VEC_DIR>hb_input.txt and compare
--     every emitted sample against <VEC_DIR>hb_expected.txt from
--     gen_halfband_vectors.py. Golden vectors follow the RTL EMIT CONVENTION:
--     full[1::2] from conv idx 1 (full transient, NOT decimate_fixed's CENTER::2).
-- PASS iff both oracles pass.
--
-- FILE PATHS: pass the absolute vectors directory as generic VEC_DIR (with a
-- trailing slash). Files are opened in the process BODY via file_open+status,
-- so xsim's run directory (sim_1/behav/xsim) does not matter and a bad path
-- reports cleanly instead of crashing. Default "" = current dir (GHDL/local).
--   xsim : xelab ... -generic_top "VEC_DIR=/abs/path/to/vectors/"
--   ghdl : ghdl -r --std=08 tb_halfband_decimator -gVEC_DIR=/abs/path/to/vectors/
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_halfband_decimator is
  generic (VEC_DIR : string := "");
end entity;

architecture sim of tb_halfband_decimator is
  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal in_valid  : std_logic := '0';
  signal in_i, in_q : signed(15 downto 0) := (others => '0');
  signal out_valid : std_logic;
  signal out_i, out_q : signed(15 downto 0);

  signal tb_phase  : integer := 1;              -- 1 = bit-exact, 2 = DC analytic
  signal dc_i, dc_q : integer := 0;
  signal dc_done   : boolean := false;

  signal be_checked, be_errors : integer := 0;
  signal dc_checked, dc_errors : integer := 0;

  constant DC_SETTLE : integer := 60;
begin
  clk <= not clk after 5 ns;                    -- 100 MHz

  dut : entity work.halfband_decimator
    port map (clk => clk, rst => rst,
              in_valid => in_valid, in_i => in_i, in_q => in_q,
              out_valid => out_valid, out_i => out_i, out_q => out_q);

  ----------------------------------------------------------------------------
  -- STIMULUS
  ----------------------------------------------------------------------------
  stim : process
    file fin       : text;
    variable fst   : file_open_status;
    variable L     : line;
    variable vi, vq : integer;
  begin
    file_open(fst, fin, VEC_DIR & "hb_input.txt", read_mode);
    assert fst = open_ok
      report "cannot open " & VEC_DIR & "hb_input.txt (set generic VEC_DIR)"
      severity failure;

    rst <= '1'; in_valid <= '0'; tb_phase <= 1;
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    -- ORACLE 2: bit-exact stream
    while not endfile(fin) loop
      readline(fin, L); read(L, vi); read(L, vq);
      in_i <= to_signed(vi, 16); in_q <= to_signed(vq, 16); in_valid <= '1';
      wait until rising_edge(clk);
    end loop;
    in_valid <= '0'; file_close(fin);
    for k in 0 to 31 loop wait until rising_edge(clk); end loop;

    -- ORACLE 1: DC unity gain
    tb_phase <= 2; dc_i <= 12345; dc_q <= -9876;
    for k in 0 to 399 loop
      in_i <= to_signed(12345, 16); in_q <= to_signed(-9876, 16);
      in_valid <= '1'; wait until rising_edge(clk);
    end loop;
    in_valid <= '0';
    for k in 0 to 31 loop wait until rising_edge(clk); end loop;
    dc_done <= true;
    wait;
  end process;

  ----------------------------------------------------------------------------
  -- CHECKER
  ----------------------------------------------------------------------------
  chk : process
    file fexp      : text;
    variable fst   : file_open_status;
    variable L     : line;
    variable ei, eq : integer;
    variable dc_seen : integer := 0;
  begin
    file_open(fst, fexp, VEC_DIR & "hb_expected.txt", read_mode);
    assert fst = open_ok
      report "cannot open " & VEC_DIR & "hb_expected.txt (set generic VEC_DIR)"
      severity failure;
    loop
      wait until rising_edge(clk);
      if out_valid = '1' then
        if tb_phase = 1 then
          if not endfile(fexp) then
            readline(fexp, L); read(L, ei); read(L, eq);
            if to_integer(out_i) /= ei or to_integer(out_q) /= eq then
              be_errors <= be_errors + 1;
              report "bitexact mismatch @" & integer'image(be_checked) &
                     " got (" & integer'image(to_integer(out_i)) & "," &
                     integer'image(to_integer(out_q)) & ") exp (" &
                     integer'image(ei) & "," & integer'image(eq) & ")"
                     severity warning;
            end if;
            be_checked <= be_checked + 1;
          end if;
        else
          dc_seen := dc_seen + 1;
          if dc_seen > DC_SETTLE then
            if to_integer(out_i) /= dc_i or to_integer(out_q) /= dc_q then
              dc_errors <= dc_errors + 1;
            end if;
            dc_checked <= dc_checked + 1;
          end if;
        end if;
      end if;
    end loop;
  end process;

  ----------------------------------------------------------------------------
  -- VERDICT
  ----------------------------------------------------------------------------
  verdict : process
  begin
    wait until dc_done;
    wait for 1 ns;
    report "ORACLE 2 (bit-exact): checked " & integer'image(be_checked) &
           ", mismatches " & integer'image(be_errors) severity note;
    report "ORACLE 1 (DC unity) : checked " & integer'image(dc_checked) &
           ", errors "     & integer'image(dc_errors) severity note;
    if be_errors = 0 and dc_errors = 0 and be_checked > 0 and dc_checked > 0 then
      report "PASS: halfband_decimator bit-exact to golden model AND unity DC gain"
             severity note;
    else
      report "FAIL" severity error;
    end if;
    finish;
  end process;

end architecture sim;
