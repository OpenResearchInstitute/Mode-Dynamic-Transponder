-- tb_fill_probe.vhd : mechanistic probe (fixed file only; maps debug_sync_fill).
-- Feeds symbols after a clear and prints fill_prev + state each symbol, showing
-- the window filling one tap per symbol and HUNTING held until fill = 24.
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY tb_fill_probe IS END ENTITY;

ARCHITECTURE b OF tb_fill_probe IS
    CONSTANT CLK_PERIOD : time := 10 ns;
    SIGNAL clk : std_logic := '0';
    SIGNAL done : boolean := false;
    SIGNAL reset : std_logic := '1';
    SIGNAL rx_bit, rx_bit_valid : std_logic := '0';
    SIGNAL soft : signed(15 DOWNTO 0) := (OTHERS=>'0');
    SIGNAL dstate : std_logic_vector(2 DOWNTO 0);
    SIGNAL dfill  : std_logic_vector(4 DOWNTO 0);
    SIGNAL dsl : std_logic := '0';
    SIGNAL sym : integer := 0;
BEGIN
    clk_p : PROCESS BEGIN
        WHILE NOT done LOOP clk<='0'; WAIT FOR CLK_PERIOD/2; clk<='1'; WAIT FOR CLK_PERIOD/2; END LOOP; WAIT;
    END PROCESS;

    dut : ENTITY work.frame_sync_detector_soft
        GENERIC MAP (SYNC_WORD => x"02B8DB", PAYLOAD_BYTES => 268)
        PORT MAP (
            clk=>clk, reset=>reset, rx_bit=>rx_bit, rx_bit_valid=>rx_bit_valid,
            s_axis_soft_tdata=>soft,
            m_axis_tdata=>OPEN, m_axis_tvalid=>OPEN, m_axis_tready=>'1', m_axis_tlast=>OPEN,
            m_axis_soft_bit_tdata=>OPEN, m_axis_soft_bit_tvalid=>OPEN, m_axis_soft_bit_tready=>'1', m_axis_soft_bit_tlast=>OPEN,
            frame_sync_locked=>OPEN, frames_received=>OPEN, frame_sync_errors=>OPEN, frame_buffer_overflow=>OPEN,
            demod_sync_lock=>dsl,
            hunting_threshold_i=>std_logic_vector(to_signed(85,32)),
            locked_threshold_i=>std_logic_vector(to_signed(70,32)),
            quant_thr_1_i=>std_logic_vector(to_signed(500,16)),
            quant_thr_2_i=>std_logic_vector(to_signed(1400,16)),
            quant_thr_3_i=>std_logic_vector(to_signed(2800,16)),
            debug_state=>dstate, debug_correlation=>OPEN, debug_corr_peak=>OPEN,
            debug_bit_count=>OPEN, debug_missed_syncs=>OPEN, debug_consecutive_good=>OPEN,
            debug_soft_current=>OPEN, debug_soft_quantized=>OPEN, debug_byte_v=>OPEN,
            debug_sync_fill=>dfill
        );

    stim : PROCESS
        PROCEDURE feed(v : integer) IS BEGIN
            soft <= to_signed(v,16);
            IF v<0 THEN rx_bit<='1'; ELSE rx_bit<='0'; END IF;
            rx_bit_valid<='1'; WAIT UNTIL rising_edge(clk); rx_bit_valid<='0';
            sym <= sym+1;
            WAIT UNTIL rising_edge(clk); WAIT UNTIL rising_edge(clk);
            REPORT "sym=" & integer'image(sym)
                 & "  fill_prev=" & integer'image(to_integer(unsigned(dfill)))
                 & "  state=" & integer'image(to_integer(unsigned(dstate)))
                 & "  (1=HUNT 2=LOCKED)";
        END PROCEDURE;
    BEGIN
        reset<='1'; dsl<='0'; WAIT FOR 5*CLK_PERIOD; WAIT UNTIL rising_edge(clk); reset<='0';
        WAIT FOR 5*CLK_PERIOD; WAIT UNTIL rising_edge(clk); dsl<='1'; sym<=0; WAIT FOR 4*CLK_PERIOD;
        feed(-20000);  -- s1
        feed(100);     -- s2: OLD code locked HERE
        feed(-300); feed(300); feed(-300); feed(300);  -- s3..s6
        done<=true; WAIT;
    END PROCESS;
END ARCHITECTURE;
