-------------------------------------------------------------------------------
-- cfo_sync_da.vhd -- sync-anchored DATA-AIDED carrier frequency measurement
-------------------------------------------------------------------------------
-- Project : Mode-Dynamic-Transponder / Haifuraiya      License: CERN-OHL-S v2
--
-- WHAT THIS IS (F4, design ratified 2026-10-18; f4_sync_anchored_design.md)
--   One unbiased carrier-offset measurement per ACCEPTED sync word, from
--   the 24 KNOWN sync symbols -- no symbol decisions anywhere in the path,
--   so the decision-directed threshold bias (Rife & Boorstyn; the measured
--   +343 Hz at Eb/N0 = 10 dB) cannot exist here at any SNR.  Output drives
--   the cfo_afc servo while frame sync is locked (the F2 freeze blocks the
--   decision-directed path; this path is the only authority over the word
--   once frames flow).
--
-- MEASUREMENT (numerically derived and verified 2026-10-18; model
-- cross-checked against the weekend's captures):
--   The sync tone sequence is INVARIANT over all data histories
--   (verified over 50 random histories, both parities):
--     A A A A A A B A B A B B B A A A B B A B B A B B   (A = tone f1)
--   Of the twelve lag-12 index pairs, SEVEN pair identical tones; for
--   those the accumulated LO/history phase cancels IDENTICALLY
--   (different-tone pairs carry a history-parity term -- excluded by
--   construction: the 677-Hz lesson applied in advance).  The data phase
--   of every used pair is exactly pi (verified to 1e-15), so the whole
--   correction ROM degenerates to one global negation:
--
--     Z = - SUM over 7 pairs of  y_t[j] * conj(y_t[i]),   j = i + 12
--     ferr = arg(Z) / (2*pi*12) * SYMBOL_RATE
--
--   Unambiguous range +/- R/24 = +/-2258 Hz; accuracy (numerical model):
--   sigma per sync = 52/66/84/108 Hz at Eb/N0 = 14/12/10/8 dB, unbiased
--   at all four.  The cfo_afc servo (alpha 1/4) averages to ~30-40 Hz
--   steady state: the measured requirement (residual < 150 Hz; theta
--   slip cliff ~195 Hz) is met with margin.
--
-- DETECTION vs MEASUREMENT (division of labor, deliberate):
--   This block does NOT detect sync words -- |Z| alone has only ~sqrt(7)
--   discrimination against random-payload windows (Rayleigh tail), not
--   enough for one accept per 2168 candidates.  The frame sync detector
--   already solves detection with the full 24-bit soft correlation and
--   its state machine; its sync_verified strobe (frame_sync_detector_
--   soft.vhd, F4 port) gates THIS block: on each strobe, the result ring
--   is searched G_LAT_SYM +/- G_LAT_WIN symbols back for the maximum-|Z|
--   window, and that measurement is emitted if it clears a sanity floor.
--   The detector detects; this block measures.  No strobe (missed sync)
--   means no measurement -- the word simply holds (F2 semantics).
--   Nothing here runs once: acquisition is a standing capability.
--
-- LATENCY: G_LAT_SYM is the pipeline distance, in symbols, from a sync
--   word's LAST symbol at this block's y taps to the detector's strobe
--   (MLSE traceback + soft path; a build constant).  The +/-G_LAT_WIN
--   search absorbs calibration error; if the system bench shows no
--   accepts, G_LAT_SYM is off by more than the window -- recalibrate from
--   the waves (distance from |Z| peak to strobe), do not widen the window.
--
-- SIGN CONVENTION: products are ordered NEW * conj(OLD), the same order
--   as cfo_afc's dom*conj(prev); the demod-domain double-negation note in
--   cfo_afc.vhd's header applies unchanged, so cz * (R/12) IS antenna-
--   frame ferr.  Asserted closed-loop in tb_cfo_sync_da and tb_cfo_afc T7.
--
-- BUDGET: 7 product clocks + normalize + 14 CORDIC + ring bookkeeping
--   ~= 30 clocks/symbol of 1845 available.
-- STYLE: VHDL-93; declaration initializers mirror the reset branch.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cfo_sync_da is
    generic (
        G_SYMBOL_RATE : natural := 54200;
        -- sanity floor on |Z| ~ (|re|+|im|) at the selected window: peak is
        -- ~7*|y|^2; with the normalizer pinning |y| ~ 1e5, peak ~ 2^36.
        -- 2^33 rejects dead-air strobes without biasing live ones.
        G_FLOOR_SH    : natural := 33;
        -- strobe latency: symbols from sync-end at the y taps to the frame
        -- sync detector's sync_verified strobe (traceback + soft path)
        G_LAT_SYM     : natural := 40;
        G_LAT_WIN     : natural := 12
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- per-symbol tone correlations (demod domain), engine exports --
        -- the same taps cfo_afc consumes
        y_valid    : in  std_logic;
        y1_re      : in  signed(23 downto 0);
        y1_im      : in  signed(23 downto 0);
        y2_re      : in  signed(23 downto 0);
        y2_im      : in  signed(23 downto 0);

        -- 1-clk strobe from frame_sync_detector_soft: a sync word was
        -- ACCEPTED (hunting peak or locked-position verify)
        sync_seen  : in  std_logic;

        -- one measurement per strobe (when the ring search clears the floor)
        da_ferr_hz : out signed(15 downto 0);   -- antenna frame
        da_valid   : out std_logic;             -- 1-clk strobe
        da_mag     : out unsigned(15 downto 0)  -- |Z| gauge at accept
    );
end entity cfo_sync_da;

architecture rtl of cfo_sync_da is

    -- CORDIC atan table: atan(2^-i) in Q16 TURNS (2pi = 65536), i = 0..13
    -- (verbatim from cfo_afc.vhd)
    type atan_t is array (0 to 13) of signed(17 downto 0);
    constant C_ATAN : atan_t := (
        to_signed(8192, 18), to_signed(4836, 18), to_signed(2555, 18),
        to_signed(1297, 18), to_signed(651, 18),  to_signed(326, 18),
        to_signed(163, 18),  to_signed(81, 18),   to_signed(41, 18),
        to_signed(20, 18),   to_signed(10, 18),   to_signed(5, 18),
        to_signed(3, 18),    to_signed(1, 18));

    -- Hz per Q16 turn at lag 12: round(54200/12) = 4517 (0.0074% error)
    constant C_R12 : signed(17 downto 0) :=
        to_signed((G_SYMBOL_RATE + 6) / 12, 18);

    -- the seven same-tone lag-12 pairs: window slot indices (0 = oldest of
    -- the 24-symbol window) and the matched tone (1 = y1/A, 2 = y2/B),
    -- from the invariant sync tone sequence (header)
    type idx_t  is array (0 to 6) of natural range 0 to 23;
    type tsel_t is array (0 to 6) of natural range 1 to 2;
    constant C_PI_IDX : idx_t  := (1, 2, 3, 8, 9, 10, 11);
    constant C_PJ_IDX : idx_t  := (13, 14, 15, 20, 21, 22, 23);
    constant C_PTONE  : tsel_t := (1, 1, 1, 2, 1, 2, 2);

    -- sliding window of correlations: slot 0 oldest .. 23 newest
    type win_t is array (0 to 23) of signed(23 downto 0);
    signal w1r, w1i, w2r, w2i : win_t := (others => (others => '0'));
    signal nfill : unsigned(4 downto 0) := (others => '0');

    type ph_t is (P_WAIT, P_ACC, P_NEG, P_NRM, P_CORDIC, P_FIN);
    signal ph : ph_t := P_WAIT;

    signal pidx   : unsigned(2 downto 0) := (others => '0');
    signal acc_re : signed(51 downto 0) := (others => '0');
    signal acc_im : signed(51 downto 0) := (others => '0');
    signal cx, cy : signed(19 downto 0) := (others => '0');
    signal cz     : signed(17 downto 0) := (others => '0');
    signal ci     : unsigned(3 downto 0) := (others => '0');
    signal mag_c  : unsigned(51 downto 0) := (others => '0');

    -- per-symbol result ring (64 deep; searched on each strobe)
    type fring_t is array (0 to 63) of signed(15 downto 0);
    type mring_t is array (0 to 63) of unsigned(51 downto 0);
    signal ferr_ring : fring_t := (others => (others => '0'));
    signal mag_ring  : mring_t := (others => (others => '0'));
    signal wptr      : unsigned(5 downto 0) := (others => '0');

    signal pend   : std_logic := '0';
    signal o_ferr : signed(15 downto 0) := (others => '0');
    signal o_valid: std_logic := '0';
    signal o_mag  : unsigned(15 downto 0) := (others => '0');

begin

    da_ferr_hz <= o_ferr;
    da_valid   <= o_valid;
    da_mag     <= o_mag;

    main : process(clk)
        variable ri, ii, rj, ij : signed(23 downto 0);
        variable pre, pim       : signed(48 downto 0);
        variable are, aim       : signed(51 downto 0);
        variable nx, ny         : signed(19 downto 0);
        variable magv           : unsigned(51 downto 0);
        variable ferr36         : signed(35 downto 0);
        variable bestm          : unsigned(51 downto 0);
        variable bestf          : signed(15 downto 0);
        variable slot           : integer;
    begin
        if rising_edge(clk) then
            o_valid <= '0';
            if rst = '1' then
                -- RESET BRANCH IS TRUTH (mirrors declaration initializers)
                w1r <= (others => (others => '0'));
                w1i <= (others => (others => '0'));
                w2r <= (others => (others => '0'));
                w2i <= (others => (others => '0'));
                nfill <= (others => '0');
                ph <= P_WAIT; pidx <= (others => '0');
                acc_re <= (others => '0'); acc_im <= (others => '0');
                cx <= (others => '0'); cy <= (others => '0');
                cz <= (others => '0'); ci <= (others => '0');
                mag_c <= (others => '0');
                ferr_ring <= (others => (others => '0'));
                mag_ring  <= (others => (others => '0'));
                wptr <= (others => '0');
                pend <= '0';
                o_ferr <= (others => '0'); o_valid <= '0';
                o_mag <= (others => '0');
            else
                -- catch the detector's strobe whenever it arrives; served
                -- at the next P_FIN (ring is then current to the symbol)
                if sync_seen = '1' then
                    pend <= '1';
                end if;

                case ph is
                    when P_WAIT =>
                        if y_valid = '1' then
                            for k in 0 to 22 loop
                                w1r(k) <= w1r(k+1); w1i(k) <= w1i(k+1);
                                w2r(k) <= w2r(k+1); w2i(k) <= w2i(k+1);
                            end loop;
                            w1r(23) <= y1_re; w1i(23) <= y1_im;
                            w2r(23) <= y2_re; w2i(23) <= y2_im;
                            if nfill /= 24 then
                                nfill <= nfill + 1;
                            end if;
                            acc_re <= (others => '0');
                            acc_im <= (others => '0');
                            pidx <= (others => '0');
                            ph <= P_ACC;
                        end if;

                    when P_ACC =>
                        -- one same-tone lag-12 product per clock:
                        -- NEW * conj(OLD)  (cfo_afc ordering)
                        if nfill = 24 then
                            if C_PTONE(to_integer(pidx)) = 1 then
                                ri := w1r(C_PI_IDX(to_integer(pidx)));
                                ii := w1i(C_PI_IDX(to_integer(pidx)));
                                rj := w1r(C_PJ_IDX(to_integer(pidx)));
                                ij := w1i(C_PJ_IDX(to_integer(pidx)));
                            else
                                ri := w2r(C_PI_IDX(to_integer(pidx)));
                                ii := w2i(C_PI_IDX(to_integer(pidx)));
                                rj := w2r(C_PJ_IDX(to_integer(pidx)));
                                ij := w2i(C_PJ_IDX(to_integer(pidx)));
                            end if;
                            -- new * conj(old):
                            --   re = rj*ri + ij*ii ; im = ij*ri - rj*ii
                            pre := resize(rj*ri, 49) + resize(ij*ii, 49);
                            pim := resize(ij*ri, 49) - resize(rj*ii, 49);
                            acc_re <= acc_re + resize(pre, 52);
                            acc_im <= acc_im + resize(pim, 52);
                        end if;
                        if pidx = 6 then
                            ph <= P_NEG;
                        else
                            pidx <= pidx + 1;
                        end if;

                    when P_NEG =>
                        -- the entire correction ROM: one global negation
                        -- (every used pair's data phase is exactly pi)
                        acc_re <= -acc_re;
                        acc_im <= -acc_im;
                        mag_c  <= unsigned(abs(acc_re)) +
                                  unsigned(abs(acc_im));
                        ph <= P_NRM;

                    when P_NRM =>
                        are := acc_re; aim := acc_im;
                        if are > 131071 or are < -131072 or
                           aim > 131071 or aim < -131072 then
                            acc_re <= shift_right(are, 2);
                            acc_im <= shift_right(aim, 2);
                        elsif (unsigned(abs(are)) + unsigned(abs(aim))) < 64
                        then
                            -- dead air: no angle information
                            cz <= (others => '0');
                            ph <= P_FIN;
                        else
                            -- quadrant fold into the right half plane
                            if are < 0 then
                                cx <= resize(-signed(are(19 downto 0)), 20);
                                cy <= resize(-signed(aim(19 downto 0)), 20);
                                if aim >= 0 then
                                    cz <= to_signed(-32768, 18);
                                else
                                    cz <= to_signed(32768, 18);
                                end if;
                            else
                                cx <= resize(signed(are(19 downto 0)), 20);
                                cy <= resize(signed(aim(19 downto 0)), 20);
                                cz <= (others => '0');
                            end if;
                            ci <= (others => '0');
                            ph <= P_CORDIC;
                        end if;

                    when P_CORDIC =>
                        nx := cx; ny := cy;
                        if cy >= 0 then
                            cx <= nx + shift_right(ny, to_integer(ci));
                            cy <= ny - shift_right(nx, to_integer(ci));
                            cz <= cz - C_ATAN(to_integer(ci));
                        else
                            cx <= nx - shift_right(ny, to_integer(ci));
                            cy <= ny + shift_right(nx, to_integer(ci));
                            cz <= cz + C_ATAN(to_integer(ci));
                        end if;
                        if ci = 13 then
                            ph <= P_FIN;
                        else
                            ci <= ci + 1;
                        end if;

                    when P_FIN =>
                        -- cz (Q16 turns over 12 symbols) -> antenna-frame Hz
                        -- (sign chain identical to cfo_afc; see header)
                        ferr36 := resize(cz * C_R12, 36);
                        ferr_ring(to_integer(wptr)) <=
                            resize(shift_right(ferr36, 16), 16);
                        mag_ring(to_integer(wptr)) <= mag_c;
                        wptr <= wptr + 1;

                        -- serve a pending detector strobe: search the ring
                        -- G_LAT_SYM +/- G_LAT_WIN symbols back for the
                        -- maximum-|Z| window = the sync's true position
                        if pend = '1' then
                            pend <= '0';
                            bestm := (others => '0');
                            bestf := (others => '0');
                            for d in 0 to 2*G_LAT_WIN loop
                                slot := (to_integer(wptr) + 64
                                         - (G_LAT_SYM - G_LAT_WIN + d))
                                        mod 64;
                                if mag_ring(slot) > bestm then
                                    bestm := mag_ring(slot);
                                    bestf := ferr_ring(slot);
                                end if;
                            end loop;
                            if bestm >= shift_left(to_unsigned(1, 52),
                                                   G_FLOOR_SH) then
                                o_ferr  <= bestf;
                                o_mag   <= resize(shift_right(
                                               bestm, G_FLOOR_SH - 12), 16);
                                o_valid <= '1';
                            end if;
                        end if;
                        ph <= P_WAIT;
                end case;
            end if;
        end if;
    end process main;

end architecture rtl;
