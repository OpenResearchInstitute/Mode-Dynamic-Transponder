-- Drop-in capture for the fabric soft seam (frame_sync_detector_soft.m_axis_soft_bit)
-- Add inside ARCHITECTURE behavior OF tb_msk_modem_134byte (VHDL-2008; ghdl/nvc).
-- Writes one 3-bit soft value (0..7) per AXIS beat to seam_out.txt.
-- Then on the host:  opv-decode -3 -r < <(python3 -c "print bytes...")  (see seam_diag.py)
--
-- NOTE: hierarchical path assumes the DUT instance is named "DUT" and msk_top's
-- internal signals are sync_det_soft_*. Adjust the external names if either differs.

  -- declarations (architecture declarative part):
  signal cap_tdata  : std_logic_vector(2 downto 0);
  signal cap_tvalid : std_logic;
  signal cap_tready : std_logic;
  signal cap_tlast  : std_logic;

  -- concurrent (architecture body):
  cap_tdata  <= << signal .tb_msk_modem_134byte.DUT.sync_det_soft_tdata  : std_logic_vector(2 downto 0) >>;
  cap_tvalid <= << signal .tb_msk_modem_134byte.DUT.sync_det_soft_tvalid : std_logic >>;
  cap_tready <= << signal .tb_msk_modem_134byte.DUT.sync_det_soft_tready : std_logic >>;
  cap_tlast  <= << signal .tb_msk_modem_134byte.DUT.sync_det_soft_tlast  : std_logic >>;

  soft_seam_cap : process(clk)
    file g : text open write_mode is "seam_out.txt";
    variable l : line;
  begin
    if rising_edge(clk) then
      if cap_tvalid = '1' and cap_tready = '1' then   -- a real AXIS transfer
        write(l, to_integer(unsigned(cap_tdata)));
        writeline(g, l);
      end if;
    end if;
  end process;
