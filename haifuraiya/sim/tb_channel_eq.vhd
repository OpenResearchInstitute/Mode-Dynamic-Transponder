-------------------------------------------------------------------------------
-- tb_channel_eq.vhd  (dual-oracle)
-- Proves channel_eq.vhd (per-channel halfband-droop EQ) two ways:
--   ORACLE 2 (bit-exact): out_i/out_q equal channel_eq_model.apply_eq for every
--     sample, AND out_chan equals the channel the gain was applied for (proves
--     the gain ROM is indexed by TDEST and the tag propagates -- a routing check
--     independent of the arithmetic).
--   ORACLE 1 (in-hardware invariant): the stream deliberately drives full-scale
--     samples on boosted channels; the TB confirms saturation actually occurred
--     (clamp path exercised) and that no output exceeds +/-32767 (no wrap).
--
-- channel_eq is a stateless 3-stage pipeline (gain selected by in_chan), output
-- in input order. The checker collects outputs on out_valid and compares in
-- order, so pipeline latency needs no special handling.
--
-- Vectors via generic VEC_DIR (trailing slash), opened in-body with status.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_channel_eq is
  generic (VEC_DIR : string := "");
end entity;

architecture sim of tb_channel_eq is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal iv  : std_logic := '0';
  signal ichan : unsigned(5 downto 0) := (others => '0');
  signal ii, iq : signed(15 downto 0) := (others => '0');
  signal ov  : std_logic;
  signal ochan : unsigned(5 downto 0);
  signal oi, oq : signed(15 downto 0);

  signal all_done : boolean := false;
  signal checked, val_errors, chan_errors, sat_events : integer := 0;
begin
  clk <= not clk after 5 ns;

  dut : entity work.channel_eq
    port map (clk => clk, rst => rst, in_valid => iv, in_chan => ichan,
              in_i => ii, in_q => iq, out_valid => ov, out_chan => ochan,
              out_i => oi, out_q => oq);

  ----------------------------------------------------------------------------
  -- STIMULUS: drive one (chan,i,q) triple per clock.
  ----------------------------------------------------------------------------
  stim : process
    file fin     : text;
    variable fst : file_open_status;
    variable L   : line;
    variable ch, vi, vq : integer;
  begin
    file_open(fst, fin, VEC_DIR & "eq_input.txt", read_mode);
    assert fst = open_ok
      report "cannot open " & VEC_DIR & "eq_input.txt (set generic VEC_DIR)"
      severity failure;

    rst <= '1'; iv <= '0';
    for k in 0 to 3 loop wait until rising_edge(clk); end loop;
    rst <= '0'; wait until rising_edge(clk);

    while not endfile(fin) loop
      readline(fin, L); read(L, ch); read(L, vi); read(L, vq);
      ichan <= to_unsigned(ch, 6);
      ii    <= to_signed(vi, 16);
      iq    <= to_signed(vq, 16);
      iv    <= '1';
      wait until rising_edge(clk);
    end loop;
    iv <= '0';
    for k in 0 to 20 loop wait until rising_edge(clk); end loop;
    all_done <= true; wait;
  end process;

  ----------------------------------------------------------------------------
  -- CHECKER: compare each out_valid sample to the expected file, in order.
  ----------------------------------------------------------------------------
  chk : process
    file fexp    : text;
    variable fst : file_open_status;
    variable L   : line;
    variable ech, eoi, eoq : integer;
  begin
    file_open(fst, fexp, VEC_DIR & "eq_expected.txt", read_mode);
    assert fst = open_ok report "cannot open " & VEC_DIR & "eq_expected.txt" severity failure;
    loop
      wait until rising_edge(clk);
      if ov = '1' and not endfile(fexp) then
        readline(fexp, L); read(L, ech); read(L, eoi); read(L, eoq);
        -- ORACLE 2: values
        if to_integer(oi) /= eoi or to_integer(oq) /= eoq then
          val_errors <= val_errors + 1;
          report "value mismatch #" & integer'image(checked) & " ch " &
                 integer'image(to_integer(ochan)) & " got (" &
                 integer'image(to_integer(oi)) & "," & integer'image(to_integer(oq)) &
                 ") exp (" & integer'image(eoi) & "," & integer'image(eoq) & ")"
                 severity warning;
        end if;
        -- ORACLE 2: channel-tag integrity (correct gain routed + tag propagated)
        if to_integer(ochan) /= ech then
          chan_errors <= chan_errors + 1;
          report "out_chan mismatch #" & integer'image(checked) & " got " &
                 integer'image(to_integer(ochan)) & " exp " & integer'image(ech)
                 severity warning;
        end if;
        -- ORACLE 1: saturation actually exercised
        if oi = to_signed(32767, 16) or oi = to_signed(-32768, 16) or
           oq = to_signed(32767, 16) or oq = to_signed(-32768, 16) then
          sat_events <= sat_events + 1;
        end if;
        checked <= checked + 1;
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
    report "ORACLE 2: checked " & integer'image(checked) & " samples, value mismatches "
           & integer'image(val_errors) & ", out_chan mismatches " & integer'image(chan_errors)
           severity note;
    report "ORACLE 1: saturation events observed " & integer'image(sat_events)
           severity note;
    if val_errors = 0 and chan_errors = 0 and checked > 0 and sat_events > 0 then
      report "PASS: channel_eq bit-exact to golden model, TDEST-correct gain, saturation clamps"
             severity note;
    else
      report "FAIL" severity error;
    end if;
    finish;
  end process;

end architecture sim;
