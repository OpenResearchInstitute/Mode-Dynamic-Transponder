-------------------------------------------------------------------------------
-- tb_r2sdf_fft.vhd  (dual-oracle)
-- Proves r2sdf_fft two independent ways:
--   ORACLE 1 (analytic ordering, the REVERSAL DETECTOR): for each real frame the
--     generator tags an expected peak bin in fft_peaks.txt. A +k tone must peak
--     at bin k, a -k tone at bin (N-k). If channels are mirrored anywhere in the
--     FFT (twiddle sign, bit-reversal reorder) this fires.
--   ORACLE 2 (bit-exact): every output sample must equal fft_expected.txt, and
--     out_idx must equal its natural position in the frame (catches reorder bugs).
--
-- FRAME CONTRACT (measured, see gen_fft_vectors.py):
--   ignore outputs until the first out_idx=0 (leading partial), then FILL=1
--   aligned frame is pipeline-fill garbage, then aligned frame (FILL+k) =
--   fft_fixed(input frame k), out_idx = natural bin. Input carries 2 trailing
--   zero flush frames so the last real frame drains while in_valid is high.
--
-- File paths via generic VEC_DIR (trailing slash), opened in-body with status.
--   ghdl -r --std=08 tb_r2sdf_fft -gVEC_DIR=/abs/path/to/vectors/
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use ieee.math_real.all;

entity tb_r2sdf_fft is
  generic (
    VEC_DIR : string   := "";
    N       : positive := 64;
    W       : positive := 40;
    FILL    : natural  := 1        -- aligned garbage frames after the partial
  );
end entity;

architecture sim of tb_r2sdf_fft is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal iv  : std_logic := '0';
  signal ire, iim : signed(W-1 downto 0) := (others => '0');
  signal ov  : std_logic;
  signal ore, oim : signed(W-1 downto 0);
  signal oidx : unsigned(integer(ceil(log2(real(N))))-1 downto 0);

  signal all_done : boolean := false;
  signal be_checked, be_errors : integer := 0;
  signal idx_errors            : integer := 0;
  signal ord_checked, ord_errors : integer := 0;

  function iabs(x : integer) return integer is
  begin if x < 0 then return -x; else return x; end if; end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.r2sdf_fft
    generic map (N => N, DATA_WIDTH => W, TWIDDLE_WIDTH => 16)
    port map (clk => clk, rst => rst, in_valid => iv, in_re => ire, in_im => iim,
              out_valid => ov, out_re => ore, out_im => oim, out_idx => oidx);

  ----------------------------------------------------------------------------
  -- STIMULUS: stream every input line continuously, then drain.
  ----------------------------------------------------------------------------
  stim : process
    file fin     : text;
    variable fst : file_open_status;
    variable L   : line;
    variable re, im : integer;
  begin
    file_open(fst, fin, VEC_DIR & "fft_input.txt", read_mode);
    assert fst = open_ok
      report "cannot open " & VEC_DIR & "fft_input.txt (set generic VEC_DIR)"
      severity failure;

    rst <= '1'; iv <= '0';
    for k in 0 to 3 loop wait until rising_edge(clk); end loop;
    rst <= '0'; wait until rising_edge(clk);

    while not endfile(fin) loop
      readline(fin, L); read(L, re); read(L, im);
      ire <= to_signed(re, W); iim <= to_signed(im, W); iv <= '1';
      wait until rising_edge(clk);
    end loop;
    iv <= '0';
    for k in 0 to 400 loop wait until rising_edge(clk); end loop;
    wait;
  end process;

  ----------------------------------------------------------------------------
  -- CHECKER: align on first out_idx=0, skip FILL frames, then dual-oracle.
  ----------------------------------------------------------------------------
  chk : process
    file fexp, fpk : text;
    variable fs1, fs2 : file_open_status;
    variable Le, Lp   : line;
    variable ei, eq, pk : integer;
    variable aligned  : boolean := false;
    variable frame_no : integer := 0;      -- aligned frame index (incl. FILL)
    variable pos      : integer := 0;      -- 0..N-1 within frame
    variable cur_max  : integer := -1;
    variable cur_peak : integer := 0;
    variable mag      : integer;
    variable real_fr  : boolean;
  begin
    file_open(fs1, fexp, VEC_DIR & "fft_expected.txt", read_mode);
    assert fs1 = open_ok report "cannot open " & VEC_DIR & "fft_expected.txt" severity failure;
    file_open(fs2, fpk,  VEC_DIR & "fft_peaks.txt", read_mode);
    assert fs2 = open_ok report "cannot open " & VEC_DIR & "fft_peaks.txt" severity failure;

    loop
      wait until rising_edge(clk);
      if ov = '1' then
        if not aligned then
          if to_integer(oidx) = 0 then       -- first true frame boundary
            aligned := true; frame_no := 0; pos := 0; cur_max := -1;
          end if;
        end if;

        if aligned then
          real_fr := frame_no >= FILL;
          if real_fr and not endfile(fexp) then
            -- ORACLE 2a: out_idx must equal natural position
            if to_integer(oidx) /= pos then
              idx_errors <= idx_errors + 1;
              report "idx slip: frame " & integer'image(frame_no-FILL) &
                     " pos " & integer'image(pos) & " got idx " &
                     integer'image(to_integer(oidx)) severity warning;
            end if;
            -- ORACLE 2b: bit-exact value
            readline(fexp, Le); read(Le, ei); read(Le, eq);
            if to_integer(ore) /= ei or to_integer(oim) /= eq then
              be_errors <= be_errors + 1;
              report "fft mismatch frame " & integer'image(frame_no-FILL) &
                     " bin " & integer'image(pos) & " got (" &
                     integer'image(to_integer(ore)) & "," &
                     integer'image(to_integer(oim)) & ") exp (" &
                     integer'image(ei) & "," & integer'image(eq) & ")"
                     severity warning;
            end if;
            be_checked <= be_checked + 1;
            -- ORACLE 1: track peak bin for the ordering check
            mag := iabs(to_integer(ore)) + iabs(to_integer(oim));
            if mag > cur_max then cur_max := mag; cur_peak := pos; end if;
          end if;

          pos := pos + 1;
          if pos = N then
            if real_fr and not endfile(fpk) then
              readline(fpk, Lp); read(Lp, pk);
              if pk /= -1 then
                if cur_peak /= pk then
                  ord_errors <= ord_errors + 1;
                  report "ORDERING/REVERSAL: frame " & integer'image(frame_no-FILL) &
                         " peak bin " & integer'image(cur_peak) &
                         " expected " & integer'image(pk) severity warning;
                end if;
                ord_checked <= ord_checked + 1;
              end if;
            end if;
            pos := 0; cur_max := -1; cur_peak := 0;
            frame_no := frame_no + 1;
            if endfile(fexp) then all_done <= true; end if;
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
    report "ORACLE 2 (bit-exact): checked " & integer'image(be_checked) &
           " samples, mismatches " & integer'image(be_errors) &
           ", idx slips " & integer'image(idx_errors) severity note;
    report "ORACLE 1 (ordering) : checked " & integer'image(ord_checked) &
           " frames, reversals " & integer'image(ord_errors) severity note;
    if be_errors = 0 and idx_errors = 0 and ord_errors = 0
       and be_checked > 0 and ord_checked > 0 then
      report "PASS: r2sdf_fft bit-exact to golden model AND channel ordering correct (+k->k, -k->N-k)"
             severity note;
    else
      report "FAIL" severity error;
    end if;
    finish;
  end process;

end architecture sim;
