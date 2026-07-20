-------------------------------------------------------------------------------
-- sym_lock_detector.vhd -- Symbol-timing lock detector (normalized early-late)
-------------------------------------------------------------------------------
-- Project : Mode-Dynamic-Transponder / Haifuraiya
-- License : CERN-OHL-S v2
--
-- WHAT THIS IS
--   A measurement of symbol-timing lock quality from the actual signal:
--   the NORMALIZED early-late statistic, windowed, with hysteresis.
--   Per symbol the engine exports the winning survivor's early and late
--   window magnitudes (E, L).  This block maintains sliding sums over
--   2**window_log2 symbols and declares:
--
--        LOCKED    when  100 * SUM|L-E|  <=  PCT_LOCK   * SUM(L+E)
--        UNLOCKED  when  100 * SUM|L-E|  >=  PCT_UNLOCK * SUM(L+E)
--
--   i.e. the windowed mean of |L-E|/(L+E) against percent thresholds --
--   multiply-and-compare, no divider, the same normalized-CFAR pattern
--   as frame_sync_detector_soft's 100*corr >= PCT*energy.
--
-- WHY THIS FORM (references)
--   * The normalized early-late gate is the standard NDA timing metric:
--     U. Mengali, A. N. D'Andrea, "Synchronization Techniques for
--     Digital Receivers", Plenum 1997.
--   * It is EXACTLY the reference implementation's statistic:
--     opv-cxx-demod opv_demod.hpp, ted = (el-ee)/(el+ee); its
--     SymbolLockDetector locks below 0.25 and unlocks above 0.50 of
--     this dimensionless quantity -- which map verbatim to the percent
--     defaults 25 / 50 here.  No scale calibration exists or is needed:
--     the ratio is amplitude-invariant and the engine's export shift
--     cancels.
--   * Frame-sync gating on this detector follows the same reference
--     ("gates frame sync search on TED convergence").
--
-- ARCHITECTURAL INVARIANT (not configurable)
--   locked (via demod_lock) GATES frame-sync hunt.  No bypass register
--   exists and none may be added.
--
-- REGISTERS (map v6)
--   SYM_LOCK_STATUS   0x0A0 ro  locked, window_full, ratio_pct (live)
--   SYM_LOCK_THRESH   0x0A4 rw  PCT_LOCK,   percent, default 25 (C++)
--   SYM_UNLOCK_THRESH 0x0A8 rw  PCT_UNLOCK, percent, default 50 (C++)
--   SYM_LOCK_WINDOW   0x0AC rw  window_log2; write flushes (deterministic)
--
-- ratio_pct readback: serial restoring divider, one bit per clock,
-- 24 clocks per update, retriggered each symbol -- symbols are ~1845
-- clocks apart at 54.2 kbaud on 100 MHz, so the readback is always
-- fresh and costs no DSP.
--
-- STYLE: VHDL-93; declaration initializers mirror the reset branch.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sym_lock_detector is
    generic (
        G_MAG_W          : natural := 16;
        G_MAX_WINDOW_LOG2: natural := 12
    );
    port (
        clk          : in  std_logic;
        init         : in  std_logic;

        e_valid      : in  std_logic;
        e_early      : in  unsigned(G_MAG_W-1 downto 0);
        e_late       : in  unsigned(G_MAG_W-1 downto 0);

        pct_lock     : in  unsigned(7 downto 0);   -- percent, default 25
        pct_unlock   : in  unsigned(7 downto 0);   -- percent, default 50
        window_log2  : in  unsigned(3 downto 0);

        locked       : out std_logic;
        ratio_pct    : out unsigned(7 downto 0);   -- live 100*S_num/S_den
        window_full  : out std_logic
    );
end entity sym_lock_detector;

architecture rtl of sym_lock_detector is

    constant C_MEM_DEPTH : natural := 2**G_MAX_WINDOW_LOG2;
    constant C_SUM_W     : natural := G_MAG_W + 1 + G_MAX_WINDOW_LOG2;

    type mag_mem_t is array (0 to C_MEM_DEPTH-1)
        of unsigned(G_MAG_W downto 0);          -- one extra bit: L+E
    signal num_mem : mag_mem_t := (others => (others => '0'));
    signal den_mem : mag_mem_t := (others => (others => '0'));

    signal s_num   : unsigned(C_SUM_W-1 downto 0) := (others => '0');
    signal s_den   : unsigned(C_SUM_W-1 downto 0) := (others => '0');
    signal wr_ptr  : unsigned(G_MAX_WINDOW_LOG2-1 downto 0) := (others => '0');
    signal fill    : unsigned(G_MAX_WINDOW_LOG2 downto 0)   := (others => '0');
    signal locked_r: std_logic := '0';
    signal wlog_r  : unsigned(3 downto 0) := (others => '0');

    -- subtractive divider for the ratio_pct readback: pct = 100*S_num/S_den,
    -- quotient bounded ~200, one subtraction per clock, retriggered per
    -- symbol (symbols are ~1845 clocks apart -- always finishes fresh)
    signal div_busy : std_logic := '0';
    signal div_acc  : unsigned(C_SUM_W+7 downto 0) := (others => '0');
    signal div_den  : unsigned(C_SUM_W+7 downto 0) := (others => '0');
    signal div_q    : unsigned(7 downto 0) := (others => '0');
    signal pct_r    : unsigned(7 downto 0) := (others => '0');

begin

    locked      <= locked_r;
    ratio_pct   <= pct_r;
    window_full <= '1' when fill = shift_left(
                       to_unsigned(1, fill'length),
                       to_integer(wlog_r)) else '0';

    detector : process(clk)
        variable num  : unsigned(G_MAG_W downto 0);
        variable den  : unsigned(G_MAG_W downto 0);
        variable wlen : unsigned(fill'range);
        variable sn   : unsigned(C_SUM_W-1 downto 0);
        variable sd   : unsigned(C_SUM_W-1 downto 0);
        variable lhs  : unsigned(C_SUM_W+7 downto 0);
        variable rl   : unsigned(C_SUM_W+7 downto 0);
        variable ru   : unsigned(C_SUM_W+7 downto 0);
    begin
        if rising_edge(clk) then
            if init = '1' then
                -- RESET BRANCH IS TRUTH (mirrors declaration initializers)
                s_num    <= (others => '0');
                s_den    <= (others => '0');
                wr_ptr   <= (others => '0');
                fill     <= (others => '0');
                locked_r <= '0';
                wlog_r   <= window_log2;
                div_busy <= '0';
                pct_r    <= (others => '0');
            else
                if window_log2 /= wlog_r then
                    wlog_r   <= window_log2;
                    s_num    <= (others => '0');
                    s_den    <= (others => '0');
                    wr_ptr   <= (others => '0');
                    fill     <= (others => '0');
                    locked_r <= '0';

                elsif e_valid = '1' then
                    if e_late >= e_early then
                        num := resize(e_late - e_early, G_MAG_W+1);
                    else
                        num := resize(e_early - e_late, G_MAG_W+1);
                    end if;
                    den := resize(e_late, G_MAG_W+1)
                         + resize(e_early, G_MAG_W+1);

                    wlen := shift_left(to_unsigned(1, wlen'length),
                                       to_integer(wlog_r));

                    sn := s_num + resize(num, C_SUM_W);
                    sd := s_den + resize(den, C_SUM_W);
                    if fill = wlen then
                        sn := sn - resize(num_mem(to_integer(wr_ptr)), C_SUM_W);
                        sd := sd - resize(den_mem(to_integer(wr_ptr)), C_SUM_W);
                    else
                        fill <= fill + 1;
                    end if;
                    s_num <= sn;  s_den <= sd;

                    num_mem(to_integer(wr_ptr)) <= num;
                    den_mem(to_integer(wr_ptr)) <= den;
                    if wr_ptr = wlen - 1 then
                        wr_ptr <= (others => '0');
                    else
                        wr_ptr <= wr_ptr + 1;
                    end if;

                    -- normalized-CFAR lock decision with hysteresis:
                    --   100*S_num <= pct_lock  *S_den  -> lock
                    --   100*S_num >= pct_unlock*S_den  -> unlock
                    if fill = wlen then
                        lhs := resize(sn * to_unsigned(100, 7), lhs'length);
                        rl  := resize(sd * pct_lock,   rl'length);
                        ru  := resize(sd * pct_unlock, ru'length);
                        if locked_r = '0' and lhs <= rl then
                            locked_r <= '1';
                        elsif locked_r = '1' and lhs >= ru then
                            locked_r <= '0';
                        end if;
                        -- kick the readback divider: pct = 100*S_num / S_den
                        div_acc  <= lhs;
                        div_den  <= resize(sd, div_den'length);
                        div_q    <= (others => '0');
                        div_busy <= '1';
                    end if;
                end if;

                -- subtractive divide: one subtraction per clock,
                -- quotient saturates at 255
                if div_busy = '1' then
                    if div_acc >= div_den and div_den /= 0
                       and div_q /= x"FF" then
                        div_acc <= div_acc - div_den;
                        div_q   <= div_q + 1;
                    else
                        pct_r    <= div_q;
                        div_busy <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process detector;

end architecture rtl;
