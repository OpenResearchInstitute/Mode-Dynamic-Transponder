-------------------------------------------------------------------------------
-- tb_cnm_extpow_equiv.vhd -- POWER_INTERNAL true/false equivalence.
--
-- Two instances of channel_normalizer_mux, same stimulus:
--   A: POWER_INTERNAL=true   (squares in-block, 2 DSP)
--   B: POWER_INTERNAL=false  (takes dsum on power_ext, 0 DSP)
-- B's power_ext is driven with the saturating I^2+Q^2 that the shared power
-- detector's squaring stage produces (WP2 Table B: dsum = di_sq + dq_sq, 31b).
--
-- If A and B are not beat-for-beat identical, "share the squaring, not the
-- smoothing" is not a free change and must not be made.
-------------------------------------------------------------------------------
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all; use std.env.all;
entity tb_cnm_extpow_equiv is generic (VEC_DIR : string := ""); end entity;
architecture sim of tb_cnm_extpow_equiv is
  constant N_CH:positive:=64; constant CW:positive:=6; constant DW:positive:=16;
  constant GW:positive:=16; constant GF:positive:=10; constant PW:positive:=31;
  signal clk:std_logic:='0'; signal rst:std_logic:='1';
  signal iv:std_logic:='0'; signal ic:unsigned(CW-1 downto 0):=(others=>'0');
  signal ii,iq:signed(DW-1 downto 0):=(others=>'0');
  signal pext:std_logic_vector(PW-1 downto 0):=(others=>'0');
  signal sq:std_logic_vector(PW-1 downto 0):=std_logic_vector(to_unsigned(1000000,PW));
  signal lw:std_logic:='0'; signal la:std_logic_vector(4 downto 0):=(others=>'0');
  signal ld:std_logic_vector(GW-1 downto 0):=(others=>'0');
  signal avA,avB:std_logic; signal acA,acB:unsigned(CW-1 downto 0);
  signal aiA,aqA,aiB,aqB:signed(DW-1 downto 0);
  signal tcA:unsigned(CW-1 downto 0):=(others=>'0');
  signal teA,teB:std_logic_vector(PW-1 downto 0);
  signal tgA,tgB:std_logic_vector(GW-1 downto 0);
  signal thA,thB,gsA,gsB:std_logic;
  signal bad:integer:=0; signal chk:integer:=0; signal done:boolean:=false;
  signal feed_done:boolean:=false;
begin
  clk <= not clk after 5 ns when not done else '0';

  -- the shared power detector's squaring stage: dsum = I^2 + Q^2, saturating
  p_dsum : process(ii,iq)
    variable s : unsigned(2*DW downto 0);
  begin
    s := resize(unsigned(ii*ii),2*DW+1) + resize(unsigned(iq*iq),2*DW+1);
    if s > resize(unsigned'(to_unsigned(0,PW)) - 1, 2*DW+1) then
      pext <= (others=>'1');
    else
      pext <= std_logic_vector(resize(s,PW));
    end if;
  end process;

  A : entity work.channel_normalizer_mux
    generic map (N_CHANNELS=>N_CH, POWER_INTERNAL=>true, CHAN_W=>CW, DATA_W=>DW,
                 GAIN_W=>GW, GAIN_FRAC=>GF, POWER_W=>PW, HYST_DWELL=>16)
    port map (clk=>clk,rst=>rst,in_valid=>iv,in_chan=>ic,in_i=>ii,in_q=>iq,
      power_ext=>(others=>'0'), gain_mode=>'1',
      gain_manual=>std_logic_vector(to_unsigned(1024,GW)),
      attack_shift=>to_unsigned(4,5),release_shift=>to_unsigned(6,5),
      squelch_thr=>sq,freeze=>'0',lut_we=>lw,lut_addr=>la,lut_wdata=>ld,
      out_valid=>avA,out_chan=>acA,out_i=>aiA,out_q=>aqA,
      tlm_chan=>tcA,tlm_env=>teA,tlm_gain=>tgA,tlm_held=>thA,gain_sat=>gsA);

  B : entity work.channel_normalizer_mux
    generic map (N_CHANNELS=>N_CH, POWER_INTERNAL=>false, CHAN_W=>CW, DATA_W=>DW,
                 GAIN_W=>GW, GAIN_FRAC=>GF, POWER_W=>PW, HYST_DWELL=>16)
    port map (clk=>clk,rst=>rst,in_valid=>iv,in_chan=>ic,in_i=>ii,in_q=>iq,
      power_ext=>pext, gain_mode=>'1',
      gain_manual=>std_logic_vector(to_unsigned(1024,GW)),
      attack_shift=>to_unsigned(4,5),release_shift=>to_unsigned(6,5),
      squelch_thr=>sq,freeze=>'0',lut_we=>lw,lut_addr=>la,lut_wdata=>ld,
      out_valid=>avB,out_chan=>acB,out_i=>aiB,out_q=>aqB,
      tlm_chan=>tcA,tlm_env=>teB,tlm_gain=>tgB,tlm_held=>thB,gain_sat=>gsB);

  cmp : process(clk) begin
    if rising_edge(clk) and rst='0' then
      if avA/=avB then bad<=bad+1; end if;
      if avA='1' then
        chk<=chk+1;
        if acA/=acB or aiA/=aiB or aqA/=aqB then bad<=bad+1; end if;
      end if;
    end if;
  end process;

  main : process
    file fl,fi : text; variable L:line; variable v,vc,vin,vq,vv:integer;
  begin
    rst<='1'; wait for 100 ns; wait until rising_edge(clk); rst<='0';
    wait until rising_edge(clk);
    file_open(fl, VEC_DIR & "cnm_lut.txt", read_mode);
    for a in 0 to 31 loop
      readline(fl,L); read(L,v);
      lw<='1'; la<=std_logic_vector(to_unsigned(a,5));
      ld<=std_logic_vector(to_unsigned(v,GW));
      wait until rising_edge(clk);
    end loop;
    file_close(fl); lw<='0'; wait until rising_edge(clk);

    file_open(fi, VEC_DIR & "cnm_input.txt", read_mode);
    while not endfile(fi) loop
      readline(fi,L); read(L,vc); read(L,vin); read(L,vq); read(L,vv);
      ic<=to_unsigned(vc,CW); ii<=to_signed(vin,DW); iq<=to_signed(vq,DW);
      if vv=1 then iv<='1'; else iv<='0'; end if;
      wait until rising_edge(clk);
    end loop;
    file_close(fi); iv<='0';
    for k in 0 to 7 loop wait until rising_edge(clk); end loop;

    report "=======================================================";
    report "tb_cnm_extpow_equiv: beats compared = " & integer'image(chk)
         & "   mismatches = " & integer'image(bad);
    assert bad=0 and chk>0
      report "POWER_INTERNAL true/false NOT equivalent" severity failure;
    report "EXT-POWER EQUIVALENCE PASSED: sharing the squaring is free"
      severity note;
    report "=======================================================";
    done<=true; finish;
  end process;
end architecture;
