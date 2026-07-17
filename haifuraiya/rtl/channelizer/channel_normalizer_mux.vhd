------------------------------------------------------------------------------
-- channel_normalizer_mux.vhd
-- Per-channel feed-forward gain node for the Haifuraiya / MDT receiver.
------------------------------------------------------------------------------
-- Open Research Institute.  License: CERN-OHL-S-2.0
--
-- WHAT IT IS
--
--     gain = GAIN_TARGET / sqrt( max(channel_power, SQUELCH_THR) )
--     out  = saturate( round( in * gain ) )
--
--   That is the whole block. channel_power is I^2+Q^2, already measured per
--   channel by the existing power_detector. Nothing here measures anything.
--
-- WHERE IT GOES
--
--     chan_re_q --> channel_eq --+--> 64x power_detector  (sees UN-normalized)
--                                |
--                                +--> THIS BLOCK --> m_axis_chans --> demod
--
--   Sense before, correct after. The gain is computed from a measurement taken
--   UPSTREAM of the gain, so nothing the gain does can change the measurement.
--   This is FEED-FORWARD, not a control loop. Moving this block to where the
--   OUTPUT_SHIFT requantize lives would put the power detectors downstream of
--   the gain and turn it into a slow hidden feedback loop.
--
-- WHY IT EXISTS
--   The demod's 3-bit soft quantizer has FIXED thresholds. Measured on real OPV
--   frames through the real msk_demodulator, mean|rx_data_soft| is LINEAR in
--   input amplitude over five octaves. So fixed thresholds are correct at
--   exactly one input level. Without this block the soft path is a hard-decision
--   device everywhere else, and R=1/2 K=7 Viterbi gives up ~2 dB of coding gain.
--
--   Haifuraiya has NO RF AGC, and must not: 64 stations share one ADC, so an RF
--   AGC would see only the composite and one loud station keying up would
--   desense the other 63. This block is the ONLY gain control in the chain.
--
-- STATE
--   None. Per channel or otherwise. power_detector already holds the per-channel
--   state; this block is a pure function of (in_i, in_q, power) plus config.
--   in_chan and in_last are carried through only to stay aligned with the data.
--
-- BYPASS
--   gain_mode='0' multiplies by gain_manual and nothing else. With
--   gain_manual = 0x0400 (unity, Q6.10) the output is bit-for-bit identical to
--   the input. This is the RESET DEFAULT: a receiver that has never been
--   configured behaves exactly as it did before this block existed.
--
-- THE GAIN LAW, IN FIXED POINT
--   Let p = max(power, squelch_thr), and p = m * 2^e with m in [1,2).
--
--     gain = T / sqrt(p) = T * invsqrt(m) * 2^(-e/2)
--
--   e/2 is not an integer for odd e, so the exponent parity is folded into the
--   ROM: rom(0, m) = 2^ROM_FRAC / sqrt(m), rom(1, m) = 2^ROM_FRAC / sqrt(2m).
--   Then a plain right shift by e/2 finishes it. No divider, no sqrt.
--
--     gain_q610 = ( T * rom(e mod 2, frac(m)) ) >> (ROM_FRAC + e/2 - GAIN_FRAC)
--
--   MEASURED (python model, 60 dB amplitude sweep, MANT_FRAC=6):
--     worst gain-law error 0.017 dB; output amplitude within 0.015 dB of TARGET.
--   An earlier draft quantized the gain to whole octaves (3.01 dB steps). That
--   cost 40% of the soft codes against the reference decoder. Do not coarsen it.
--
-- THE SQUELCH FLOOR
--   gain = T/sqrt(p) grows without bound as p -> 0. An empty channel would be
--   amplified to full scale. squelch_thr is the floor. It is ALSO the
--   channel-active threshold the transponder needs. One register, two jobs.
--
--   HARD CONSTRAINT, asserted below: the Q6.10 gain word cannot exceed 63.99x,
--   so squelch_thr must satisfy
--         squelch_thr >= (gain_target * 2^GAIN_FRAC / GAIN_MAX)^2
--   or the CEILING clamps before the FLOOR does, and squelch_thr becomes inert.
--
-- LATENCY
--   5 clocks, in_valid -> out_valid. out_valid, out_chan and out_last travel
--   WITH the data. Feeding a downstream block the raw upstream valid instead
--   gives a uniform one-sample delay that still decodes and still locks -- it
--   fails silently.
--
-- VHDL-93 CLEAN. Vivado 2022.2 assumes VHDL-93 for a .vhd file unless told
-- otherwise; GHDL and nvc default to 2008 and accept constructs (conditional
-- signal assignment inside a process) that synthesis rejects.
-- ieee.math_real is used ONLY to build a constant ROM at elaboration.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity channel_normalizer_mux is
    generic (
        DATA_W    : positive := 16;   -- channel I/Q width
        CHAN_W    : positive := 6;    -- TDEST width carried through
        GAIN_W    : positive := 16;   -- Q6.10, matches GAIN_MANUAL (0x030)
        GAIN_FRAC : positive := 10;
        POWER_W   : positive := 31;   -- I^2+Q^2 for DATA_W=16
        MANT_FRAC : positive := 6;    -- reciprocal-sqrt ROM: 2^(MANT_FRAC+1) entries
        ROM_FRAC  : positive := 15    -- ROM fixed-point fraction
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- the equalizer's time-multiplexed channel stream
        in_valid    : in  std_logic;
        in_chan     : in  unsigned(CHAN_W - 1 downto 0);
        in_last     : in  std_logic;
        in_i        : in  signed(DATA_W - 1 downto 0);
        in_q        : in  signed(DATA_W - 1 downto 0);

        -- I^2+Q^2 for THIS beat's channel, from power_detector.
        -- Same units as CHANNEL_POWER[k] in the AXI map / Bouro.
        power       : in  std_logic_vector(POWER_W - 1 downto 0);

        -- === the three registers ===
        gain_mode   : in  std_logic;                              -- 0=bypass 1=auto
        gain_target : in  std_logic_vector(GAIN_W - 1 downto 0);  -- setpoint, counts
        squelch_thr : in  std_logic_vector(POWER_W - 1 downto 0); -- floor + activity
        -- (gain_manual already exists in the register map at 0x030)
        gain_manual : in  std_logic_vector(GAIN_W - 1 downto 0);

        out_valid   : out std_logic;
        out_chan    : out unsigned(CHAN_W - 1 downto 0);
        out_last    : out std_logic;
        out_i       : out signed(DATA_W - 1 downto 0);
        out_q       : out signed(DATA_W - 1 downto 0);

        -- telemetry
        gain_current : out std_logic_vector(GAIN_W - 1 downto 0);
        gain_sat     : out std_logic   -- this beat clipped; OUTPUT_SHIFT is too low
    );
end entity channel_normalizer_mux;

architecture rtl of channel_normalizer_mux is

    constant LATENCY : positive := 5;
    constant PROD_W  : positive := DATA_W + GAIN_W + 1;
    constant MAX_POS : signed(DATA_W - 1 downto 0) := to_signed(2**(DATA_W-1) - 1, DATA_W);
    constant MAX_NEG : signed(DATA_W - 1 downto 0) := to_signed(-(2**(DATA_W-1)), DATA_W);
    constant GAIN_MAX : natural := 2**GAIN_W - 1;
    constant NFRAC    : natural := 2**MANT_FRAC;

    ---------------------------------------------------------------------------
    -- Reciprocal-square-root ROM, built at elaboration. Indexed by
    -- {exponent parity, MANT_FRAC fractional bits of the mantissa}.
    --   rom(0, i) = 2^ROM_FRAC / sqrt(m)      m = 1 + (i+0.5)/NFRAC
    --   rom(1, i) = 2^ROM_FRAC / sqrt(2m)
    -- The +0.5 evaluates at the BIN MIDPOINT, which halves the error and makes
    -- it two-sided instead of always-high.
    ---------------------------------------------------------------------------
    type rom_t is array (0 to 2*NFRAC - 1) of unsigned(GAIN_W - 1 downto 0);

    function build_invsqrt_rom return rom_t is
        variable r : rom_t;
        variable m : real;
        variable v : real;
    begin
        for par in 0 to 1 loop
            for i in 0 to NFRAC - 1 loop
                m := 1.0 + (real(i) + 0.5) / real(NFRAC);
                if par = 1 then
                    m := m * 2.0;
                end if;
                v := real(2**ROM_FRAC) / sqrt(m);
                r(par*NFRAC + i) := to_unsigned(integer(floor(v + 0.5)), GAIN_W);
            end loop;
        end loop;
        return r;
    end function;

    constant INVSQRT_ROM : rom_t := build_invsqrt_rom;

    ---------------------------------------------------------------------------
    -- round-half-up then saturate a PROD_W product back to DATA_W
    ---------------------------------------------------------------------------
    function round_sat(p : signed; frac : natural) return signed is
        variable r : signed(p'length - 1 downto 0);
    begin
        r := shift_right(p + to_signed(2**(frac-1), p'length), frac);
        if r > resize(MAX_POS, p'length) then
            return MAX_POS;
        elsif r < resize(MAX_NEG, p'length) then
            return MAX_NEG;
        else
            return resize(r, DATA_W);
        end if;
    end function;

    function saturated(p : signed; frac : natural) return boolean is
        variable r : signed(p'length - 1 downto 0);
    begin
        r := shift_right(p + to_signed(2**(frac-1), p'length), frac);
        return (r > resize(MAX_POS, p'length)) or (r < resize(MAX_NEG, p'length));
    end function;

    -- alignment pipeline: chan/last/valid/data travel with the gain computation
    type i_arr is array (1 to LATENCY-1) of signed(DATA_W-1 downto 0);
    type c_arr is array (1 to LATENCY-1) of unsigned(CHAN_W-1 downto 0);
    signal pi_i, pi_q : i_arr := (others => (others => '0'));
    signal pi_c       : c_arr := (others => (others => '0'));
    signal pi_v, pi_l : std_logic_vector(1 to LATENCY-1) := (others => '0');

    -- gain computation pipeline
    signal s1_p    : unsigned(POWER_W-1 downto 0) := (others => '0');
    signal s2_e    : integer range 0 to POWER_W-1 := 0;
    signal s2_idx  : integer range 0 to 2*NFRAC-1 := 0;
    signal s3_rom  : unsigned(GAIN_W-1 downto 0)  := (others => '0');
    signal s3_sh   : integer range 0 to 63        := ROM_FRAC - GAIN_FRAC;
    signal s4_gain : unsigned(GAIN_W-1 downto 0)  := to_unsigned(2**GAIN_FRAC, GAIN_W);
    signal sat_r   : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Guard the one constraint that silently disables squelch_thr.
    ---------------------------------------------------------------------------
    -- synthesis translate_off
    check_squelch : process(squelch_thr, gain_target)
        variable need : real;
    begin
        -- squelch_thr = 0 means 'floor explicitly disabled'; do not warn.
        if to_integer(unsigned(gain_target)) > 0 and to_integer(unsigned(squelch_thr)) > 0 then
            need := (real(to_integer(unsigned(gain_target))) * real(2**GAIN_FRAC)
                     / real(GAIN_MAX)) ** 2.0;
            assert real(to_integer(unsigned(squelch_thr))) >= need
                report "channel_normalizer_mux: SQUELCH_THR is below "
                     & "(GAIN_TARGET*2^GAIN_FRAC/GAIN_MAX)^2. The Q6.10 gain "
                     & "CEILING will clamp before the squelch FLOOR does, and "
                     & "SQUELCH_THR is inert."
                severity warning;
        end if;
    end process;
    -- synthesis translate_on

    ---------------------------------------------------------------------------
    -- Stage 1: capture the beat; apply the squelch floor to the power.
    ---------------------------------------------------------------------------
    p_s1 : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pi_i(1) <= (others => '0'); pi_q(1) <= (others => '0');
                pi_c(1) <= (others => '0'); pi_v(1) <= '0'; pi_l(1) <= '0';
                s1_p <= (others => '0');
            else
                pi_i(1) <= in_i;  pi_q(1) <= in_q;
                pi_c(1) <= in_chan; pi_v(1) <= in_valid; pi_l(1) <= in_last;
                -- floor. Also never let p reach zero: leading_one(0) is undefined
                -- and the gain would be meaningless.
                if unsigned(power) < unsigned(squelch_thr) then
                    s1_p <= unsigned(squelch_thr);
                else
                    s1_p <= unsigned(power);
                end if;
                if unsigned(squelch_thr) = 0 and unsigned(power) = 0 then
                    s1_p <= to_unsigned(1, POWER_W);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stage 2: exponent and mantissa. p = m * 2^e, m in [1,2).
    -- idx = {e mod 2, MANT_FRAC bits below the leading one}.
    ---------------------------------------------------------------------------
    p_s2 : process(clk)
        variable e    : integer range 0 to POWER_W-1;
        variable frac : integer range 0 to NFRAC-1;
        variable t    : unsigned(POWER_W + MANT_FRAC - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pi_i(2) <= (others => '0'); pi_q(2) <= (others => '0');
                pi_c(2) <= (others => '0'); pi_v(2) <= '0'; pi_l(2) <= '0';
                s2_e <= 0; s2_idx <= 0;
            else
                pi_i(2) <= pi_i(1); pi_q(2) <= pi_q(1);
                pi_c(2) <= pi_c(1); pi_v(2) <= pi_v(1); pi_l(2) <= pi_l(1);

                e := 0;
                for k in 0 to POWER_W-1 loop
                    if s1_p(k) = '1' then
                        e := k;
                    end if;
                end loop;

                -- MANT_FRAC bits immediately below bit e
                t := shift_left(resize(s1_p, POWER_W + MANT_FRAC), MANT_FRAC);
                t := shift_right(t, e);
                frac := to_integer(t(MANT_FRAC-1 downto 0));

                s2_e   <= e;
                s2_idx <= (e mod 2) * NFRAC + frac;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stage 3: reciprocal-sqrt ROM lookup, and the shift that finishes 2^(-e/2).
    ---------------------------------------------------------------------------
    p_s3 : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pi_i(3) <= (others => '0'); pi_q(3) <= (others => '0');
                pi_c(3) <= (others => '0'); pi_v(3) <= '0'; pi_l(3) <= '0';
                s3_rom <= (others => '0');
                s3_sh  <= ROM_FRAC - GAIN_FRAC;
            else
                pi_i(3) <= pi_i(2); pi_q(3) <= pi_q(2);
                pi_c(3) <= pi_c(2); pi_v(3) <= pi_v(2); pi_l(3) <= pi_l(2);
                s3_rom <= INVSQRT_ROM(s2_idx);
                s3_sh  <= ROM_FRAC + (s2_e / 2) - GAIN_FRAC;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stage 4: gain = (TARGET * rom) >> sh, rounded and clamped.
    --          gain_mode='0' overrides with gain_manual (bypass).
    ---------------------------------------------------------------------------
    p_s4 : process(clk)
        variable prod : unsigned(2*GAIN_W - 1 downto 0);
        variable g    : unsigned(2*GAIN_W - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pi_i(4) <= (others => '0'); pi_q(4) <= (others => '0');
                pi_c(4) <= (others => '0'); pi_v(4) <= '0'; pi_l(4) <= '0';
                s4_gain <= to_unsigned(2**GAIN_FRAC, GAIN_W);
            else
                pi_i(4) <= pi_i(3); pi_q(4) <= pi_q(3);
                pi_c(4) <= pi_c(3); pi_v(4) <= pi_v(3); pi_l(4) <= pi_l(3);

                prod := unsigned(gain_target) * s3_rom;
                g    := shift_right(prod + shift_left(to_unsigned(1, 2*GAIN_W), s3_sh - 1),
                                    s3_sh);
                if g > to_unsigned(GAIN_MAX, 2*GAIN_W) then
                    s4_gain <= to_unsigned(GAIN_MAX, GAIN_W);
                else
                    s4_gain <= resize(g, GAIN_W);
                end if;

                if gain_mode = '0' then
                    s4_gain <= unsigned(gain_manual);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stage 5: the saturating gain multiply.
    ---------------------------------------------------------------------------
    p_s5 : process(clk)
        variable pi, pq : signed(PROD_W - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_i <= (others => '0'); out_q <= (others => '0');
                out_valid <= '0'; out_chan <= (others => '0'); out_last <= '0';
                sat_r <= '0';
            else
                pi := pi_i(4) * signed('0' & std_logic_vector(s4_gain));
                pq := pi_q(4) * signed('0' & std_logic_vector(s4_gain));
                out_i     <= round_sat(pi, GAIN_FRAC);
                out_q     <= round_sat(pq, GAIN_FRAC);
                out_valid <= pi_v(4);
                out_chan  <= pi_c(4);
                out_last  <= pi_l(4);
                -- VHDL-93: no conditional signal assignment inside a process.
                if saturated(pi, GAIN_FRAC) or saturated(pq, GAIN_FRAC) then
                    sat_r <= '1';
                else
                    sat_r <= '0';
                end if;
            end if;
        end if;
    end process;

    gain_sat     <= sat_r;
    gain_current <= std_logic_vector(s4_gain);

end architecture rtl;
