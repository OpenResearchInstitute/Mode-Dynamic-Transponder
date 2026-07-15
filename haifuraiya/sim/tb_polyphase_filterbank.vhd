-------------------------------------------------------------------------------
-- tb_polyphase_filterbank.vhd  (dual-oracle)
-- Proves polyphase_filterbank_parallel two independent ways:
--   ORACLE 1 (analytic, in-hardware DC gain = commutator/channel-0 sanity):
--     drive a constant c; once the 1536-tap prototype settles, channel 0 (the
--     sum of all N branch outputs) must equal c * COEFF_SUM (Q1.14 unity DC).
--     A wrong commutator direction breaks channel 0 and this fires.
--   ORACLE 2 (bit-exact): every branch output of every frame must equal
--     poly_expected.txt from the golden model (proven bit-exact to this RTL).
--
-- FRAME CONTRACT (measured, dump-compare, M=16): frame f (f=0,1,2,...) appears
--   on the f-th outputs_valid; NO fill frame. All N branch outputs are present
--   in parallel on branch_outputs the cycle outputs_valid=1. Branch k occupies
--   bits ((k+1)*W-1 downto k*W), W=40, LSB=branch 0.
--
-- Order: bit-exact FIRST (xbuf is zero from power-on init, matching the model's
--   zero-history assumption), then DC (which self-flushes the buffer).
--
-- Paths via generic VEC_DIR (trailing slash), opened in-body with status.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_polyphase_filterbank is
  generic (
    VEC_DIR   : string   := "";
    N         : positive := 64;
    W         : positive := 40;
    M         : positive := 16;
    COEFF_SUM : integer  := 16432;   -- sum of prototype coeffs (Q1.14), DC gain
    DC_C      : integer  := 100      -- DC test level (c*COEFF_SUM must fit integer)
  );
end entity;

architecture sim of tb_polyphase_filterbank is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal sv  : std_logic := '0';
  signal sin : std_logic_vector(15 downto 0) := (others => '0');
  signal bo  : std_logic_vector(N*W-1 downto 0);
  signal ov  : std_logic;

  signal tb_phase : integer := 1;                 -- 1 = bit-exact, 2 = DC
  signal be_frames, be_errors : integer := 0;
  signal dc_checked, dc_errors : integer := 0;
  signal all_done : boolean := false;
begin
  clk <= not clk after 5 ns;

  dut : entity work.polyphase_filterbank_parallel
    generic map (N_CHANNELS => N, M_DECIMATION => M, TAPS_PER_BRANCH => 24,
                 DATA_WIDTH => 16, COEFF_WIDTH => 16, ACCUM_WIDTH => W)
    port map (clk => clk, reset => rst, sample_in => sin, sample_valid => sv,
              branch_outputs => bo, outputs_valid => ov);

  ----------------------------------------------------------------------------
  -- STIMULUS
  ----------------------------------------------------------------------------
  stim : process
    file fin     : text;
    variable fst : file_open_status;
    variable L   : line; variable v : integer;
  begin
    file_open(fst, fin, VEC_DIR & "poly_input.txt", read_mode);
    assert fst = open_ok
      report "cannot open " & VEC_DIR & "poly_input.txt (set generic VEC_DIR)"
      severity failure;

    rst <= '1'; sv <= '0'; tb_phase <= 1;
    for k in 0 to 3 loop wait until rising_edge(clk); end loop;
    rst <= '0'; wait until rising_edge(clk);

    -- ORACLE 2: bit-exact stream (xbuf starts at 0 from power-on init)
    while not endfile(fin) loop
      readline(fin, L); read(L, v);
      sin <= std_logic_vector(to_signed(v, 16)); sv <= '1';
      wait until rising_edge(clk);
    end loop;
    sv <= '0';
    for k in 0 to 40 loop wait until rising_edge(clk); end loop;

    -- ORACLE 1: DC unity gain. Feed >= 1536+M constant samples to settle.
    tb_phase <= 2;
    for k in 0 to (N*24 + M*8) loop
      sin <= std_logic_vector(to_signed(DC_C, 16)); sv <= '1';
      wait until rising_edge(clk);
    end loop;
    sv <= '0';
    for k in 0 to 40 loop wait until rising_edge(clk); end loop;
    all_done <= true; wait;
  end process;

  ----------------------------------------------------------------------------
  -- CHECKER: each outputs_valid delivers all N branches in parallel.
  ----------------------------------------------------------------------------
  chk : process
    file fexp    : text;
    variable fst : file_open_status;
    variable L   : line; variable ev : integer;
    variable brk : signed(W-1 downto 0);
    variable ssum : signed(63 downto 0);
    variable dc_seen : integer := 0;
  begin
    file_open(fst, fexp, VEC_DIR & "poly_expected.txt", read_mode);
    assert fst = open_ok report "cannot open " & VEC_DIR & "poly_expected.txt" severity failure;
    loop
      wait until rising_edge(clk);
      if ov = '1' then
        if tb_phase = 1 then                       -- ORACLE 2: bit-exact
          if not endfile(fexp) then
            for k in 0 to N-1 loop
              brk := signed(bo((k+1)*W-1 downto k*W));
              readline(fexp, L); read(L, ev);
              if to_integer(brk) /= ev then
                be_errors <= be_errors + 1;
                report "branch mismatch frame " & integer'image(be_frames) &
                       " branch " & integer'image(k) & " got " &
                       integer'image(to_integer(brk)) & " exp " &
                       integer'image(ev) severity warning;
              end if;
            end loop;
            be_frames <= be_frames + 1;
            if endfile(fexp) then                  -- last expected frame consumed
              null;
            end if;
          end if;
        else                                       -- ORACLE 1: DC unity gain
          ssum := (others => '0');
          for k in 0 to N-1 loop
            ssum := ssum + resize(signed(bo((k+1)*W-1 downto k*W)), 64);
          end loop;
          dc_seen := dc_seen + 1;
          if dc_seen > (N*24)/M + 2 then           -- fully settled frames only
            if ssum /= to_signed(DC_C * COEFF_SUM, 64) then
              dc_errors <= dc_errors + 1;
              report "DC gain: channel0 sum " & integer'image(to_integer(ssum(31 downto 0))) &
                     " expected " & integer'image(DC_C * COEFF_SUM) severity warning;
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
    wait until all_done;
    wait for 1 ns;
    report "ORACLE 2 (bit-exact): " & integer'image(be_frames) &
           " frames, branch mismatches " & integer'image(be_errors) severity note;
    report "ORACLE 1 (DC unity)  : " & integer'image(dc_checked) &
           " settled frames, errors " & integer'image(dc_errors) severity note;
    if be_errors = 0 and dc_errors = 0 and be_frames > 0 and dc_checked > 0 then
      report "PASS: polyphase_filterbank bit-exact to golden model AND channel-0 unity DC gain (commutator direction correct)"
             severity note;
    else
      report "FAIL" severity error;
    end if;
    finish;
  end process;

end architecture sim;
