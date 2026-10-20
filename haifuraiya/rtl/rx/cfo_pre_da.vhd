-------------------------------------------------------------------------------
-- cfo_pre_da.vhd -- preamble-anchored DATA-AIDED carrier frequency measurement
-------------------------------------------------------------------------------
-- Project : Mode-Dynamic-Transponder / Haifuraiya      License: CERN-OHL-S v2
--
-- WHAT THIS IS (F5b, 2026-10-19; parity table stage 1)
--   The fabric equivalent of the C++ reference's estimate_offset(): the
--   carrier is measured DURING THE PREAMBLE, before the first sync word
--   arrives, so data frame 1 is demodulated start-to-finish with a correct
--   word.  Like cfo_sync_da (F4), the measurement is data-aided -- built
--   on KNOWN transmitted structure, no symbol decisions anywhere -- so the
--   decision-directed threshold bias cannot exist here at any SNR.
--
-- MEASUREMENT (numerically derived from the modulator's own diff encoding,
-- 2026-10-19, machine precision):
--   The preamble (2168 raw bits of 0xCC, no FEC, no sync) maps through the
--   differential MSK precoder to the tone sequence  B B A A  repeating
--   (period 4), with EVERY symbol's matched correlation at the SAME phase:
--   every lag-4 pair is same-tone with data-phase correction exactly ZERO
--   (spread < 1e-13 over all 2164 pairs).  No phase ROM, no negation:
--
--     Z = SUM over a window of  ( y1[t]*conj(y1[t-4])
--                               + y2[t]*conj(y2[t-4]) )
--     ferr = arg(Z) / (2*pi*4) * SYMBOL_RATE
--
--   BOTH tone rails are summed blind (the pattern's phase is unknown at
--   startup): the matched rail adds coherently, the unmatched rail is
--   junk*junk, zero mean.  Verified unbiased to < 0.01 Hz at offsets 0,
--   +/-120, +509, +/-1500, -2000, +6000 against the exact waveform.
--   Unambiguous range +/- R/8 = +/-6775 Hz (wider than the C++ grid's
--   +/-1500).  Accuracy (numerical model, Eb/N0 = 10 dB, 256-symbol
--   window): sigma ~ 25 Hz, max |error| ~ 40 Hz -- one window puts the
--   word inside the ~195 Hz slip cliff; the 40 ms preamble holds eight.
--
-- DETECTION (division of labor, deliberately DIFFERENT from cfo_sync_da):
--   The sync-anchored block needs the frame sync detector's strobe because
--   7 pairs give only ~sqrt(7) discrimination.  Here a window accumulates
--   up to 512 products COHERENTLY (every product has the same phase
--   -2*pi*f*4/R regardless of position), so the preamble announces itself:
--   measured at 10 dB, the weakest full-preamble window's |Z| beats the
--   strongest payload window's by 6.3x.  The magnitude floor G_FLOOR_SH
--   sits between them, so this block self-gates -- no external strobe.
--   Windows straddling the preamble's edges pass the floor only when
--   mostly preamble, and then measure within ~100 Hz; the sync-anchored
--   measurement at the first frame (F5a full-weight gear) re-corrects any
--   trailing-window wobble.  Nothing here runs once: a preamble after
--   signal loss re-measures automatically (anti-wedge: acquisition is a
--   standing capability).
--
-- CONSUMER: cfo_afc's pre_ferr/pre_valid/pre_ena port (F5b).  Applied at
--   full weight while frame sync is NOT locked; ignored while locked (the
--   sync-anchored path owns the word there).  The servo holds the
--   decision-directed integrator for G_PRE_HOLD symbols after each accept,
--   so the biased dd path cannot drag the word between windows.
--
-- SIGN CONVENTION: products are ordered NEW * conj(OLD), the same order as
--   cfo_afc's dom*conj(prev) and cfo_sync_da's pairs; the demod-domain
--   double-negation note in cfo_afc.vhd's header applies unchanged, so
--   cz * (R/4) IS antenna-frame ferr.  No data-phase negation (the sync
--   word's pairs sit at pi; the preamble's sit at 0).  Asserted in
--   tb_cfo_pre_da with the same demod-domain model tb_cfo_sync_da uses.
--
-- BUDGET: 2 product clocks per symbol + (per window) magnitude, normalize
--   (<= 15 shifts), 14 CORDIC, emit ~= 35 clocks per 256 symbols, of 1845
--   available per symbol.
-- STYLE: VHDL-93; declaration initializers mirror the reset branch.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cfo_pre_da is
    generic (
        G_SYMBOL_RATE : natural := 54200;
        -- window length, log2 (256 symbols = 4.7 ms; 8 windows per preamble)
        G_WIN_LOG2    : natural := 8;
        -- magnitude floor on |Z| ~ (|re|+|im|) at window end.  Its ONLY job
        -- now is to reject dead-air / noise windows; preamble-vs-payload
        -- discrimination is NOT needed here, because cfo_afc only uses these
        -- measurements during acquisition (in_acq) and ignores them on
        -- payload.  So the floor is set LOW and robust -- matched to the
        -- in-system level that cfo_sync_da's floor (2^33) proved rejects
        -- dead air at this normalized |y| -- rather than tuned to split
        -- preamble from payload (the 2^41 bench value did NOT survive the
        -- real normalized level and silently rejected every window,
        -- 2026-10-20).  A full preamble window (~2^42) clears 2^33 with
        -- large margin; dead air does not.
        G_FLOOR_SH    : natural := 33
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- per-symbol tone correlations (demod domain), engine exports --
        -- the same taps cfo_afc and cfo_sync_da consume
        y_valid    : in  std_logic;
        y1_re      : in  signed(23 downto 0);
        y1_im      : in  signed(23 downto 0);
        y2_re      : in  signed(23 downto 0);
        y2_im      : in  signed(23 downto 0);

        -- one measurement per window that clears the floor
        pre_ferr_hz : out signed(15 downto 0);   -- antenna frame
        pre_valid   : out std_logic;             -- 1-clk strobe
        pre_mag     : out unsigned(15 downto 0)  -- |Z| gauge at accept
    );
end entity cfo_pre_da;

architecture rtl of cfo_pre_da is

    -- CORDIC atan table: atan(2^-i) in Q16 TURNS (2pi = 65536), i = 0..13
    -- (verbatim from cfo_afc.vhd / cfo_sync_da.vhd)
    type atan_t is array (0 to 13) of signed(17 downto 0);
    constant C_ATAN : atan_t := (
        to_signed(8192, 18), to_signed(4836, 18), to_signed(2555, 18),
        to_signed(1297, 18), to_signed(651, 18),  to_signed(326, 18),
        to_signed(163, 18),  to_signed(81, 18),   to_signed(41, 18),
        to_signed(20, 18),   to_signed(10, 18),   to_signed(5, 18),
        to_signed(3, 18),    to_signed(1, 18));

    -- Hz per Q16 turn at lag 4: 54200/4 = 13550 (exact)
    constant C_R4 : signed(17 downto 0) :=
        to_signed((G_SYMBOL_RATE + 2) / 4, 18);

    -- 4-symbol delay lines, both rails (slot 0 oldest = y[t-4] after shift)
    type dly_t is array (0 to 3) of signed(23 downto 0);
    signal d1r, d1i, d2r, d2i : dly_t := (others => (others => '0'));
    signal nfill : unsigned(2 downto 0) := (others => '0');

    -- latched operands for the product clocks
    signal c1r, c1i, c2r, c2i : signed(23 downto 0) := (others => '0');
    signal o1r, o1i, o2r, o2i : signed(23 downto 0) := (others => '0');

    type ph_t is (P_WAIT, P_ACC1, P_ACC2, P_MAG, P_NRM, P_CORDIC, P_FIN);
    signal ph : ph_t := P_WAIT;

    -- window accumulator: product is 49 bits; 2^(G_WIN_LOG2+1) products
    -- -> 49 + G_WIN_LOG2 + 1 = 58 bits at the default window
    signal acc_re : signed(57 downto 0) := (others => '0');
    signal acc_im : signed(57 downto 0) := (others => '0');
    signal wcnt   : unsigned(G_WIN_LOG2 downto 0) := (others => '0');
    signal cx, cy : signed(19 downto 0) := (others => '0');
    signal cz     : signed(17 downto 0) := (others => '0');
    signal ci     : unsigned(3 downto 0) := (others => '0');
    signal mag_c  : unsigned(57 downto 0) := (others => '0');

    signal o_ferr : signed(15 downto 0) := (others => '0');
    signal o_valid: std_logic := '0';
    signal o_mag  : unsigned(15 downto 0) := (others => '0');

begin

    pre_ferr_hz <= o_ferr;
    pre_valid   <= o_valid;
    pre_mag     <= o_mag;

    main : process(clk)
        variable pre, pim : signed(48 downto 0);
        variable are, aim : signed(57 downto 0);
        variable nx, ny   : signed(19 downto 0);
        variable ferr36   : signed(35 downto 0);
    begin
        if rising_edge(clk) then
            o_valid <= '0';
            if rst = '1' then
                -- RESET BRANCH IS TRUTH (mirrors declaration initializers)
                d1r <= (others => (others => '0'));
                d1i <= (others => (others => '0'));
                d2r <= (others => (others => '0'));
                d2i <= (others => (others => '0'));
                nfill <= (others => '0');
                c1r <= (others => '0'); c1i <= (others => '0');
                c2r <= (others => '0'); c2i <= (others => '0');
                o1r <= (others => '0'); o1i <= (others => '0');
                o2r <= (others => '0'); o2i <= (others => '0');
                ph <= P_WAIT;
                acc_re <= (others => '0'); acc_im <= (others => '0');
                wcnt <= (others => '0');
                cx <= (others => '0'); cy <= (others => '0');
                cz <= (others => '0'); ci <= (others => '0');
                mag_c <= (others => '0');
                o_ferr <= (others => '0'); o_valid <= '0';
                o_mag <= (others => '0');
            else
                case ph is
                    when P_WAIT =>
                        if y_valid = '1' then
                            -- latch NEW and OLD(lag 4) operands, then shift
                            c1r <= y1_re; c1i <= y1_im;
                            c2r <= y2_re; c2i <= y2_im;
                            o1r <= d1r(0); o1i <= d1i(0);
                            o2r <= d2r(0); o2i <= d2i(0);
                            for k in 0 to 2 loop
                                d1r(k) <= d1r(k+1); d1i(k) <= d1i(k+1);
                                d2r(k) <= d2r(k+1); d2i(k) <= d2i(k+1);
                            end loop;
                            d1r(3) <= y1_re; d1i(3) <= y1_im;
                            d2r(3) <= y2_re; d2i(3) <= y2_im;
                            if nfill /= 4 then
                                nfill <= nfill + 1;
                            end if;
                            ph <= P_ACC1;
                        end if;

                    when P_ACC1 =>
                        -- rail 1: NEW * conj(OLD)
                        --   re = c1r*o1r + c1i*o1i ; im = c1i*o1r - c1r*o1i
                        if nfill = 4 then
                            pre := resize(c1r*o1r, 49) + resize(c1i*o1i, 49);
                            pim := resize(c1i*o1r, 49) - resize(c1r*o1i, 49);
                            acc_re <= acc_re + resize(pre, 58);
                            acc_im <= acc_im + resize(pim, 58);
                        end if;
                        ph <= P_ACC2;

                    when P_ACC2 =>
                        -- rail 2: NEW * conj(OLD); then close the window when
                        -- 2^G_WIN_LOG2 symbols have contributed
                        if nfill = 4 then
                            pre := resize(c2r*o2r, 49) + resize(c2i*o2i, 49);
                            pim := resize(c2i*o2r, 49) - resize(c2r*o2i, 49);
                            acc_re <= acc_re + resize(pre, 58);
                            acc_im <= acc_im + resize(pim, 58);
                        end if;
                        if wcnt = to_unsigned(2**G_WIN_LOG2 - 1,
                                              G_WIN_LOG2 + 1) then
                            wcnt <= (others => '0');
                            ph <= P_MAG;
                        else
                            wcnt <= wcnt + 1;
                            ph <= P_WAIT;
                        end if;

                    when P_MAG =>
                        mag_c <= unsigned(abs(acc_re)) +
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
                            -- dead air / junk window: no angle information
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
                        -- cz (Q16 turns over 4 symbols) -> antenna-frame Hz
                        -- (sign chain identical to cfo_sync_da minus the
                        -- data-phase negation; see header)
                        ferr36 := resize(cz * C_R4, 36);
                        if mag_c >= shift_left(to_unsigned(1, 58),
                                               G_FLOOR_SH) then
                            o_ferr  <= resize(shift_right(ferr36, 16), 16);
                            o_mag   <= resize(shift_right(
                                           mag_c, G_FLOOR_SH - 12), 16);
                            o_valid <= '1';
                        end if;
                        acc_re <= (others => '0');
                        acc_im <= (others => '0');
                        ph <= P_WAIT;
                end case;
            end if;
        end if;
    end process main;

end architecture rtl;
