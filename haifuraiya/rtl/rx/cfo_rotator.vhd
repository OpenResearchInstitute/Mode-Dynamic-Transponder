-------------------------------------------------------------------------------
-- cfo_rotator.vhd -- carrier frequency offset correction rotator
-------------------------------------------------------------------------------
-- Project : Mode-Dynamic-Transponder / Haifuraiya      License: CERN-OHL-S v2
--
-- WHAT THIS IS (WP2 build step 1; WP2_CFO_DESIGN.md section 4)
--   Complex derotator at the demodulator input: multiplies each channel
--   sample by e^(-j*2*pi*f*t) to remove a MEASURED carrier frequency
--   offset f before the MLSE chain sees it.  The channelizer removes the
--   KNOWN frequency (bin center); this removes the measured one; the PSP
--   theta tracker absorbs the residual (+/-212 Hz).  Partition per
--   Mehlan/Chen/Meyr 1993 and the C++ reference (set_freq_offset applies
--   the same rotation to input samples, opv_demod.hpp:287,295).
--
-- FREQUENCY WORD
--   freq_hz : signed Hz, positive = remove a POSITIVE offset (the NCO
--   rotates by -f).  Conversion to NCO increment is done here so the
--   register interface stays in engineering units:
--     C_HZ_TO_INC = round(2^32 / 625000) = 6872   (Q0 Hz -> Q32 turns/smp)
--   Error of the rounding: 6872*625000/2^32 = 1.000012 -> 0.0012%,
--   i.e. 0.16 Hz at the +/-13.55 kHz spec edge: absorbed by theta.
--
-- TRIG
--   Same quarter-wave QROM as the engine and MLSE (lut16q_pkg,
--   16385 x [cos|sin] Q15), same fold_phase idiom verbatim -- one source
--   of trig truth in the design.
--
-- PIPELINE (3 stages, one sample in flight per en strobe)
--   S1 en: phase acc += inc; fold; ROM address registered
--   S2   : ROM data registered (synchronous read)
--   S3   : complex multiply, round, saturate; out_valid
--   Samples arrive at ~625 kHz on a 100 MHz clock (160 clocks apart):
--   the 3-cycle latency is invisible to the ring buffer downstream.
--
-- STYLE: VHDL-93; declaration initializers mirror the reset branch.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.lut16q_pkg.all;

entity cfo_rotator is
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;                     -- synchronous, active high

        en       : in  std_logic;                     -- input sample strobe
        i_in     : in  signed(15 downto 0);
        q_in     : in  signed(15 downto 0);

        freq_hz  : in  signed(15 downto 0);           -- offset to REMOVE, Hz

        out_valid: out std_logic;
        i_out    : out signed(15 downto 0);
        q_out    : out signed(15 downto 0)
    );
end entity cfo_rotator;

architecture rtl of cfo_rotator is

    -- Hz -> Q32 phase increment (derivation in header)
    constant C_HZ_TO_INC : signed(13 downto 0) := to_signed(6872, 14);

    signal phase   : unsigned(31 downto 0) := (others => '0');

    -- pipeline registers
    signal v1, v2, v3       : std_logic := '0';
    signal i1, q1, i2, q2   : signed(15 downto 0) := (others => '0');
    signal cneg1, sneg1     : std_logic := '0';
    signal cneg2, sneg2     : std_logic := '0';
    signal addr1            : unsigned(14 downto 0) := (others => '0');
    signal rom2             : std_logic_vector(31 downto 0) := (others => '0');
    signal io_r, qo_r       : signed(15 downto 0) := (others => '0');

    -- fold idiom identical to msk_mlse4.vhd / msk_symbol_engine.vhd
    procedure fold_phase(ph            : in  unsigned(15 downto 0);
                         variable addr : out unsigned(14 downto 0);
                         variable cneg : out std_logic;
                         variable sneg : out std_logic) is
        variable q : unsigned(13 downto 0);
    begin
        q := ph(13 downto 0);
        case to_integer(ph(15 downto 14)) is
            when 0 =>
                addr := resize(q, 15);                 cneg := '0'; sneg := '0';
            when 1 =>
                addr := to_unsigned(16384, 15) - resize(q, 15);
                cneg := '1'; sneg := '0';
            when 2 =>
                addr := resize(q, 15);                 cneg := '1'; sneg := '1';
            when others =>
                addr := to_unsigned(16384, 15) - resize(q, 15);
                cneg := '0'; sneg := '1';
        end case;
    end procedure;

    -- round-to-nearest >>15 with saturation into 16 bits
    function rss15(x : signed(32 downto 0)) return signed is
        variable r : signed(32 downto 0);
    begin
        r := x + to_signed(16384, 33);
        r := shift_right(r, 15);
        if r > 32767 then return to_signed(32767, 16); end if;
        if r < -32768 then return to_signed(-32768, 16); end if;
        return resize(r, 16);
    end function;

begin

    out_valid <= v3;
    i_out     <= io_r;
    q_out     <= qo_r;

    main : process(clk)
        variable inc     : signed(31 downto 0);
        variable ph_next : unsigned(31 downto 0);
        variable vaddr   : unsigned(14 downto 0);
        variable vc, vs  : std_logic;
        variable c, s    : signed(15 downto 0);
        variable pr, pi  : signed(32 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- RESET BRANCH IS TRUTH (mirrors declaration initializers)
                phase <= (others => '0');
                v1 <= '0'; v2 <= '0'; v3 <= '0';
                i1 <= (others => '0'); q1 <= (others => '0');
                i2 <= (others => '0'); q2 <= (others => '0');
                cneg1 <= '0'; sneg1 <= '0'; cneg2 <= '0'; sneg2 <= '0';
                addr1 <= (others => '0');
                rom2  <= (others => '0');
                io_r  <= (others => '0'); qo_r <= (others => '0');
            else
                -- ---- stage 1: NCO advance + fold on each input sample ----
                v1 <= en;
                if en = '1' then
                    inc := resize(freq_hz * C_HZ_TO_INC, 32);
                    -- rotate by MINUS the offset: subtract the increment
                    ph_next := phase - unsigned(inc);
                    phase <= ph_next;
                    fold_phase(ph_next(31 downto 16), vaddr, vc, vs);
                    addr1 <= vaddr; cneg1 <= vc; sneg1 <= vs;
                    i1 <= i_in; q1 <= q_in;
                end if;

                -- ---- stage 2: synchronous ROM read ----
                v2 <= v1;
                if v1 = '1' then
                    rom2  <= LUT16Q_ROM(to_integer(addr1));
                    cneg2 <= cneg1; sneg2 <= sneg1;
                    i2 <= i1; q2 <= q1;
                end if;

                -- ---- stage 3: (I + jQ) * (c + js), round, saturate ----
                v3 <= v2;
                if v2 = '1' then
                    c := signed(rom2(31 downto 16));
                    s := signed(rom2(15 downto 0));
                    if cneg2 = '1' then c := -c; end if;
                    if sneg2 = '1' then s := -s; end if;
                    pr := resize(i2 * c, 33) - resize(q2 * s, 33);
                    pi := resize(i2 * s, 33) + resize(q2 * c, 33);
                    io_r <= rss15(pr);
                    qo_r <= rss15(pi);
                end if;
            end if;
        end if;
    end process main;

end architecture rtl;
