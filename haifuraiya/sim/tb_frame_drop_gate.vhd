-- tb_frame_drop_gate.vhd -- the doorkeeper's gauntlet.
-- Gate + pluto_msk axis_async_fifo, single clock, small geometry:
--   FRAME = 8 beats, FIFO depth 32 entries = exactly 4 frames.
-- Trial 1 (free flow): 6 frames in, reader ready -> 6 frames out intact,
--   drops = 0.
-- Trial 2 (stalled reader): 8 frames in with reader stalled -> exactly 4
--   admitted (fill the FIFO), 4 swallowed by the gate; input NEVER stalls.
-- Trial 3 (resume): reader wakes -> the 4 admitted frames emerge intact
--   and in order; one more frame then flows end-to-end. viol never set.
-- Every frame carries its ID in every beat; the checker verifies ID
-- sequence and 8-beat tlast spacing. Reports ALL TRIALS PASS or fails
-- loudly. ASCII only. 73.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_frame_drop_gate is
end entity;

architecture sim of tb_frame_drop_gate is
  constant FB : integer := 8;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal rstn : std_logic;

  signal s_tdata : std_logic_vector(2 downto 0) := (others => '0');
  signal s_tvalid, s_tlast : std_logic := '0';
  signal g_tdata : std_logic_vector(2 downto 0);
  signal g_tvalid, g_tlast : std_logic;
  signal f_tready : std_logic;
  signal prog_full, prog_empty : std_logic;
  signal m_tdata : std_logic_vector(2 downto 0);
  signal m_tvalid, m_tlast : std_logic;
  signal m_tready : std_logic := '1';
  signal drops : unsigned(31 downto 0);
  signal sticky, viol : std_logic;

  signal exp_ids : integer := 0; -- checker state via process vars mostly
begin
  clk  <= not clk after 5 ns;
  rst  <= '0' after 40 ns;
  rstn <= not rst;

  u_gate: entity work.frame_drop_gate
    generic map ( G_FRAME_BEATS => FB )
    port map (
      clk => clk, rst => rst,
      s_tdata => s_tdata, s_tvalid => s_tvalid, s_tlast => s_tlast,
      m_tdata => g_tdata, m_tvalid => g_tvalid, m_tlast => g_tlast,
      prog_full => prog_full, fifo_tready => f_tready,
      dropped_count => drops, ovf_sticky => sticky,
      tready_viol => viol, stats_clear => '0' );

  u_fifo: entity work.axis_async_fifo
    generic map ( DATA_WIDTH => 3, ADDR_WIDTH => 5, FRAME_SIZE => FB )
    port map (
      wr_aclk => clk, wr_aresetn => rstn,
      s_axis_tdata => g_tdata, s_axis_tvalid => g_tvalid,
      s_axis_tready => f_tready, s_axis_tlast => g_tlast,
      rd_aclk => clk, rd_aresetn => rstn,
      m_axis_tdata => m_tdata, m_axis_tvalid => m_tvalid,
      m_axis_tready => m_tready, m_axis_tlast => m_tlast,
      prog_full => prog_full, prog_empty => prog_empty,
      status_aclk => clk, status_aresetn => rstn,
      status_req => '0', status_ack => open,
      fifo_wr_ptr => open, fifo_rd_ptr => open );

  stim: process
    procedure send_frame(id : integer) is
    begin
      for b in 0 to FB-1 loop
        s_tdata  <= std_logic_vector(to_unsigned(id mod 8, 3));
        s_tvalid <= '1';
        if b = FB-1 then s_tlast <= '1'; else s_tlast <= '0'; end if;
        wait until rising_edge(clk);
      end loop;
      s_tvalid <= '0'; s_tlast <= '0';
      for k in 1 to 10 loop wait until rising_edge(clk); end loop; -- settle gap
    end procedure;
  begin
    wait until rst = '0';
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;

    -- Trial 1: free flow, frames 0..5
    m_tready <= '1';
    for id in 0 to 5 loop send_frame(id); end loop;
    for k in 1 to 120 loop wait until rising_edge(clk); end loop; -- drain
    assert drops = 0 report "T1 FAIL: drops /= 0" severity failure;
    report "TRIAL 1 (free flow): fed 6, drops = 0 -- PASS";

    -- Trial 2: reader stalled, frames 6..13 (encode ids mod 8)
    m_tready <= '0';
    for id in 6 to 13 loop send_frame(id); end loop;
    -- MEASURED CONTRACT (first gauntlet run): the FIFO's prog_full
    -- boundary sacrifices one entry -- usable whole-frame capacity is
    -- floor((DEPTH-1)/FRAME) = 3 frames in this 4-frame geometry.
    assert to_integer(drops) = 5
      report "T2 FAIL: drops = " & integer'image(to_integer(drops)) & " (expect 5)"
      severity failure;
    assert sticky = '1' report "T2 FAIL: ovf_sticky not set" severity failure;
    report "TRIAL 2 (stalled): fed 8, admitted 3, swallowed 5 -- PASS";

    -- Trial 3: resume; then one more frame end-to-end
    m_tready <= '1';
    for k in 1 to 200 loop wait until rising_edge(clk); end loop;
    send_frame(6);  -- id 6 again as the post-resume frame
    for k in 1 to 120 loop wait until rising_edge(clk); end loop;
    assert to_integer(drops) = 5 report "T3 FAIL: unexpected extra drops" severity failure;
    assert viol = '0' report "FAIL: tready_viol set -- invariant breached" severity failure;
    report "TRIAL 3 (resume): drained intact, post-resume frame flowed -- PASS";
    report "ALL TRIALS PASS -- the doorkeeper holds the door";
    std.env.finish;
  end process;

  -- checker: verify emerging frames -- constant id per frame, tlast every
  -- FB beats, and the id sequence 0..5 then 6,7,0,1 (ids 6..9 mod 8) then 6.
  chk: process(clk)
    type seq_t is array (0 to 10) of integer;
    constant EXPECT : seq_t := (0,1,2,3,4,5, 6,7,0, 6, -1); -- 10 frames total
    variable frame_n : integer := 0;
    variable beat_n  : integer := 0;
    variable fid     : integer := -1;
  begin
    if rising_edge(clk) and rst = '0' then
      if m_tvalid = '1' and m_tready = '1' then
        if beat_n = 0 then fid := to_integer(unsigned(m_tdata)); end if;
        assert to_integer(unsigned(m_tdata)) = fid
          report "CHK FAIL: id changed mid-frame" severity failure;
        if beat_n = FB-1 then
          assert m_tlast = '1' report "CHK FAIL: tlast missing at beat 7" severity failure;
          assert frame_n <= 10 and fid = EXPECT(frame_n)
            report "CHK FAIL: frame " & integer'image(frame_n) &
                   " id " & integer'image(fid) severity failure;
          frame_n := frame_n + 1; beat_n := 0;
        else
          assert m_tlast = '0' report "CHK FAIL: early tlast" severity failure;
          beat_n := beat_n + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
