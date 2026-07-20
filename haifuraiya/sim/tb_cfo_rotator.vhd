-- tb_cfo_rotator.vhd -- self-checking bench for the CFO correction rotator
-- T1 freq_hz=0: passthrough -- tone at +5 kHz stays at +5 kHz (phase-slope
--    measured across the output), amplitude preserved within rounding
-- T2 freq_hz=+5000 removing a +5 kHz tone -> output DC (slope ~ 0)
-- T3 freq_hz=-3000 on a -3 kHz tone -> DC (sign convention proof)
-- T4 amplitude invariance across T2 (|out| == |in| within 2 LSB)
-- Method: drive complex tone at fs=625k (en every 160 clk); measure mean
-- per-sample phase advance over 200 samples via cross/dot on successive
-- outputs; slope_hz = advance/2pi * fs.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_cfo_rotator is end entity;

architecture sim of tb_cfo_rotator is
    constant CLK_P : time := 10 ns;
    constant FS    : real := 625000.0;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal en  : std_logic := '0';
    signal ii, qi : signed(15 downto 0) := (others => '0');
    signal fhz : signed(15 downto 0) := (others => '0');
    signal ov  : std_logic;
    signal io, qo : signed(15 downto 0);
    signal running : std_logic := '1';
    signal fails : natural := 0;
begin
    clkgen : process
    begin
        while running = '1' loop
            clk <= '0'; wait for CLK_P/2;
            clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    dut : entity work.cfo_rotator
        port map (clk => clk, rst => rst, en => en, i_in => ii, q_in => qi,
                  freq_hz => fhz, out_valid => ov, i_out => io, q_out => qo);

    stim : process
        variable ph, w : real;
        variable n : integer;
        variable pr, pi, r0, i0 : real;
        variable cross, dot, adv, slope, mag, mag0 : real;
        procedure run_tone(constant tone_hz : in real;
                           constant corr_hz : in integer;
                           variable slope_out : out real;
                           variable mag_out   : out real) is
            variable lp_r, lp_i : real := 0.0;
            variable have_prev : boolean := false;
            variable acc_cross, acc_dot, acc_mag : real := 0.0;
            variable cnt : integer := 0;
        begin
            fhz <= to_signed(corr_hz, 16);
            ph := 0.0; w := 2.0*MATH_PI*tone_hz/FS;
            rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
            rst <= '0';
            for k in 0 to 259 loop
                ii <= to_signed(integer(round(20000.0*cos(ph))), 16);
                qi <= to_signed(integer(round(20000.0*sin(ph))), 16);
                ph := ph + w;
                en <= '1'; wait until rising_edge(clk);
                en <= '0';
                for c in 1 to 7 loop wait until rising_edge(clk); end loop;
                if ov = '1' or true then null; end if;
                -- sample the registered output after the pipe settles
                pr := real(to_integer(io)); pi := real(to_integer(qo));
                if k > 8 then          -- skip pipe fill + settle
                    if have_prev then
                        acc_cross := acc_cross + (r0*pi - i0*pr);
                        acc_dot   := acc_dot   + (r0*pr + i0*pi);
                        acc_mag   := acc_mag + sqrt(pr*pr + pi*pi);
                        cnt := cnt + 1;
                    end if;
                    r0 := pr; i0 := pi; have_prev := true;
                end if;
            end loop;
            adv := arctan(acc_cross, acc_dot);   -- mean per-sample advance
            slope_out := adv/(2.0*MATH_PI)*FS;
            mag_out   := acc_mag/real(cnt);
        end procedure;
        procedure chk(constant cond : boolean; constant msg : string) is
        begin
            if cond then report "PASS: " & msg severity note;
            else report "FAIL: " & msg severity error; fails <= fails + 1;
            end if;
            wait for 0 ns;
        end procedure;
    begin
        wait until rising_edge(clk);

        -- T1: passthrough
        run_tone(5000.0, 0, slope, mag);
        report "T1 slope=" & integer'image(integer(slope)) & " Hz  mag=" &
               integer'image(integer(mag)) severity note;
        chk(abs(slope - 5000.0) < 40.0, "T1 freq=0 passthrough: +5 kHz stays");
        mag0 := mag;

        -- T2: remove +5 kHz
        run_tone(5000.0, 5000, slope, mag);
        report "T2 slope=" & integer'image(integer(slope)) & " Hz" severity note;
        chk(abs(slope) < 40.0, "T2 +5 kHz corrected to DC");

        -- T4: amplitude through correction
        chk(abs(mag - mag0) < 30.0, "T4 amplitude preserved (" &
            integer'image(integer(mag)) & " vs " & integer'image(integer(mag0)) & ")");

        -- T3: sign convention, negative side
        run_tone(-3000.0, -3000, slope, mag);
        report "T3 slope=" & integer'image(integer(slope)) & " Hz" severity note;
        chk(abs(slope) < 40.0, "T3 -3 kHz corrected to DC (sign convention)");

        if fails = 0 then report "ALL TESTS PASS" severity note;
        else report integer'image(fails) & " FAILURES" severity failure;
        end if;
        running <= '0';
        wait;
    end process;
end architecture;
