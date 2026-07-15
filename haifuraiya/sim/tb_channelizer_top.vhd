-------------------------------------------------------------------------------
-- tb_channelizer_top.vhd -- dual-oracle bench for haifuraiya_channelizer_top.
--
-- DUT chain:  sample_re -> polyphase(I) \
--             sample_im -> polyphase(Q) / -> P2S (bi+j*bq) -> r2sdf_fft -> (-j)^(k*m) rot
--
-- ORACLE 2 (bit-exact): the settled frame CAP_IDX of each burst equals the
--   composed golden model (channelizer_top_model, proven bit-exact by dump-
--   compare) exactly, channel_re & channel_im (40-bit).
-- ORACLE 1 (empirical frequency->channel MAP): for each pure-tone burst, the
--   OUTPUT channel carrying the most energy (summed over settled frames) is
--   REPORTED and ASSERTED == the model's dominant channel. This demonstrates,
--   on real RTL, the k -> (N-k) reversal.
--
-- Sweep: burst 0 = random complex (bit-exact only); bursts 1..N = tones.
-- Samples are driven one every 10 clocks (10 MSps @ 100 MHz) so the P2S drains.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_channelizer_top is
    generic (
        VEC_DIR   : string  := "";
        N_BURSTS  : integer := 12;
        BURST_LEN : integer := 720;
        CAP_IDX   : integer := 40;
        ENERGY_SKIP : integer := 8
    );
end entity;

architecture sim of tb_channelizer_top is
    constant DW : integer := 16;
    constant AW : integer := 40;
    constant N  : integer := 64;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal sv  : std_logic := '0';
    signal sre, sim : std_logic_vector(DW-1 downto 0) := (others => '0');
    signal cre, cim : std_logic_vector(AW-1 downto 0);
    signal cidx : std_logic_vector(5 downto 0);
    signal cval, clast, rdy, fdrop : std_logic;

    -- capture / accumulation (written by sampler, read by driver at burst end)
    type real_arr is array(0 to N-1) of real;
    type slv_arr  is array(0 to N-1) of std_logic_vector(AW-1 downto 0);
    signal energy   : real_arr := (others => 0.0);
    signal cap_re, cap_im : slv_arr := (others => (others => '0'));
    signal frame_cnt : integer := 0;
    signal clr_pulse : std_logic := '0';     -- driver pulses to reset accumulation

    signal errors : integer := 0;
    signal map_bad : integer := 0;
    signal done : boolean := false;

    function slv2real(v : std_logic_vector(AW-1 downto 0)) return real is
        variable hi : integer := to_integer(signed(v(AW-1 downto 20)));
        variable lo : integer := to_integer(unsigned(v(19 downto 0)));
    begin
        return real(hi) * 1048576.0 + real(lo);
    end function;
begin
    clk <= not clk after 5 ns;

    dut : entity work.haifuraiya_channelizer_top
        generic map (N_CHANNELS => 64, M_DECIMATION => 16, TAPS_PER_BRANCH => 24,
                     DATA_WIDTH => DW, COEFF_WIDTH => 16, ACCUM_WIDTH => AW)
        port map (clk => clk, reset => rst, sample_re => sre, sample_im => sim,
                  sample_valid => sv, channel_re => cre, channel_im => cim,
                  channel_idx => cidx, channel_valid => cval, channel_last => clast,
                  ready => rdy, frame_dropped => fdrop);

    ---------------------------------------------------------------------------
    -- Sampler: per-channel energy accumulation + capture of frame CAP_IDX.
    ---------------------------------------------------------------------------
    sampler : process
        variable ch : integer;
        variable re_r, im_r : real;
    begin
        wait until rising_edge(clk);
        if clr_pulse = '1' then
            frame_cnt <= 0;
            for c in 0 to N-1 loop energy(c) <= 0.0; end loop;
        elsif cval = '1' then
            ch := to_integer(unsigned(cidx));
            -- energy accumulation (skip unsettled leading frames)
            if frame_cnt >= ENERGY_SKIP then
                re_r := slv2real(cre); im_r := slv2real(cim);
                energy(ch) <= energy(ch) + re_r*re_r + im_r*im_r;
            end if;
            -- capture the CAP_IDX frame for bit-exact
            if frame_cnt = CAP_IDX then
                cap_re(ch) <= cre; cap_im(ch) <= cim;
            end if;
            if clast = '1' then frame_cnt <= frame_cnt + 1; end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Driver: sweep bursts; per burst drive, then check map + bit-exact.
    ---------------------------------------------------------------------------
    driver : process
        file fi, fe : text;
        variable si, se : file_open_status;
        variable Li, Le : line;
        variable vr, vi : integer;
        variable tag : string(1 to 5);
        variable kk, exp_peak : integer;
        variable rehex, imhex : std_logic_vector(AW-1 downto 0);
        variable peak_c : integer; variable peak_e : real;
        procedure pulse_clr is begin
            clr_pulse <= '1'; wait until rising_edge(clk); clr_pulse <= '0';
        end procedure;
    begin
        file_open(si, fi, VEC_DIR & "ct_sweep_input.txt", read_mode);
        if si /= open_ok then file_open(si, fi, "ct_sweep_input.txt", read_mode); end if;
        assert si = open_ok report "cannot open ct_sweep_input.txt" severity failure;
        file_open(se, fe, VEC_DIR & "ct_sweep_expected.txt", read_mode);
        if se /= open_ok then file_open(se, fe, "ct_sweep_expected.txt", read_mode); end if;
        assert se = open_ok report "cannot open ct_sweep_expected.txt" severity failure;

        report "======================================================";
        report "channelizer_top empirical frequency->channel map:";

        for b in 0 to N_BURSTS-1 loop
            -- reset DUT + accumulation
            rst <= '1'; sv <= '0';
            for j in 0 to 3 loop wait until rising_edge(clk); end loop;
            pulse_clr;
            rst <= '0'; wait until rising_edge(clk);
            -- drive BURST_LEN samples, one every 10 clocks
            for s in 0 to BURST_LEN-1 loop
                readline(fi, Li); read(Li, vr); read(Li, vi);
                sre <= std_logic_vector(to_signed(vr, DW));
                sim <= std_logic_vector(to_signed(vi, DW));
                sv <= '1'; wait until rising_edge(clk); sv <= '0';
                for g in 0 to 8 loop wait until rising_edge(clk); end loop;
            end loop;
            sv <= '0';
            for j in 0 to 40 loop wait until rising_edge(clk); end loop;   -- drain
            -- expected header
            readline(fe, Le); read(Le, tag); read(Le, kk); read(Le, exp_peak);
            -- map oracle: argmax energy
            peak_c := 0; peak_e := energy(0);
            for c in 1 to N-1 loop
                if energy(c) > peak_e then peak_e := energy(c); peak_c := c; end if;
            end loop;
            if exp_peak < 0 then
                report "  burst " & integer'image(b) & " (random): bit-exact check only";
            else
                report "  input channel " & integer'image(kk)
                     & " -> energy peaks at OUTPUT channel " & integer'image(peak_c)
                     & "  (model " & integer'image(exp_peak) & ")";
                if peak_c /= exp_peak then map_bad <= map_bad + 1;
                    report "    MAP MISMATCH" severity error; end if;
            end if;
            -- bit-exact oracle: CAP_IDX frame
            for c in 0 to N-1 loop
                readline(fe, Le); hread(Le, rehex); hread(Le, imhex);
                if cap_re(c) /= rehex or cap_im(c) /= imhex then
                    errors <= errors + 1;
                    if errors < 6 then
                        report "    BITEXACT mismatch burst " & integer'image(b)
                             & " ch " & integer'image(c) severity error;
                    end if;
                end if;
            end loop;
        end loop;

        report "------------------------------------------------------";
        report "channelizer_top: bit-exact errors=" & integer'image(errors)
             & "  map mismatches=" & integer'image(map_bad);
        assert errors = 0 and map_bad = 0
            report "CHANNELIZER_TOP TB FAILED" severity failure;
        report "CHANNELIZER_TOP TB PASSED (bit-exact + empirical k->(N-k) map)"
            severity note;
        report "======================================================";
        done <= true; finish;
    end process;
end architecture;
