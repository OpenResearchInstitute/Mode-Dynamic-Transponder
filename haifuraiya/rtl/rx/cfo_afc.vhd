-------------------------------------------------------------------------------
-- cfo_afc.vhd -- automatic frequency control: CFO estimator + servo
-------------------------------------------------------------------------------
-- Project : Mode-Dynamic-Transponder / Haifuraiya      License: CERN-OHL-S v2
--
-- WHAT THIS IS (WP2 build step 2; WP2_CFO_DESIGN.md sections 3-5)
--   Measures residual carrier frequency offset from the per-symbol tone
--   correlations the engine already exports, and accumulates the antenna-
--   frame correction word that drives cfo_rotator.  Replaces the human
--   hand on CFO_MANUAL with a measurement loop.
--
-- ALGORITHM (C++ AFC law, opv_demod.hpp ~390, generalized per the ratified
-- design: the delta-phase discriminator IS the estimator -- Mehlan/Chen/
-- Meyr 1993, "the phase of the smoothed signal is an estimate of the
-- carrier frequency offset"):
--   dom      = the larger-|.|^2 of (y1, y2) this symbol
--   pd       = arg( dom * conj(prev_dom) )        [CORDIC vectoring]
--   ferr_hz  = pd_turns * SYMBOL_RATE              (+/- R/2 = +/-27.1 kHz
--                                                   unambiguous ambit)
--   est     += ferr >> alpha_shift                 (two gears, registered)
--
-- CLOSED LOOP + DOMAIN SIGN (both essential, both measured 2026-07-20/21):
--   * The rotator corrects BEFORE the demod, so this block measures the
--     RESIDUAL r = offset - applied.  est += alpha*r is an integrating
--     servo: converges exactly when the residual is nulled.
--   * The y's live in the demod's SWAPPED domain (z' = j*conj(z), the
--     deliberate gq/gi swap in rx_top): conjugation negates frequency,
--     so the measured rotation is MINUS the antenna-frame residual.
--     ferr is therefore negated once, here, where the domain boundary
--     is crossed -- the red/green sign campaign, pre-paid.
--
-- STATE MACHINE (CFO_STATE, map v6 0x0B0) -- the anti-wedge structure:
--   IDLE(0)       reset/init held
--   SEARCH(1)     signal-quality gate: windowed sum |dom| over 64 symbols
--                 must clear the floor before any correction
--   CORRECTING(2) acquisition gear (alpha_acq); -> HELD after the error
--                 stays small for 64 consecutive symbols
--   HELD(3)       tracking gear (alpha_trk); cfo_locked = '1'
--   LOST(4)       quality collapsed: estimate RETAINED (warm), one
--                 window's grace, then -> SEARCH.  Acquisition is a
--                 standing capability, never a boot event: the C++
--                 wedge (KB5MU 2026-07-07, first-chunk-only estimation)
--                 is structurally impossible here.
--
-- GEARS: alpha fields are SHIFT exponents from CFO_CTRL (ratified
-- packing): [15:8] trk (default 10 ~ C++ 0.001), [23:16] acq (default 6
-- = 16x, provisional per decision 2).  Register-adjustable, no rebuild.
--
-- BUDGET: worst path ~45 clocks/symbol of 1845 available.
-- STYLE: VHDL-93; declaration initializers mirror the reset branch.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cfo_afc is
    generic (
        G_SYMBOL_RATE : natural := 54200;
        G_EST_CLAMP_HZ: natural := 20000;   -- beyond spec edge; sweep room
        G_QUAL_FLOOR  : natural := 512      -- windowed floor: locked signal
        -- reads ~6k-22k on this gauge (|re|+|im| >> 4, 64-sym mean);
        -- dead air reads ~0. 512 splits them with 12x margin both ways.
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- per-symbol tone correlations (demod domain), engine exports
        y_valid    : in  std_logic;
        y1_re      : in  signed(23 downto 0);
        y1_im      : in  signed(23 downto 0);
        y2_re      : in  signed(23 downto 0);
        y2_im      : in  signed(23 downto 0);

        -- gears (shift exponents) from CFO_CTRL
        alpha_trk  : in  unsigned(7 downto 0);
        alpha_acq  : in  unsigned(7 downto 0);

        -- outputs
        est_hz     : out signed(15 downto 0);   -- antenna frame, to rotator
        state_o    : out unsigned(2 downto 0);  -- CFO_STATE encoding
        quality    : out unsigned(15 downto 0); -- windowed |dom| gauge
        cfo_locked : out std_logic
    );
end entity cfo_afc;

architecture rtl of cfo_afc is

    -- CORDIC atan table: atan(2^-i) in Q16 TURNS (2pi = 65536), i = 0..13
    type atan_t is array (0 to 13) of signed(17 downto 0);
    constant C_ATAN : atan_t := (
        to_signed(8192, 18), to_signed(4836, 18), to_signed(2555, 18),
        to_signed(1297, 18), to_signed(651, 18),  to_signed(326, 18),
        to_signed(163, 18),  to_signed(81, 18),   to_signed(41, 18),
        to_signed(20, 18),   to_signed(10, 18),   to_signed(5, 18),
        to_signed(3, 18),    to_signed(1, 18));

    constant C_EST_CLAMP_Q16 : signed(35 downto 0) :=
        to_signed(G_EST_CLAMP_HZ * 65536, 36);

    type st_t is (S_IDLE, S_SEARCH, S_CORRECTING, S_HELD, S_LOST);
    signal st : st_t := S_IDLE;

    type ph_t is (P_WAIT, P_MAG, P_SEL, P_PROD, P_NORM, P_CORDIC, P_SERVO);
    signal ph : ph_t := P_WAIT;

    -- captured symbol
    signal c1r, c1i, c2r, c2i : signed(23 downto 0) := (others => '0');
    -- dominant this symbol + PER-TONE previous correlations.
    -- The reference stores prev_corr_f1_ AND prev_corr_f2_ every symbol
    -- and compares dominant against ITS OWN tone's previous
    -- (opv_demod.hpp:390-409): a tone's correlation rotates at the
    -- offset rate whether or not it is dominant, so same-tone deltas
    -- always measure the offset. A single cross-tone prev (this block's
    -- first port) measures tone separation on switches and biased the
    -- servo to a false equilibrium (measured: est stalled 677 Hz short,
    -- 2026-07-21 system bench).
    signal dr, di, pr, pi     : signed(23 downto 0) := (others => '0');
    signal p1r, p1i, p2r, p2i : signed(23 downto 0) := (others => '0');
    signal have_prev          : std_logic := '0';
    -- magnitude compare
    signal m1, m2             : signed(47 downto 0) := (others => '0');
    -- conjugate product (dot = re, cross = im)
    signal dotp, crossp       : signed(47 downto 0) := (others => '0');
    -- normalized CORDIC operands / iterator
    signal cx, cy             : signed(19 downto 0) := (others => '0');
    signal cz                 : signed(17 downto 0) := (others => '0');
    signal ci                 : unsigned(3 downto 0) := (others => '0');
    -- servo
    signal est_q16            : signed(35 downto 0) := (others => '0');
    -- quality window (64 symbols)
    signal q_acc              : unsigned(29 downto 0) := (others => '0');
    signal q_win              : unsigned(15 downto 0) := (others => '0');
    signal q_cnt              : unsigned(5 downto 0)  := (others => '0');
    -- dwell counters
    signal good_cnt           : unsigned(6 downto 0) := (others => '0');
    signal lost_cnt           : unsigned(6 downto 0) := (others => '0');
    -- HELD gate: estimate snapshot at each 64-symbol window boundary.
    -- The dwell criterion judges ESTIMATE STABILITY (|est - est_64ago|
    -- < 200 Hz), not per-symbol ferr: the raw discriminator is
    -- intrinsically spiky on real data (measured 2026-07-21: servo
    -- converged tightly on -5000 while a ferr-based consecutive gate
    -- never fired). The C++ has no lock gate at all -- one gear, free
    -- integration -- so this criterion is ours; it watches the quantity
    -- the flag actually claims.
    signal est_snap           : signed(35 downto 0) := (others => '0');

begin

    est_hz     <= resize(shift_right(est_q16, 16), 16);
    quality    <= q_win;
    cfo_locked <= '1' when st = S_HELD else '0';

    with st select state_o <=
        to_unsigned(0, 3) when S_IDLE,
        to_unsigned(1, 3) when S_SEARCH,
        to_unsigned(2, 3) when S_CORRECTING,
        to_unsigned(3, 3) when S_HELD,
        to_unsigned(4, 3) when others;

    main : process(clk)
        variable a1, a2, ad   : signed(24 downto 0);
        variable ferr_hz_v    : signed(35 downto 0);
        variable shv          : signed(7 downto 0);
        variable nx, ny       : signed(19 downto 0);
        variable adj          : signed(35 downto 0);
        variable mx           : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- RESET BRANCH IS TRUTH (mirrors declaration initializers)
                st <= S_IDLE; ph <= P_WAIT;
                c1r <= (others=>'0'); c1i <= (others=>'0');
                c2r <= (others=>'0'); c2i <= (others=>'0');
                dr <= (others=>'0'); di <= (others=>'0');
                pr <= (others=>'0'); pi <= (others=>'0');
                p1r <= (others=>'0'); p1i <= (others=>'0');
                p2r <= (others=>'0'); p2i <= (others=>'0');
                have_prev <= '0';
                m1 <= (others=>'0'); m2 <= (others=>'0');
                dotp <= (others=>'0'); crossp <= (others=>'0');
                cx <= (others=>'0'); cy <= (others=>'0');
                cz <= (others=>'0'); ci <= (others=>'0');
                est_q16 <= (others=>'0');
                q_acc <= (others=>'0'); q_win <= (others=>'0');
                q_cnt <= (others=>'0');
                good_cnt <= (others=>'0'); lost_cnt <= (others=>'0');
            else
                if st = S_IDLE then
                    st <= S_SEARCH;
                end if;

                case ph is
                    when P_WAIT =>
                        if y_valid = '1' then
                            c1r <= y1_re; c1i <= y1_im;
                            c2r <= y2_re; c2i <= y2_im;
                            ph <= P_MAG;
                        end if;

                    when P_MAG =>
                        -- |y|^2 exact (products fit 47 bits)
                        m1 <= resize(c1r*c1r, 48) + resize(c1i*c1i, 48);
                        m2 <= resize(c2r*c2r, 48) + resize(c2i*c2i, 48);
                        ph <= P_SEL;

                    when P_SEL =>
                        -- dominant pair AND its own tone's previous pair
                        if m1 >= m2 then
                            dr <= c1r; di <= c1i; pr <= p1r; pi <= p1i;
                        else
                            dr <= c2r; di <= c2i; pr <= p2r; pi <= p2i;
                        end if;
                        -- quality: |re|+|im| of dominant, windowed 64 sym
                        if m1 >= m2 then
                            a1 := abs(resize(c1r, 25)); a2 := abs(resize(c1i, 25));
                        else
                            a1 := abs(resize(c2r, 25)); a2 := abs(resize(c2i, 25));
                        end if;
                        ad := a1 + a2;
                        q_acc <= q_acc + resize(unsigned(std_logic_vector(
                                    shift_right(ad, 4)(20 downto 0))), 30);
                        if q_cnt = 63 then
                            q_win <= resize(shift_right(q_acc, 6), 16);
                            q_acc <= (others => '0');
                            q_cnt <= (others => '0');
                        else
                            q_cnt <= q_cnt + 1;
                        end if;
                        ph <= P_PROD;

                    when P_PROD =>
                        -- dom * conj(same-tone prev): dot = dr*pr + di*pi,
                        --                             cross = di*pr - dr*pi
                        dotp   <= resize(dr*pr, 48) + resize(di*pi, 48);
                        crossp <= resize(di*pr, 48) - resize(dr*pi, 48);
                        -- store BOTH tones' correlations, every symbol
                        -- (reference verbatim: prev_corr_f1_/f2_ updated
                        -- unconditionally at the bottom of the loop)
                        p1r <= c1r; p1i <= c1i;
                        p2r <= c2r; p2i <= c2i;
                        if have_prev = '1' then
                            ph <= P_NORM;
                        else
                            have_prev <= '1';
                            ph <= P_WAIT;
                        end if;

                    when P_NORM =>
                        -- scale both operands down 2 bits/clock until they
                        -- fit 18 bits (angle invariant under common scale)
                        if dotp >  131071 or dotp <  -131072 or
                           crossp > 131071 or crossp < -131072 then
                            dotp   <= shift_right(dotp, 2);
                            crossp <= shift_right(crossp, 2);
                        elsif (abs(dotp) + abs(crossp)) < 64 then
                            -- degenerate (dead air): no angle information.
                            -- CORDIC on ~(0,0) fabricates a full-scale
                            -- angle (measured: est drifted during T3);
                            -- report ferr=0 instead and let the quality
                            -- window drive the state machine.
                            cz <= (others => '0');
                            ph <= P_SERVO;
                        else
                            -- quadrant fold into the right half plane
                            if dotp < 0 then
                                cx <= resize(-signed(dotp(19 downto 0)), 20);
                                cy <= resize(-signed(crossp(19 downto 0)), 20);
                                if crossp >= 0 then
                                    cz <= to_signed(-32768, 18);  -- +pi
                                else
                                    cz <= to_signed(32768, 18);   -- -pi
                                end if;
                            else
                                cx <= resize(signed(dotp(19 downto 0)), 20);
                                cy <= resize(signed(crossp(19 downto 0)), 20);
                                cz <= (others => '0');
                            end if;
                            ci <= (others => '0');
                            ph <= P_CORDIC;
                        end if;

                    when P_CORDIC =>
                        -- vectoring: drive cy to zero, accumulate angle in cz
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
                            ph <= P_SERVO;
                        else
                            ci <= ci + 1;
                        end if;

                    when P_SERVO =>
                        -- cz = -pd in Q16 turns (vectoring accumulates the
                        -- NEGATIVE of the input angle).  The demod-domain
                        -- conjugation supplies the OTHER negation (header):
                        -- the two cancel, so cz*R IS antenna-frame ferr.
                        ferr_hz_v := resize(cz * to_signed(G_SYMBOL_RATE, 18), 36);
                        -- ferr in Q16 Hz (cz Q16 turns * R Hz/turn)

                        if st = S_CORRECTING or st = S_HELD then
                            if st = S_HELD then
                                shv := signed(resize(alpha_trk, 8));
                            else
                                shv := signed(resize(alpha_acq, 8));
                            end if;
                            adj := shift_right(ferr_hz_v, to_integer(unsigned(shv)));
                            mx  := resize(est_q16, 48) + resize(adj, 48);
                            if mx > resize(C_EST_CLAMP_Q16, 48) then
                                est_q16 <= C_EST_CLAMP_Q16;
                            elsif mx < -resize(C_EST_CLAMP_Q16, 48) then
                                est_q16 <= -C_EST_CLAMP_Q16;
                            else
                                est_q16 <= resize(mx, 36);
                            end if;
                        end if;

                        -- state walk (evaluated once per symbol)
                        case st is
                            when S_SEARCH =>
                                good_cnt <= (others => '0');
                                if q_win >= G_QUAL_FLOOR then
                                    st <= S_CORRECTING;
                                end if;
                            when S_CORRECTING =>
                                if q_win < G_QUAL_FLOOR and q_win /= 0 then
                                    st <= S_LOST; lost_cnt <= (others => '0');
                                elsif q_cnt = 0 then
                                    -- window boundary: estimate stable
                                    -- across the whole window -> HELD
                                    if (est_q16 - est_snap) < 13107200 and
                                       (est_q16 - est_snap) > -13107200 then
                                        st <= S_HELD;
                                    end if;
                                    est_snap <= est_q16;
                                end if;
                            when S_HELD =>
                                -- HYSTERESIS (2026-07-21: state flapped
                                -- 2<->3 on real data because this exit
                                -- judged noisy per-symbol ferr -- the
                                -- same defect evicted from the entry
                                -- gate). Enter under 200 Hz/window;
                                -- leave only over 400 Hz/window of
                                -- ESTIMATE movement. A genuine step
                                -- moves the estimate ~500 Hz/window
                                -- even in the tracking gear, so real
                                -- steps still downshift within one
                                -- window, 1.2 ms (bench T2).
                                if q_win < G_QUAL_FLOOR then
                                    st <= S_LOST; lost_cnt <= (others => '0');
                                elsif q_cnt = 0 then
                                    if (est_q16 - est_snap) > 26214400 or
                                       (est_q16 - est_snap) < -26214400 then
                                        st <= S_CORRECTING;
                                    end if;
                                    est_snap <= est_q16;
                                end if;
                            when S_LOST =>
                                -- estimate retained (warm start); one
                                -- window of grace, then re-search
                                if q_win >= G_QUAL_FLOOR then
                                    st <= S_CORRECTING;
                                    good_cnt <= (others => '0');
                                elsif lost_cnt = 64 then
                                    st <= S_SEARCH;
                                else
                                    lost_cnt <= lost_cnt + 1;
                                end if;
                            when others => null;
                        end case;

                        ph <= P_WAIT;
                end case;
            end if;
        end if;
    end process main;

end architecture rtl;
