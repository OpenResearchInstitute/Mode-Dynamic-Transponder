-- msk_symbol_engine.vhd
--
-- Correlator + V-bank TED + PI timing loop for the Opulent Voice MSK
-- demodulator (Haifuraiya channel rate: 625 ksps, 54.2 kbaud, sps =
-- 11.5314 fractional). First fabric block of the Phase 0 receiver.
--
-- Architecture proven in the fixed-point model (opv_demod_model.py,
-- track_engine): raw integer sample windows (no interpolator), one NCO
-- shared by both tone arms (tone 2 is the conjugate twiddle), integer
-- amax + (3/8)min magnitudes, shift-only PI gains with acquisition gear,
-- position as integer sample + Q16 fraction. Arm unification downstream
-- is a sign flip (gamma = pi): Q_k = -Y2_k * (-1)^k.
--
-- Interface model: the engine addresses a sample memory (ring buffer in
-- the full design; the testbench serves a file). One correlation MAC
-- runs sequentially: 3 windows x wlen samples per symbol (~36 clocks),
-- ample at any fabric clock vs the 625 kHz sample rate.
--
-- Verification: dump-compare against golden_engine.txt produced by the
-- bit-identical Python model. All arithmetic below mirrors the model
-- integer-for-integer (arithmetic right shifts, floor semantics; the
-- sin/cos table is LOADED FROM THE SAME FILE the model used, so no
-- rounding-convention risk exists between the two worlds).
--
-- ASCII only. 73.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.lut16q_pkg.all;

entity msk_symbol_engine is
  generic (
    G_INC32    : integer := 93114891;    -- NCO increment: 13550/625000 * 2^32
    G_SPS_Q16  : integer := 755720;      -- symbol period in Q16 samples
    G_EL       : integer := 2;           -- early/late offset, whole samples
    G_NSAMP    : integer := 60000        -- stimulus length (bench)
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- stall: freeze the FSM (ring buffer paces the engine against
    -- sample arrival in the streaming system; benches leave it '0')
    hold       : in  std_logic := '0';
    -- sample memory interface (int16 I/Q served by ring buffer / bench)
    mem_addr   : out unsigned(23 downto 0);
    -- TRACKING GATE (2026-08-01): transcribes the reference's
    -- tracking_enabled_ discipline (opv_demod.hpp: "On noise the TED and
    -- AFC chase random correlations, causing drift that hurts acquisition
    -- when a real signal arrives"). The PROPORTIONAL (alpha) path always
    -- runs -- the reference's timing_adj includes alpha*ted regardless.
    -- Only the RATE INTEGRATOR (timing_freq_ / freq_full) is gated: it
    -- holds its value until carrier lock, then integrates.
    trk_enable : in  std_logic := '1';
    mem_i      : in  signed(15 downto 0);
    mem_q      : in  signed(15 downto 0);
    -- per-symbol outputs
    y_valid    : out std_logic;
    y1_re      : out signed(23 downto 0);
    y1_im      : out signed(23 downto 0);
    y2_re      : out signed(23 downto 0);
    y2_im      : out signed(23 downto 0);
    sym_index  : out unsigned(23 downto 0);
    pos_q16    : out unsigned(47 downto 0);   -- debug tap: position word
    dbg_mac    : out std_logic;                -- high during S_MAC
    dbg_a1r    : out signed(39 downto 0);      -- live accumulator
    -- burst-birth camera taps (2026-08-02, additive only):
    dbg_ted    : out signed(16 downto 0);      -- per-symbol timing error
    dbg_freq   : out signed(31 downto 0);      -- integrator Q24 view (=0x0CC)
    dbg_trk    : out std_logic;                -- tracking gate as applied
    dbg_eerr   : out std_logic;                -- e_err_v (walkthrough 8.2)
    -- per-symbol EARLY/LATE magnitude export for the symbol lock
    -- detector (normalized early-late gate; Mengali & D'Andrea 1997,
    -- and bit-for-concept identical to the C++ reference TED
    -- (el-ee)/(el+ee), opv_demod.hpp line ~365).  Both values carry the
    -- SAME >> C_ERR_EXPORT_SHR scaling, which CANCELS in the detector's
    -- ratio -- the lock decision is amplitude- and scaling-invariant.
    e_early    : out unsigned(15 downto 0);
    e_late     : out unsigned(15 downto 0);
    e_err_valid: out std_logic;
    -- timing-loop coefficients (register-backed, map v6 0x0C4/0x0C8) and
    -- integrator status (0x0CC).  Loop law = C++ reference verbatim
    -- (opv_demod.hpp:197-199,377-380):
    --   ted            = (L-E)/(L+E)          normalized, Q15 here
    --   adj [Q16 smp]  = ted*ALPHA + clk_off  ALPHA default 0.005 -> Q16 328
    --   clk_off [Q24]  += ted*BETA            BETA  default 1e-5  -> Q24 168
    --   clk_off clamp  = +/-0.1 sample        -> +/-1677722 Q24
    -- SYM_CLK_OFFSET is the integrator: the estimated symbol-clock rate
    -- error between transmitter baud and this receiver's sample clock,
    -- Q24 fractional samples per symbol (ppm = val * 2^-24 / SPS * 1e6).
    cfg_tim_alpha : in  unsigned(15 downto 0);
    cfg_tim_beta  : in  unsigned(15 downto 0);
    sym_clk_offset: out signed(31 downto 0);
    done       : out std_logic
  );
end entity;

architecture rtl of msk_symbol_engine is

  -- export scaling for e_err (see port comment); mirrors the adj arm
  constant C_ERR_EXPORT_SHR : natural := 4;


  -- quarter-wave sin/cos ROM from lut16q_pkg (constants; see pkg header)
  signal QROM : qlut_t := LUT16Q_ROM;
  attribute rom_style : string;
  attribute rom_style of QROM : signal is "block";

  -- synchronous ROM access: fold the 16-bit phase into quarter-table
  -- address + output signs (slices only -- no divide, no mod)
  signal rom_q    : std_logic_vector(31 downto 0) := (others => '0');
  signal cneg_d, sneg_d : std_logic := '0';   -- sign flags, ROM-aligned
  signal xr_d, xi_d     : signed(15 downto 0) := (others => '0');

  procedure fold_phase(ph            : in  unsigned(15 downto 0);
                       variable addr : out unsigned(14 downto 0);
                       variable cneg : out std_logic;
                       variable sneg : out std_logic) is
    variable q : unsigned(13 downto 0);
  begin
    q := ph(13 downto 0);
    case to_integer(ph(15 downto 14)) is
      when 0 =>
        addr := resize(q, 15);                     cneg := '0'; sneg := '0';
      when 1 =>
        addr := to_unsigned(16384, 15) - resize(q, 15);
        cneg := '1'; sneg := '0';
      when 2 =>
        addr := resize(q, 15);                     cneg := '1'; sneg := '1';
      when others =>
        addr := to_unsigned(16384, 15) - resize(q, 15);
        cneg := '0'; sneg := '1';
    end case;
  end procedure;

  type state_t is (S_WIN_SETUP, S_MAC_A, S_MAC_B, S_WIN_DONE,
                   S_TED_A, S_TED_B, S_TED_DIV, S_TED_C, S_ADVANCE, S_ADVANCE2,
                   S_DONE);
  signal state : state_t := S_WIN_SETUP;

  -- position and loop state
  signal pos    : unsigned(47 downto 0) := to_unsigned(2, 32) & x"0000";
  signal freq   : signed(31 downto 0) := (others => '0');  -- Q24 clk offset (readback view)
  -- PLESIOCHRONOUS PRECISION (restored 2026-07-29 after a git-stash ate
  -- the 2026-07-27 patch from the working copy -- see WP_SYMBOL_CLOCK_SLIP
  -- and the plan-of-attack case file): the C++ reference integrates
  -- timing_freq_ in DOUBLE precision; truncating (ted*beta)>>15 per
  -- symbol creates a deadzone (|ted|<195 contributes zero at beta=168)
  -- with arithmetic-shift -inf bias. freq_full keeps the 15 discarded
  -- bits; truncation applies only to the Q24 readback, never the state.
  -- Reference behavior at full precision (opv-resample, 2026-07-27):
  -- 11.5 ppm: 149/149; 25 ppm: 149/149; 50 ppm: 147/149.
  signal freq_full : signed(39 downto 0) := (others => '0'); -- Q39 integrator state
  constant C_FREQ_CLAMP_FULL : signed(39 downto 0) :=
      shift_left(to_signed(1677722, 40), 15);   -- +/-0.1 sample, Q39
  constant C_RND15 : signed(39 downto 0) := to_signed(16384, 40);   -- 2^14
  constant C_RND23 : signed(39 downto 0) := to_signed(4194304, 40); -- 2^22
  -- serial divider for ted = (|L-E|<<15)/(L+E), exact Q15 (|num|<den always)
  signal div_acc  : unsigned(46 downto 0) := (others => '0');
  -- FRACTIONAL-BOUNDARY INTEGRATE-AND-DUMP + EXACT QUARTER-SYMBOL GATES
  -- (2026-08-01, rebuilt after a git-checkout clobbered the first pass).
  -- Windows integrate the TRUE span [a, a+SPS_Q16), a = pos + {-EL,0,+EL}
  -- with EL = SPS/4 EXACT in Q16 (reference: EL_OFFSET = SPS/4). Taps:
  -- n from floor(a) to floor(a+SPS) INCLUSIVE; first weighted (1-frac_a),
  -- last weighted frac_b, unity interior; total == SPS exactly, every
  -- symbol, every window. Energy flat to 0.02 dB across the frac sweep
  -- (python model) vs 0.72 dB unit-weight -- the measured comb mechanism.
  constant C_EL_Q16 : natural := (G_SPS_Q16 + 2) / 4;  -- SPS/4 exact-est Q16
  signal wfrac_a  : unsigned(15 downto 0) := (others => '0');
  signal wfrac_b  : unsigned(15 downto 0) := (others => '0');
  signal n_start  : unsigned(23 downto 0) := (others => '0');
  signal wgt_d    : unsigned(16 downto 0) := (others => '0');
  signal div_den  : unsigned(31 downto 0) := (others => '0');
  signal div_q    : unsigned(15 downto 0) := (others => '0');
  signal div_cnt  : unsigned(3 downto 0)  := (others => '0');
  signal ted_neg  : std_logic := '0';
  signal e_early_r : unsigned(15 downto 0) := (others => '0');
  signal e_late_r  : unsigned(15 downto 0) := (others => '0');
  signal e_err_v   : std_logic := '0';
  signal dbg_ted_r : signed(16 downto 0) := (others=>'0');
  signal k      : unsigned(23 downto 0) := (others => '0');

  -- window sequencing: 0 = early, 1 = on-time, 2 = late
  signal widx   : integer range 0 to 2 := 0;
  signal n_cur  : unsigned(23 downto 0);
  signal n_end  : unsigned(23 downto 0);
  signal wlen   : integer range 0 to 15;

  -- MAC accumulators (16x16 products over <=12 samples: 36 bits is ample)
  signal a1r, a1i, a2r, a2i : signed(39 downto 0);

  -- per-window results: (y1r,y1i,y2r,y2i) x {early,center,late}
  type yset_t is array (0 to 3) of signed(23 downto 0);
  type wset_t is array (0 to 2) of yset_t;
  signal ycur : wset_t;

  -- TIMING ERROR DETECTOR: the C++ reference's (opv_demod.hpp,
  -- track_correlations), transcribed 2026-10-21:
  --     ya  = (|Y1|^2 > |Y2|^2) ? Y1 : Y2            on-time, dominant tone
  --     dy  = Y_late - Y_early                       same tone
  --     err = Re(ya * conj(dy)) / |ya|^2
  -- It replaces the 2T "V-bank" detector (four combinations of
  -- consecutive-symbol correlations, amax+3/8min magnitudes,
  -- (L-E)/(L+E)).  Measured (ted_model.py, 2026-10-21): the V-bank's
  -- S-curve on random payload has half the reference's gain in one
  -- symbol-counter parity, is sign-REVERSED in the other (parity vs the
  -- transmitter is a coin flip at acquisition), and reverses again beyond
  -- |tau| ~ 0.3 symbol; on an 11.5 ppm clock the integrator reached only
  -- -1476 of the -2225 (Q24) needed, then turned around (xsim readback,
  -- 25-frame run: BER 0.2% -> 3.2% across one second).  The reference's
  -- detector is odd-symmetric, identical on preamble and payload, has no
  -- parity and no bank; the same loop law, registers and windows hold an
  -- 11.5 ppm clock to <0.04 symbol at 10 dB in the model.
  -- Pipeline: S_TED_A picks the dominant tone (energies), registers
  -- ya, dy and den = |ya|^2; S_TED_B forms num = Re(ya conj(dy)), the
  -- early/late amplitude exports, and launches the existing divider on
  -- (|num| << 15) / den with saturation when |num| >= den.
  signal ya_r, ya_i   : signed(23 downto 0) := (others => '0');
  signal dy_r, dy_i   : signed(24 downto 0) := (others => '0');
  signal den_r        : unsigned(47 downto 0) := (others => '0');
  signal ae_amp, al_amp : signed(27 downto 0) := (others => '0');
  signal have_bank    : std_logic := '0';   -- '1' once the first triple is in
  -- common right-shift applied to num and den before the 47-bit divider
  -- (the ratio is scale-invariant); |y| ~ 2^20 typical -> den ~ 2^40.
  constant C_TED_NORM_SHR : natural := 16;

  -- TONE-ARM RELATIVE PHASE RE-REFERENCE (2026-10-22).  The two tone
  -- correlations are taken against ABSOLUTE-time LOs: y1 carries
  -- exp(-j 2pi fd t_k), y2 carries exp(+j 2pi fd t_k) at the window start
  -- t_k.  The MLSE's V-bank (Q_k = y2 * (-1)^k) assumes their relative
  -- phase advances by exactly pi per symbol, which is true only when the
  -- windows sit on the nominal grid t_k = k*SPS (2 fd SPS / fs = 1/2
  -- exactly).  Any displacement d = pos - k*SPS adds 2pi(2fd/fs)d of
  -- relative phase the survivors cannot absorb (they track COMMON phase):
  -- a TX clock offset makes d grow (11.5 ppm: 113 deg over one second,
  -- measured BER 0.2% -> 3.4% across a 25-frame run), and an arbitrary TX
  -- boundary phase makes it a constant (half a symbol = 90 deg: 3.7% BER
  -- in the model at Eb/N0 10 dB vs 0.45%).  Re-referencing the exported
  -- arms to the window start restores the V-bank's assumption at every
  -- position: model BER flat 0.15-0.63% over the second (vbank_drift.py)
  -- and 0.45% at every constant d (vbank_const.py).
  -- The re-reference is split EQUALLY between the arms, as the C++
  -- reference's symbol-indexed LOs (demodulate(): phase_f += SPS*inc,
  -- independent of pos) do by construction:
  --     y1 * exp(+j 2pi(fd/fs) d),   y2 * exp(-j 2pi(fd/fs) d)
  -- The relative phase (all the MLSE needs) is the same as rotating y2
  -- alone by the full angle; the common part is slow and the survivors'
  -- phase words track it.  The split matters while the TIMING LOOP IS
  -- SLEWING (capture after idle, when pos has wandered on noise): a
  -- rotation of one arm alone by the full angle made that arm appear to
  -- spin at 2fd*adj/SPS -- tens of Hz during capture -- and the preamble
  -- carrier estimator (two-arm lag-4 sum) picked up half of it as carrier
  -- (first xsim: est 572 for a +500 burst, -264 for a -300 burst, both
  -- preambles arriving after 100 ms of idle).  With the equal split the
  -- two arms see equal and opposite apparent rates and the two-arm sum
  -- cancels to first order, exactly as in the reference.
  -- arm_ph holds the HALF angle 2pi(fd/fs)d as a 32-bit turn fraction,
  -- kept incrementally: += adj * G_INC32 / 2^16 per symbol (adj in Q16
  -- samples), seeded from the reset position; one ROM read serves both
  -- arms (conjugate for y2).  The TED and the lock detector keep the raw
  -- arms (their statistics are rotation-invariant within an arm).
  signal arm_ph    : unsigned(31 downto 0) := (others => '0');
  constant C_ARM_PH0 : unsigned(31 downto 0) :=
      to_unsigned(2 * G_INC32, 32);   -- reset pos = 2.0 smp: 2*G_INC32
  -- TIMING (VCK190 impl 2026-10-23, WNS -2.5 ns): the accumulate used to
  -- sit in S_TED_C behind the divider quotient -> ted -> alpha product ->
  -- integrator -> clamp -> 32x32 multiply -> add: 60 logic levels, two
  -- cascaded DSP58s, in one 10 ns clock.  It is now a three-stage
  -- pipeline on the states the engine already walks:
  --   S_TED_C              adj_r  <= adj                     (registered)
  --   S_WIN_SETUP, widx 0  dph_r  <= adj_r * G_INC32         (DSPs alone)
  --   S_WIN_SETUP, widx 1  arm_ph <= arm_ph + dph_r >> 16    (adder alone)
  -- arm_ph is not read until S_WIN_DONE of window 2, ~50 clocks later,
  -- so the exported arms are bit-identical to the single-cycle form.
  -- adj is clamped to +/-131072 (18 bits + sign).
  signal adj_r     : signed(18 downto 0) := (others => '0');
  signal dph_r     : signed(50 downto 0) := (others => '0');   -- 19 x 32 bits

  signal y_valid_i : std_logic := '0';
  signal done_i    : std_logic := '0';
  -- CONTINUOUS MODE (2026-07-28): position wraps mod 2^24; tone phase
  -- stays continuous by accumulating the wrap residue of G_INC32*2^24
  -- (= (G_INC32 mod 256) << 24 in 32-bit phase) into ph_base.
  signal ph_base   : unsigned(31 downto 0) := (others => '0');
  constant C_WRAP_RES : unsigned(31 downto 0)
      := to_unsigned(G_INC32 mod 256, 8) & to_unsigned(0, 24);
  signal sym_out   : unsigned(23 downto 0) := (others => '0');

  -- amax + (3/8)min on 25-bit sums
  function abmag(r, i : signed(24 downto 0)) return signed is
    variable ar, ai, hi, lo : signed(24 downto 0);
    variable res            : signed(27 downto 0);
  begin
    ar := abs(r); ai := abs(i);
    if ar >= ai then hi := ar; lo := ai; else hi := ai; lo := ar; end if;
    res := resize(hi, 28) + shift_right(resize(lo,28) + resize(lo,28)
                                        + resize(lo,28), 3);
    return res;
  end function;

begin

  sym_clk_offset <= freq;
  e_early     <= e_early_r;
  e_late      <= e_late_r;
  e_err_valid <= e_err_v;


  mem_addr  <= n_cur;
  dbg_mac   <= '1' when state = S_MAC_B else '0';
  dbg_a1r   <= a1r;
  y_valid   <= y_valid_i;
  done      <= done_i;
  sym_index <= sym_out;
  -- LIVE position, not a snapshot: the wrapper's ring-buffer stall
  -- logic gates on this, and a stale value releases the engine into
  -- unwritten memory (the symbol-1 zeros bug, session 8). At the
  -- y_valid sampling instant, live pos equals the old snapshot exactly
  -- (pos updates at the end of the TED sequence, S_ADVANCE2).
  pos_q16   <= pos;

  process(clk)
    -- combinational helpers used sequentially inside the process
    variable p_int   : unsigned(23 downto 0);
    variable vspan   : unsigned(47 downto 0);
    variable ph32    : unsigned(63 downto 0);
    variable vaddr   : unsigned(14 downto 0);
    variable vcneg, vsneg : std_logic;
    variable c, s    : signed(15 downto 0);
    variable xr, xi  : signed(15 downto 0);
    variable m1, m2, m3, m4 : signed(31 downto 0);
    -- TED variables
    variable e1, e2     : unsigned(47 downto 0);   -- tone energies |Y1|^2, |Y2|^2
    variable num        : signed(49 downto 0);     -- Re(ya conj(dy))
    variable numa       : unsigned(49 downto 0);   -- |num| >> C_TED_NORM_SHR
    variable dena       : unsigned(47 downto 0);   -- den  >> C_TED_NORM_SHR
    variable ted        : signed(16 downto 0);
    variable adj        : signed(31 downto 0);
    variable fnew       : signed(33 downto 0);   -- retired by Q39 path
    variable fnew_full  : signed(39 downto 0);
    variable rr, ri     : signed(40 downto 0);   -- rotated y2 (24x16 + 24x16)

  begin
    if rising_edge(clk) then
      y_valid_i <= '0';
      if rst = '1' then
        state <= S_WIN_SETUP;
        pos   <= to_unsigned(2, 32) & x"0000";
        -- (reset body continues below)
        freq  <= (others => '0');
        freq_full <= (others => '0');
        div_acc <= (others => '0'); div_den <= (others => '0');
        div_q <= (others => '0'); div_cnt <= (others => '0');
        ted_neg <= '0';
        e_early_r <= (others => '0');
        e_late_r  <= (others => '0');
        e_err_v   <= '0';
        k     <= (others => '0');
        widx  <= 0;
        have_bank  <= '0';
        done_i     <= '0';
        ph_base    <= (others => '0');
        arm_ph     <= C_ARM_PH0;
        adj_r      <= (others => '0');
        dph_r      <= (others => '0');
      elsif hold = '0' then
        e_err_v <= '0';                      -- one-cycle strobe default
        case state is

          when S_WIN_SETUP =>
            -- arm_ph pipeline, stages 2 and 3 (see the arm_ph note)
            if widx = 0 then
              dph_r <= adj_r * to_signed(G_INC32, 32);
            elsif widx = 1 then
              arm_ph <= arm_ph + unsigned(dph_r(47 downto 16));
            end if;
            p_int := resize(pos(47 downto 16), 24);
            wlen  <= to_integer(resize(
                       resize(pos + to_unsigned(G_SPS_Q16, 48), 48)
                         (47 downto 16), 24) - p_int);
            -- TRUE fractional span per window (early/on/late), EL exact
            case widx is
              when 0 =>
                if resize(pos,48) > to_unsigned(C_EL_Q16,48) then
                  vspan := resize(pos,48) - to_unsigned(C_EL_Q16,48);
                else
                  vspan := (others => '0');   -- C++ p_early<0 clamp
                end if;
              when 1 => vspan := resize(pos,48);
              when 2 => vspan := resize(pos,48) + to_unsigned(C_EL_Q16,48);
            end case;
            n_cur   <= resize(vspan(47 downto 16), 24);
            n_start <= resize(vspan(47 downto 16), 24);
            wfrac_a <= vspan(15 downto 0);
            vspan   := vspan + to_unsigned(G_SPS_Q16, 48);
            n_end   <= resize(vspan(47 downto 16), 24);
            wfrac_b <= vspan(15 downto 0);
            a1r <= (others=>'0'); a1i <= (others=>'0');
            a2r <= (others=>'0'); a2i <= (others=>'0');
            -- stop condition mirrors the model loop guard -- BENCH ONLY.
            -- CONTINUOUS MODE (G_NSAMP = 0): a radio has no end of
            -- stimulus. An unconditional compare here with G_NSAMP=0 is
            -- always true -> S_DONE on the FIRST window -> engine dead
            -- at birth (the 0x00060100/0x00060200 flatline, QUAL==0).
            if G_NSAMP /= 0 and
               to_integer(resize(pos(47 downto 16),32)) + G_EL + 14
               >= G_NSAMP then
              state  <= S_DONE;
            else
              state <= S_MAC_A;
            end if;

          when S_MAC_A =>
            -- address phase: fold NCO phase, register ROM output next
            -- edge; capture the sample pair aligned with the ROM data
            ph32 := resize(to_unsigned(G_INC32, 32) * resize(n_cur, 32), 64)
                    + resize(ph_base, 64);
            fold_phase(unsigned(ph32(31 downto 16)), vaddr, vcneg, vsneg);
            -- synchronous ROM read in the address phase: data registered
            -- on THIS edge, valid when S_MAC_B executes next edge
            rom_q  <= QROM(to_integer(vaddr));
            cneg_d <= vcneg;
            sneg_d   <= vsneg;
            xr_d     <= mem_i;
            xi_d     <= mem_q;
            if n_cur = n_start then
              wgt_d <= resize(to_unsigned(65536,17) - resize(wfrac_a,17), 17);
            elsif n_cur = n_end then
              wgt_d <= resize(wfrac_b, 17);
            else
              wgt_d <= to_unsigned(65536, 17);
            end if;
            state    <= S_MAC_B;

          when S_MAC_B =>
            -- accumulate phase: ROM data (registered) + aligned sample
            if cneg_d = '0' then c :=  signed(rom_q(31 downto 16));
            else                 c := -signed(rom_q(31 downto 16));
            end if;
            if sneg_d = '0' then s :=  signed(rom_q(15 downto 0));
            else                 s := -signed(rom_q(15 downto 0));
            end if;
            xr := resize(shift_right(xr_d * signed('0' & wgt_d), 16), 16);
            xi := resize(shift_right(xi_d * signed('0' & wgt_d), 16), 16);
            m1 := xr * c;  m2 := xi * s;
            m3 := xi * c;  m4 := xr * s;
            a1r <= a1r + resize(m1,40) + resize(m2,40);
            a1i <= a1i + resize(m3,40) - resize(m4,40);
            a2r <= a2r + resize(m1,40) - resize(m2,40);
            a2i <= a2i + resize(m3,40) + resize(m4,40);
            if n_cur = n_end then   -- INCLUSIVE: partial end tap carries wfrac_b
              state <= S_WIN_DONE;
            else
              n_cur <= n_cur + 1;
              state <= S_MAC_A;
            end if;

          when S_WIN_DONE =>
            ycur(widx)(0) <= resize(shift_right(a1r, 15), 24);
            ycur(widx)(1) <= resize(shift_right(a1i, 15), 24);
            ycur(widx)(2) <= resize(shift_right(a2r, 15), 24);
            ycur(widx)(3) <= resize(shift_right(a2i, 15), 24);
            if widx = 2 then
              widx  <= 0;
              -- ROM is idle here: look up cos/sin(arm_ph) so the rotated
              -- y2 can be exported next edge (same address/data cadence
              -- as S_MAC_A -> S_MAC_B)
              fold_phase(arm_ph(31 downto 16), vaddr, vcneg, vsneg);
              rom_q  <= QROM(to_integer(vaddr));
              cneg_d <= vcneg;
              sneg_d <= vsneg;
              state <= S_TED_A;
            else
              widx  <= widx + 1;
              state <= S_WIN_SETUP;
            end if;

          when S_TED_A =>
            -- COMPUTE phase: emit Y; pick the dominant on-time tone by
            -- energy (reference: e1 > e2); register ya, dy = late - early
            -- of that tone, den = |ya|^2, and the early/late amplitudes
            -- for the symbol lock detector.
            -- arms re-referenced to the window start (see arm_ph note):
            --   y1 * exp(+j arm_ph) = (y1r c - y1i s) + j (y1i c + y1r s)
            --   y2 * exp(-j arm_ph) = (y2r c + y2i s) + j (y2i c - y2r s)
            -- c/s Q15 from the single ROM read issued in S_WIN_DONE
            if cneg_d = '0' then c :=  signed(rom_q(31 downto 16));
            else                 c := -signed(rom_q(31 downto 16));
            end if;
            if sneg_d = '0' then s :=  signed(rom_q(15 downto 0));
            else                 s := -signed(rom_q(15 downto 0));
            end if;
            rr := resize(ycur(1)(0) * c, 41) - resize(ycur(1)(1) * s, 41);
            ri := resize(ycur(1)(1) * c, 41) + resize(ycur(1)(0) * s, 41);
            y1_re <= resize(shift_right(rr, 15), 24);
            y1_im <= resize(shift_right(ri, 15), 24);
            rr := resize(ycur(1)(2) * c, 41) + resize(ycur(1)(3) * s, 41);
            ri := resize(ycur(1)(3) * c, 41) - resize(ycur(1)(2) * s, 41);
            y2_re <= resize(shift_right(rr, 15), 24);
            y2_im <= resize(shift_right(ri, 15), 24);
            sym_out <= k;          -- snapshot BEFORE increment
            y_valid_i <= '1';
            e1 := unsigned(resize(ycur(1)(0) * ycur(1)(0), 48))
                + unsigned(resize(ycur(1)(1) * ycur(1)(1), 48));
            e2 := unsigned(resize(ycur(1)(2) * ycur(1)(2), 48))
                + unsigned(resize(ycur(1)(3) * ycur(1)(3), 48));
            if e1 > e2 then
              ya_r <= ycur(1)(0);  ya_i <= ycur(1)(1);
              dy_r <= resize(ycur(2)(0), 25) - resize(ycur(0)(0), 25);
              dy_i <= resize(ycur(2)(1), 25) - resize(ycur(0)(1), 25);
              den_r <= e1;
              ae_amp <= abmag(resize(ycur(0)(0), 25), resize(ycur(0)(1), 25));
              al_amp <= abmag(resize(ycur(2)(0), 25), resize(ycur(2)(1), 25));
            else
              ya_r <= ycur(1)(2);  ya_i <= ycur(1)(3);
              dy_r <= resize(ycur(2)(2), 25) - resize(ycur(0)(2), 25);
              dy_i <= resize(ycur(2)(3), 25) - resize(ycur(0)(3), 25);
              den_r <= e2;
              ae_amp <= abmag(resize(ycur(0)(2), 25), resize(ycur(0)(3), 25));
              al_amp <= abmag(resize(ycur(2)(2), 25), resize(ycur(2)(3), 25));
            end if;
            have_bank <= '1';
            state <= S_TED_B;

          when S_TED_B =>
            -- DECIDE phase part 1: winner + E/L export + divider launch.
            -- Old raw-error PI (gains ~67x/~1000x the C++ reference in
            -- normalized terms; measured 2026-07-20) and the x4
            -- acquisition gear are REMOVED: reference has neither.
            if have_bank = '1' then
              -- reference numerator: Re(ya * conj(dy)) = ya_r*dy_r + ya_i*dy_i
              num := resize(ya_r * dy_r, 50) + resize(ya_i * dy_i, 50);
              -- registered early/late export (same shift both: cancels in ratio)
              if shift_right(ae_amp, C_ERR_EXPORT_SHR) > 65535 then
                e_early_r <= (others => '1');
              else
                e_early_r <= resize(unsigned(
                    shift_right(ae_amp, C_ERR_EXPORT_SHR)), 16);
              end if;
              if shift_right(al_amp, C_ERR_EXPORT_SHR) > 65535 then
                e_late_r <= (others => '1');
              else
                e_late_r <= resize(unsigned(
                    shift_right(al_amp, C_ERR_EXPORT_SHR)), 16);
              end if;
              e_err_v <= '1';
              -- divider setup: ted_q15 = (|num| << 15) / den, sign separate.
              -- Both scaled down together (ratio invariant) so the 47-bit
              -- restoring divider fits; |num| >= den saturates to +/-1.0.
              if num < 0 then
                ted_neg <= '1';
                numa := shift_right(unsigned(-num), C_TED_NORM_SHR);
              else
                ted_neg <= '0';
                numa := shift_right(unsigned(num), C_TED_NORM_SHR);
              end if;
              dena := shift_right(den_r, C_TED_NORM_SHR);
              if dena = 0 then
                dena := to_unsigned(1, 48);
              end if;
              if numa >= resize(dena, 50) or dena(47 downto 32) /= 0 then
                -- saturate: quotient 32768 maps to +/-32767 in S_TED_C
                -- (dena >= 2^32 cannot happen for 24-bit y; guard anyway)
                div_acc <= (others => '0');
                div_den <= (others => '1');
                div_q   <= to_unsigned(32768, 16);
                div_cnt <= (others => '0');
              else
                div_acc <= resize(shift_left(resize(numa, 47), 15), 47);
                div_den <= resize(dena, 32);
                div_q   <= (others => '0');
                div_cnt <= to_unsigned(15, 4);
              end if;
              state   <= S_TED_DIV;
            else
              -- no bank yet: advance position at nominal rate, no update
              pos <= pos + to_unsigned(G_SPS_Q16, 48);
              adj_r <= (others => '0');
              k   <= k + 1;
              state <= S_WIN_SETUP;
            end if;

          when S_TED_DIV =>
            -- restoring divide, one quotient bit per clock, 16 clocks.
            -- Exact: |L-E| <= (L+E) guarantees the Q15 quotient fits.
            if shift_right(div_acc, to_integer(div_cnt))
               >= resize(div_den, 47) then
              div_acc <= div_acc - shift_left(resize(div_den, 47),
                                              to_integer(div_cnt));
              div_q(to_integer(div_cnt)) <= '1';
            end if;
            if div_cnt = 0 then
              state <= S_TED_C;
            else
              div_cnt <= div_cnt - 1;
            end if;

          when S_TED_C =>
            -- DECIDE phase part 2: apply the C++ loop law and advance.
            -- saturate the E=0 corner (quotient 32768) into Q15
            if div_q > 32767 then div_q <= to_unsigned(32767, 16); end if;
            if ted_neg = '1' then
              ted := -signed(resize(div_q, 17));
              if div_q > 32767 then ted := to_signed(-32767, 17); end if;
            else
              ted :=  signed(resize(div_q, 17));
              if div_q > 32767 then ted := to_signed( 32767, 17); end if;
            end if;
            -- integrator, FULL precision: freq_full(Q39) += ted*beta,
            -- clamp +/-0.1 smp in the widened domain (see header note).
            if trk_enable = '1' then
              fnew_full := freq_full
                         + resize(ted * signed(resize(cfg_tim_beta, 17)), 40);
            else
              fnew_full := freq_full;   -- HELD, not reset (reference behavior)
            end if;
            if fnew_full >  C_FREQ_CLAMP_FULL then fnew_full :=  C_FREQ_CLAMP_FULL; end if;
            if fnew_full < -C_FREQ_CLAMP_FULL then fnew_full := -C_FREQ_CLAMP_FULL; end if;
            freq_full <= fnew_full;
            -- Q24 readback view (0x0CC semantics unchanged), round-to-nearest
            freq <= resize(shift_right(fnew_full + C_RND15, 15), 32);
            dbg_ted_r <= ted;                  -- camera: TED as used this symbol
            -- TIMING (VCK190 impl 2026-10-23: quotient -> ted -> alpha
            -- product -> integrator -> clamp -> 48-bit position add failed
            -- 10 ns on 71 endpoints): the loop law continues over the next
            -- two states.  This state owns the integrator; S_ADVANCE forms
            -- adj from the REGISTERED ted (dbg_ted_r) and the UPDATED
            -- integrator (freq_full, written on this edge -- the same value
            -- fnew_full the single-cycle form used); S_ADVANCE2 adds it
            -- into pos.  Same arithmetic in the same order, two clocks
            -- later per symbol; nothing samples pos or adj in between.
            state <= S_ADVANCE;

          when S_ADVANCE =>
            -- proportional + integrator, Q16 samples; round-to-nearest on
            -- both slices (kills the arithmetic-shift -inf bias)
            ted := dbg_ted_r;
            adj := resize(shift_right(ted * signed(resize(cfg_tim_alpha, 17))
                                      + to_signed(16384, 34), 15), 32)
                 + resize(shift_right(freq_full + C_RND23, 23), 32);
            if adj >  131072 then adj := to_signed( 131072, 32); end if;
            if adj < -131072 then adj := to_signed(-131072, 32); end if;
            -- adj_r feeds the position add (next state) and the tone-arm
            -- half-angle pipeline in S_WIN_SETUP: the nominal step (SPS)
            -- contributes exactly half a turn of RELATIVE phase, which the
            -- MLSE's (-1)^k already carries, so only adj accumulates there
            adj_r <= resize(adj, 19);
            state <= S_ADVANCE2;

          when S_ADVANCE2 =>
            pos <= unsigned(signed(pos)
                   + to_signed(G_SPS_Q16, 48) + resize(adj_r, 48));
            k   <= k + 1;
            state <= S_WIN_SETUP;

          when S_DONE =>
            done_i <= '1';

        end case;

        -- position wrap normalization (continuous mode): int part >= 2^24
        -- -> subtract 2^24 (Q16) and bump the phase base by the residue.
        -- May land one cycle after an FSM pos update; n_cur views are
        -- mod-2^24 by construction so the interim value is harmless.
        if pos(47 downto 40) /= x"00" then
          pos     <= pos - shift_left(to_unsigned(1, 48), 40);
          ph_base <= ph_base + C_WRAP_RES;
        end if;
      end if;
    end if;
  end process;

  -- burst-birth camera (additive, no logic touched)
  dbg_ted  <= dbg_ted_r;
  dbg_freq <= freq;
  dbg_trk  <= trk_enable;
  dbg_eerr <= e_err_v;

end architecture;
