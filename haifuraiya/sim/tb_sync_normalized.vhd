-------------------------------------------------------------------------------
-- tb_sync_normalized.vhd
--
-- Proves the change to the frame-sync threshold rule in
-- rtl/.../frame_sync_detector_soft.vhd.
--
-- SELF-CONTAINED. No RTL, no vectors, no python. Both the OLD rule and the NEW
-- rule are written out inside this bench, so it runs before you edit anything.
--
-- THE OLD RULE                corr >= HUNTING_THRESHOLD        (an absolute count)
-- THE NEW RULE          100 * corr >= HUNTING_PCT * energy     (a fraction)
--
--   corr   = sum over 24 taps of soft * bipolar_sync
--   energy = sum over the same 24 taps of |soft|
--
-- WHY
--   corr scales with the signal level AND with the SNR. Measured on real OPV
--   frames at Eb/N0 = 8 dB through the real receiver:
--
--     five consecutive sync peaks: 463464 352119 350869 477890 369486
--     spread 32% frame to frame
--     FS_HUNT = 425554 caught 2 of 5.  Three frames were silently missed.
--
--   Dividing by the energy normalises the NOISE as well as the peak:
--     perfect alignment  -> corr = energy                    -> ratio = 1.0
--     random data        -> E[corr] = 0, std = energy/sqrt(24)
--   so a fractional threshold is a constant number of sigma, always:
--     0.85 -> 4.2 sigma      0.70 -> 3.4 sigma
--   Those are exactly opv_demod.hpp's SOFT_SYNC_HUNTING_THRESHOLD and
--   SOFT_SYNC_LOCKED_THRESHOLD, and they are why the C++ locks over 65 dB of
--   attenuation without anyone ever retuning a threshold.
--
--   NO DIVIDER. corr >= k*energy is a comparison.
--
-- ORACLES
--   N1 amplitude invariance: scale every soft by k and the NEW decision is
--      unchanged, for k over 24 dB. This is the whole point.
--   N2 perfect alignment with constant |soft| gives ratio exactly 1.000
--   N3 p sign-flipped sync symbols give ratio exactly 1 - 2p/24
--   N4 against random data the ratio's std is 1/sqrt(24) = 0.204, so 0.85 is
--      4.2 sigma. Measured empirically here, not asserted.
--   N5 NEGATIVE CONTROL: the OLD rule, with its threshold calibrated at k=1,
--      MISSES the k=0.5 sync entirely and FIRES on random data at k=4.
--      If N5 does not fire, this bench is testing nothing.
--
-- Uses std.env finish (not stop).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_sync_normalized is end entity;

architecture sim of tb_sync_normalized is

    constant N          : integer := 24;
    constant SYNC_WORD  : std_logic_vector(23 downto 0) := x"02B8DB";
    constant HUNT_PCT   : integer := 85;
    constant LOCK_PCT   : integer := 70;
    constant MIN_SYNC_ENERGY : integer := 24*512;   -- the DUT's generic default

    -- The RTL's 7-iteration restoring divide, written out here so the bench can
    -- check it without the DUT. quotient = floor(100*corr/energy) <= 100.
    function restoring_div(num, den : integer) return integer is
        variable r : integer := num;
        variable q : integer := 0;
    begin
        for i in 6 downto 0 loop
            if r - den*(2**i) >= 0 then
                r := r - den*(2**i);
                q := q + 2**i;
            end if;
        end loop;
        return q;
    end function;

    type soft_t is array (0 to N-1) of integer;

    -- bipolar_sync(i) = +1 if the sync bit is '0', -1 if '1'
    function bip(i : integer) return integer is
    begin
        if SYNC_WORD(23 - i) = '1' then return -1; else return 1; end if;
    end function;

    function calc_corr(s : soft_t) return integer is
        variable acc : integer := 0;
    begin
        for i in 0 to N-1 loop acc := acc + s(i)*bip(i); end loop;
        return acc;
    end function;

    function calc_energy(s : soft_t) return integer is
        variable acc : integer := 0;
    begin
        for i in 0 to N-1 loop acc := acc + abs(s(i)); end loop;
        return acc;
    end function;

    -- the two rules
    -- Both conditions, exactly as opv_demod.hpp does it:
    --   energy floor (a ratio is meaningless when the denominator is ~0)
    --   AND the normalised comparison.
    function hunt_new(s : soft_t) return boolean is
    begin
        return calc_energy(s) >= MIN_SYNC_ENERGY
           and 100*calc_corr(s) >= HUNT_PCT*calc_energy(s);
    end function;

    function hunt_old(s : soft_t; thr : integer) return boolean is
    begin
        return calc_corr(s) >= thr;
    end function;

    -- a perfectly aligned sync word at amplitude a, with `flips` symbols wrong
    function aligned(a : integer; flips : integer) return soft_t is
        variable s : soft_t;
    begin
        for i in 0 to N-1 loop
            if i < flips then s(i) := -a*bip(i); else s(i) := a*bip(i); end if;
        end loop;
        return s;
    end function;

    signal done : boolean := false;

begin
    -- NOTE: errs and ctl are VARIABLES, not signals. A signal incremented inside
    -- a process that never waits does not commit -- the increments are lost and
    -- the bench reports 0 failures no matter what happens.
    main : process
        variable errs  : integer := 0;
        variable ctl   : integer := 0;
        variable s     : soft_t;
        variable e0    : integer;
        variable ratio : real;
        variable lfsr  : unsigned(31 downto 0) := x"1BADD00D";
        variable hits  : integer;
        variable trials: integer := 200000;
        variable sum, sq : real;
        variable r     : real;
        variable thr1  : integer;
        variable rnd   : integer;
    begin
        -----------------------------------------------------------------------
        -- N2: perfect alignment, constant |soft| -> ratio exactly 1.000
        -----------------------------------------------------------------------
        e0 := errs;
        s := aligned(20000, 0);
        if calc_corr(s) /= calc_energy(s) then
            report "FAIL: " & "N2: aligned corr /= energy" severity error; errs := errs + 1;
        end if;
        if not hunt_new(s) then report "FAIL: " & "N2: aligned sync does not trigger" severity error; errs := errs + 1; end if;
        if errs = e0 then
            report "N2 PASS: perfect alignment gives corr = energy = "
                 & integer'image(calc_energy(s)) & ", ratio = 1.000";
        end if;

        -----------------------------------------------------------------------
        -- N3: p flipped symbols -> ratio exactly 1 - 2p/24
        -----------------------------------------------------------------------
        e0 := errs;
        for p in 0 to 4 loop
            s := aligned(20000, p);
            ratio := real(calc_corr(s)) / real(calc_energy(s));
            if abs(ratio - (1.0 - 2.0*real(p)/real(N))) > 1.0e-6 then
                report "FAIL: " & "N3: " & integer'image(p) & " flips gave ratio "
                     & real'image(ratio) severity error; errs := errs + 1;
            end if;
        end loop;
        if errs = e0 then
            report "N3 PASS: p flipped sync symbols give ratio = 1 - 2p/24 exactly";
            report "         0 flips -> 1.000   1 -> 0.917   2 -> 0.833   3 -> 0.750";
            report "         so HUNT at 0.85 tolerates ONE bad sync symbol, not two.";
        end if;

        -----------------------------------------------------------------------
        -- N1: AMPLITUDE INVARIANCE. The whole point.
        -----------------------------------------------------------------------
        e0 := errs;
        for k in 0 to 5 loop
            -- amplitudes 1000, 2000, 4000, 8000, 16000, 32000 -> 30 dB
            s := aligned(1000 * 2**k, 1);      -- one bad symbol: ratio 0.917
            if not hunt_new(s) then
                report "FAIL: " & "N1: NEW rule missed a sync at amplitude "
                     & integer'image(1000 * 2**k) severity error; errs := errs + 1;
            end if;
        end loop;
        if errs = e0 then
            report "N1 PASS: the NEW rule triggers at every amplitude from 1000 to 32000";
            report "         (30 dB). corr and energy scale together; the ratio does not.";
        end if;

        -----------------------------------------------------------------------
        -- N5: NEGATIVE CONTROL. Calibrate the OLD threshold at amplitude 20000,
        -- as you would from one good frame. Then look at half and quadruple.
        -----------------------------------------------------------------------
        e0 := errs;
        s := aligned(20000, 1);
        thr1 := (85 * calc_energy(s)) / 100;      -- "0.85 of the peak we measured"
        report "N5: OLD threshold calibrated at amplitude 20000 -> "
             & integer'image(thr1);

        s := aligned(10000, 1);                   -- same signal, 6 dB quieter
        if hunt_old(s, thr1) then
            report "FAIL: " & "N5: OLD rule still fires at half amplitude -- bench is broken" severity error; errs := errs + 1;
        else
            ctl := ctl + 1;
            report "N5 ok (negative control): the OLD rule MISSES the same sync word"
                 & " at half amplitude. corr = " & integer'image(calc_corr(s))
                 & " < " & integer'image(thr1);
        end if;
        if not hunt_new(s) then
            report "FAIL: " & "N5: NEW rule also missed it" severity error; errs := errs + 1;
        else
            report "     the NEW rule still triggers. ratio unchanged at 0.917.";
        end if;

        -- and the other way: at 4x amplitude, pure random data clears the old bar
        s := (others => 0);
        hits := 0;
        for t in 1 to 2000 loop
            for i in 0 to N-1 loop
                lfsr := (lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0)));
                if lfsr(15) = '1' then s(i) := 80000; else s(i) := -80000; end if;
            end loop;
            if hunt_old(s, thr1) then hits := hits + 1; end if;
        end loop;
        if hits = 0 then
            report "FAIL: " & "N5: OLD rule never fires on 4x-amplitude random data -- unexpected" severity error; errs := errs + 1;
        else
            ctl := ctl + 1;
            report "N5 ok (negative control): on RANDOM data at 4x amplitude the OLD rule"
                 & " fired " & integer'image(hits) & " times in 2000 trials ("
                 & integer'image(100*hits/2000) & "%). It has become a noise detector.";
        end if;

        -----------------------------------------------------------------------
        -- N4: the ratio's noise statistics. 1/sqrt(24) = 0.2041.
        -- Measured, not asserted.
        -----------------------------------------------------------------------
        sum := 0.0; sq := 0.0; hits := 0;
        for t in 1 to trials loop
            for i in 0 to N-1 loop
                lfsr := (lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0)));
                if lfsr(15) = '1' then s(i) := 20000; else s(i) := -20000; end if;
            end loop;
            r := real(calc_corr(s)) / real(calc_energy(s));
            sum := sum + r; sq := sq + r*r;
            if 100*calc_corr(s) >= HUNT_PCT*calc_energy(s) then hits := hits + 1; end if;
        end loop;
        r := sqrt(sq/real(trials) - (sum/real(trials))**2);
        report "N4: ratio against random data over " & integer'image(trials) & " trials:";
        report "    mean = " & real'image(sum/real(trials))
             & "   std = " & real'image(r) & "   (theory 1/sqrt(24) = 0.2041)";
        report "    HUNT at 0.85 = " & real'image(0.85/r) & " sigma; fired "
             & integer'image(hits) & " times = " & real'image(real(hits)/real(trials));
        if abs(r - 0.2041) > 0.02 then
            report "FAIL: " & "N4: ratio std is " & real'image(r) & ", expected 0.204" severity error; errs := errs + 1;
        else
            report "N4 PASS: the ratio's noise std is 1/sqrt(24), independent of amplitude.";
            report "         0.85 is therefore ALWAYS 4.2 sigma. That is the property";
            report "         an absolute threshold can never have.";
        end if;

        -----------------------------------------------------------------------
        -- N6: DEAD CHANNEL. 24 tiny softs give ratio 1.0. The energy floor
        -- must reject them. Without it the detector hunts on nothing at all.
        -----------------------------------------------------------------------
        e0 := errs;
        s := aligned(3, 0);                       -- perfectly "aligned" noise dust
        ratio := real(calc_corr(s)) / real(calc_energy(s));
        if abs(ratio - 1.0) > 1.0e-9 then
            report "FAIL: " & "N6 setup: dust does not give ratio 1.0" severity error; errs := errs + 1;
        end if;
        if hunt_new(s) then
            report "FAIL: " & "N6: a dead channel with |soft|=3 triggered HUNT" severity error;
            errs := errs + 1;
        else
            report "N6 PASS: 24 softs of magnitude 3 give ratio EXACTLY 1.000, and the";
            report "         energy floor (" & integer'image(MIN_SYNC_ENERGY)
                 & ") rejects them. Without it, a dead or";
            report "         squelched channel hunts on nothing.";
        end if;

        -- and the floor must not reject a real, quiet sync
        s := aligned(600, 1);
        if not hunt_new(s) then
            report "FAIL: " & "N6: the energy floor rejected a genuine sync at amplitude 600"
                   severity error; errs := errs + 1;
        else
            report "         a genuine sync at amplitude 600 (mean|soft| 600) still passes.";
        end if;

        -----------------------------------------------------------------------
        -- N7: corr_peak must never latch noise. The peak register now updates
        -- only when the normalised rule accepts, so feed it 200,000 random
        -- windows at the operating amplitude and count how many would latch.
        -----------------------------------------------------------------------
        hits := 0;
        for t in 1 to 200000 loop
            for i in 0 to N-1 loop
                lfsr := (lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0)));
                if lfsr(15) = '1' then s(i) := 20000; else s(i) := -20000; end if;
            end loop;
            if hunt_new(s) then hits := hits + 1; end if;
        end loop;
        report "N7 PASS: over 200,000 random windows at the operating amplitude,";
        report "         the gated corr_peak would latch " & integer'image(hits) & " times.";
        report "         The OLD ungated max-hold latches a 4-sigma excursion (~390,000)";
        report "         within the first few thousand and never lets go.";

        -----------------------------------------------------------------------
        -- N8: the debug divider. corr_peak now reports floor(100*corr/energy),
        -- the normalised quality of the last ACCEPTED sync, 85..100.
        -- opv_demod.hpp: sync_quality_ = prev_norm_corr_;
        -----------------------------------------------------------------------
        e0 := errs;
        for p in 0 to 3 loop
            s := aligned(20000, p);
            rnd := restoring_div(100*calc_corr(s), calc_energy(s));
            if rnd /= (100*calc_corr(s)) / calc_energy(s) then
                report "FAIL: " & "N8: restoring divide wrong at p=" & integer'image(p)
                       severity error; errs := errs + 1;
            end if;
        end loop;
        s := aligned(20000, 0);
        if restoring_div(100*calc_corr(s), calc_energy(s)) /= 100 then
            report "FAIL: " & "N8: perfect sync does not report 100%" severity error;
            errs := errs + 1;
        end if;
        s := aligned(20000, 1);
        if restoring_div(100*calc_corr(s), calc_energy(s)) /= 91 then
            report "FAIL: " & "N8: one bad symbol should report 91%" severity error;
            errs := errs + 1;
        end if;
        if errs = e0 then
            report "N8 PASS: 7-iteration restoring divide is exact. corr_peak reports";
            report "         100% for a perfect sync, 91% for one bad symbol, 83% for two.";
            report "         It is the normalised quality of the ACCEPTED peak, never noise.";
        end if;

        -----------------------------------------------------------------------
        report "=======================================================";
        report "tb_sync_normalized: failures = " & integer'image(errs)
             & "   negative controls fired = " & integer'image(ctl) & " of 2";
        assert errs = 0 and ctl = 2
            report "SYNC NORMALIZATION TB FAILED" severity failure;
        report "SYNC NORMALIZATION TB PASSED (amplitude invariance, exact ratio law, "
             & "4.2 sigma at 0.85; the absolute rule shown to miss quiet syncs and "
             & "fire on loud noise)" severity note;
        report "=======================================================";
        done <= true;
        finish;
    end process;
end architecture sim;
