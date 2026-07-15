-------------------------------------------------------------------------------
-- tb_soft_quantizer.vhd -- the 3-bit soft quantizer must be SYMMETRIC.
--
-- INTEROPERABILITY CONSTRAINT (from opv_demod.hpp, the reference we must match):
--
--   ViterbiDecoder::decode() forms branch metrics as
--       expected 0 -> bm = sg
--       expected 1 -> bm = SOFT_MAX - sg,      SOFT_MAX = 7
--
--   Lower metric wins. So sg < 3.5 favours '0' and sg > 3.5 favours '1', and the
--   map MUST satisfy   q(-s) = 7 - q(s)   for every s. The neutral point is 3.5,
--   which lies BETWEEN codes 3 and 4 -- so the 3<->4 boundary must sit at s = 0.
--
--   FrameDecoder::decode_soft3() takes the fabric's codes with no rescale and no
--   sign flip: "the fabric's bytes drop straight in". There is nothing
--   downstream to correct an asymmetric map.
--
-- THE DEFECT (frame_sync_detector_soft.vhd, FUNCTION quantize):
--
--       IF    soft < -thr3 THEN RETURN "111";  -- 7
--       ELSIF soft < -thr2 THEN RETURN "101";  -- 5     <- should be 6
--       ELSIF soft < -thr1 THEN RETURN "100";  -- 4     <- should be 5
--       ELSIF soft <  thr1 THEN RETURN "011";  -- 3     <- [-thr1,0) should be 4
--       ELSIF soft <  thr2 THEN RETURN "010";  -- 2
--       ELSIF soft <  thr3 THEN RETURN "001";  -- 1
--       ELSE                    RETURN "000";  -- 0
--
--   Code 6 is unreachable. The negative half has three regions where the
--   positive half has four. The 3<->4 boundary sits at s = -thr1, not at s = 0,
--   so EVERY soft value in [-thr1, 0) is decoded with the WRONG SIGN, and every
--   soft decision carries a systematic +thr1 offset.
--
-- WHY IT HAS BEEN INVISIBLE (measured, thr = 92/276/460, 8 dB symbol SNR):
--
--     mean |soft|   railed   symbols given the WRONG code   hard-decision penalty
--        2000       97.5%              1.3%                     0.06 dB
--         900       89.1%              5.5%                     0.27 dB
--         600       72.2%             13.9%                     0.57 dB
--         460       49.9%             25.0%                     0.90 dB
--         300        9.0%             45.4%                     1.81 dB
--
--   A railed soft path uses only codes 0 and 7 -- the only two the fabric gets
--   right. The metric-0 seam test (5/5 perfect frames) ran in exactly that
--   regime. The railing hid the bug.
--
--   *** The normalizer's whole purpose is to UNRAIL the soft path so the middle
--       codes carry information. Landing the normalizer without fixing this
--       walks the demod straight into the defect. FIX quantize() FIRST. ***
--
-- ORACLES:
--   Q1 mirror identity:  q(-s) = 7 - q(s) for every representable s
--   Q2 all 8 codes reachable (code 6 is unreachable in the current function)
--   Q3 monotone non-increasing in s (a quantizer must not fold)
--   Q4 the 3<->4 boundary sits at s = 0
--   Q5 the CURRENT function fails Q1/Q2/Q4  (negative control -- if this passes,
--      the bench is not testing what it claims)
--
-- Uses std.env finish (not stop).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_soft_quantizer is end entity;

architecture sim of tb_soft_quantizer is

    constant THR1 : integer := 92;    -- measured hardware soft-rail values
    constant THR2 : integer := 276;
    constant THR3 : integer := 460;
    constant SPAN : integer := 800;   -- sweep range, comfortably past thr3

    -- ==== CURRENT (frame_sync_detector_soft.vhd) -- retained verbatim ==========
    function quantize_current(soft : signed(15 downto 0);
                              thr1, thr2, thr3 : signed(15 downto 0))
        return std_logic_vector is
    begin
        if    soft < -thr3 then return "111";
        elsif soft < -thr2 then return "101";
        elsif soft < -thr1 then return "100";
        elsif soft <  thr1 then return "011";
        elsif soft <  thr2 then return "010";
        elsif soft <  thr3 then return "001";
        else                    return "000";
        end if;
    end function;

    -- ==== PROPOSED -- symmetric about 3.5, all 8 codes, boundary at zero ======
    -- The only structural change is the negative half. The positive half and the
    -- threshold values are untouched, so a railed signal produces an IDENTICAL
    -- stream (codes 0 and 7 only) and every existing railed capture still
    -- decodes bit-for-bit. Only the middle codes move -- which is precisely the
    -- region the normalizer is about to start using.
    function quantize_fixed(soft : signed(15 downto 0);
                            thr1, thr2, thr3 : signed(15 downto 0))
        return std_logic_vector is
    begin
        -- The negative half uses <= so that q(-t) mirrors q(+t) exactly at the
        -- threshold samples themselves: q(+thr3)=0 requires q(-thr3)=7.
        -- The tie at soft = 0 goes to code 4, matching opv_demod.hpp:
        --   n = (-0/scale)*3.5 + 3.5 = 3.5 ; int(3.5 + 0.5) = 4
        if    soft <= -thr3 then return "111";   -- 7
        elsif soft <= -thr2 then return "110";   -- 6   (was 5, and 6 was dead)
        elsif soft <= -thr1 then return "101";   -- 5   (was 4)
        elsif soft <=  0    then return "100";   -- 4   (was 3 -- WRONG SIGN)
        elsif soft <  thr1  then return "011";   -- 3
        elsif soft <  thr2  then return "010";   -- 2
        elsif soft <  thr3  then return "001";   -- 1
        else                     return "000";   -- 0
        end if;
    end function;

    type qfun_t is (CURRENT, FIXED);

    function q(f : qfun_t; s : integer) return integer is
        variable sv : signed(15 downto 0) := to_signed(s, 16);
        constant t1 : signed(15 downto 0) := to_signed(THR1, 16);
        constant t2 : signed(15 downto 0) := to_signed(THR2, 16);
        constant t3 : signed(15 downto 0) := to_signed(THR3, 16);
    begin
        if f = CURRENT then
            return to_integer(unsigned(quantize_current(sv, t1, t2, t3)));
        else
            return to_integer(unsigned(quantize_fixed(sv, t1, t2, t3)));
        end if;
    end function;

    signal done : boolean := false;
begin

    main : process
        variable errs      : integer := 0;
        variable ctl_fails : integer := 0;
        variable seen      : std_logic_vector(0 to 7);
        variable prev      : integer;
        variable nviol     : integer;
    begin
        ---------------------------------------------------------------
        -- Q5 first: the NEGATIVE CONTROL. The current function must FAIL.
        ---------------------------------------------------------------
        nviol := 0;
        for s in -SPAN to SPAN loop
            if q(CURRENT, -s) /= 7 - q(CURRENT, s) then
                nviol := nviol + 1;
            end if;
        end loop;
        if nviol = 0 then
            report "Q5 FAIL: the CURRENT quantizer passes the mirror test -- "
                 & "this bench is not testing what it claims" severity error;
            errs := errs + 1;
        else
            ctl_fails := ctl_fails + 1;
            report "Q5 ok (negative control): CURRENT violates q(-s)=7-q(s) on "
                 & integer'image(nviol) & " of " & integer'image(2*SPAN+1) & " points";
        end if;

        seen := (others => '0');
        for s in -SPAN to SPAN loop
            seen(q(CURRENT, s)) := '1';
        end loop;
        if seen(6) = '1' then
            report "Q5 FAIL: code 6 IS reachable in CURRENT" severity error;
            errs := errs + 1;
        else
            ctl_fails := ctl_fails + 1;
            report "Q5 ok (negative control): CURRENT never emits code 6";
        end if;

        if q(CURRENT, 0) = 3 and q(CURRENT, -1) = 4 then
            report "Q5 FAIL: CURRENT already has its 3<->4 boundary at zero" severity error;
            errs := errs + 1;
        else
            ctl_fails := ctl_fails + 1;
            report "Q5 ok (negative control): CURRENT's 3<->4 boundary is at soft = "
                 & integer'image(-THR1) & ", not 0";
        end if;

        ---------------------------------------------------------------
        -- Q1 mirror identity
        ---------------------------------------------------------------
        -- s = 0 is its own mirror, so the identity cannot hold there. The tie
        -- has to fall on one side; opv_demod.hpp puts it on code 4 (see Q6).
        nviol := 0;
        for s in 1 to SPAN loop
            if q(FIXED, -s) /= 7 - q(FIXED, s) then
                nviol := nviol + 1;
                if nviol <= 3 then
                    report "Q1 FAIL at s=" & integer'image(s) & ": q(s)=" &
                           integer'image(q(FIXED,s)) & " q(-s)=" &
                           integer'image(q(FIXED,-s)) severity error;
                end if;
            end if;
        end loop;
        if nviol /= 0 then errs := errs + 1;
        else report "Q1 PASS: q(-s) = 7 - q(s) for all s in 1.." & integer'image(SPAN)
                  & " (s=0 is its own mirror; see Q6)";
        end if;

        ---------------------------------------------------------------
        -- Q2 all 8 codes reachable
        ---------------------------------------------------------------
        seen := (others => '0');
        for s in -SPAN to SPAN loop
            seen(q(FIXED, s)) := '1';
        end loop;
        for c in 0 to 7 loop
            if seen(c) = '0' then
                report "Q2 FAIL: code " & integer'image(c) & " is unreachable" severity error;
                errs := errs + 1;
            end if;
        end loop;
        if errs = 0 then report "Q2 PASS: all 8 codes reachable"; end if;

        ---------------------------------------------------------------
        -- Q3 monotone non-increasing (a quantizer must not fold)
        ---------------------------------------------------------------
        prev := q(FIXED, -SPAN);
        nviol := 0;
        for s in -SPAN+1 to SPAN loop
            if q(FIXED, s) > prev then nviol := nviol + 1; end if;
            prev := q(FIXED, s);
        end loop;
        if nviol /= 0 then
            report "Q3 FAIL: quantizer folds at " & integer'image(nviol) & " points"
                   severity error;
            errs := errs + 1;
        else
            report "Q3 PASS: monotone non-increasing in soft";
        end if;

        ---------------------------------------------------------------
        -- Q4 the 3<->4 boundary is at zero
        ---------------------------------------------------------------
        if q(FIXED, -1) = 4 and q(FIXED, 1) = 3 then
            report "Q4 PASS: q(-1)=4, q(+1)=3 -- the neutral point 3.5 sits at soft = 0";
        else
            report "Q4 FAIL: q(-1)=" & integer'image(q(FIXED,-1)) & " q(+1)=" &
                   integer'image(q(FIXED,1)) severity error;
            errs := errs + 1;
        end if;

        ---------------------------------------------------------------
        -- Q6 the tie at soft = 0 matches opv_demod.hpp (code 4)
        ---------------------------------------------------------------
        if q(FIXED, 0) = 4 then
            report "Q6 PASS: q(0)=4, matching FrameDecoder::decode()'s int(3.5+0.5)";
        else
            report "Q6 FAIL: q(0)=" & integer'image(q(FIXED,0)) & ", C++ gives 4"
                   severity error;
            errs := errs + 1;
        end if;

        ---------------------------------------------------------------
        -- Railed-stream compatibility: outside +/-thr3 the two functions agree,
        -- so every existing railed capture decodes bit-for-bit unchanged.
        ---------------------------------------------------------------
        nviol := 0;
        for s in -SPAN to SPAN loop
            if abs(s) > THR3 and q(CURRENT, s) /= q(FIXED, s) then
                nviol := nviol + 1;
            end if;
        end loop;
        if nviol = 0 then
            report "COMPAT PASS: outside +/-thr3 the fix changes NOTHING. "
                 & "Railed captures decode identically; only the middle codes move.";
        else
            report "COMPAT FAIL: the fix perturbs the railed region" severity error;
            errs := errs + 1;
        end if;

        report "=======================================================";
        report "tb_soft_quantizer: failures=" & integer'image(errs) &
               "  negative controls fired=" & integer'image(ctl_fails) & " of 3";
        assert errs = 0 and ctl_fails = 3
            report "SOFT QUANTIZER TB FAILED" severity failure;
        report "SOFT QUANTIZER TB PASSED (mirror identity, all 8 codes, monotone, "
             & "zero boundary, railed-stream compatible; current function shown broken)"
            severity note;
        report "=======================================================";
        done <= true;
        finish;
    end process;
end architecture sim;
