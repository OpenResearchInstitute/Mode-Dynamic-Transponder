-- halfband_decimator.vhd
-- Haifuraiya 2:1 halfband decimator: 20 Msps complex in -> 10 Msps complex out.
-- Feeds the channelizer its designed 10.000 Msps so the 156.25 kHz grid is correct.
--
-- Structure (matches halfband_decimator.py / channel golden model, bit-exact):
--   - linear-phase symmetric FIR, halfband => only even-index taps are nonzero,
--     and the center tap (index 37) is exactly 0.5 -> a <<16 shift, not a multiply.
--   - 19 symmetric pre-adds (dl[2j] + dl[74-2j], j=0..18) feed 19 multipliers by
--     HB_TAPS(2j); the center sample dl[37] is shifted left 16 and added in.
--   - the 19 products + center term are summed in a PIPELINED BALANCED ADDER TREE
--     (5 registered levels: 20->10->5->3->2->1) so no single clock period sees
--     more than one adder.  This replaced a single-cycle linear accumulate, which
--     Vivado mapped to an unregistered ~18-deep DSP PCIN/PCOUT cascade (~13.5 ns
--     of logic, 94% logic / 6% route) and blew clk_pl_0 setup by 3.7 ns across
--     the whole 48-bit x 2-lane accumulator (~2492 failing endpoints).  The tree
--     reorders the additions, but with 48-bit headroom and no truncation until
--     the final round, the sum is bit-identical to the linear accumulate / model.
--   - round-half-up (+2^16), arithmetic >>17, saturate to 16-bit.
--   - output asserted on every 2nd input sample (decimate by 2).
--
-- Pipeline (output rate 10 Msps on a 100 MHz fabric):
--   s0 shift/phase -> s1 pre-add -> s2 multiply -> s3a..s3e adder tree -> s4 round.
--   Latency is a fixed +4 cycles vs the old linear sum; I and Q are symmetric so
--   they stay aligned, and the channelizer tolerates any constant input latency.
--
-- Verify in xsim against tb_halfband_decimator.vhd using tb_input.txt / tb_expected.txt.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.halfband_taps_pkg.all;          -- HB_LEN, HB_CENTER, HB_TAPS, hb_coeff_t

entity halfband_decimator is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;            -- synchronous, active high
    in_valid  : in  std_logic;            -- one 20 Msps complex sample present
    in_i      : in  signed(15 downto 0);
    in_q      : in  signed(15 downto 0);
    out_valid : out std_logic;            -- one 10 Msps complex sample present
    out_i     : out signed(15 downto 0);
    out_q     : out signed(15 downto 0)
  );
end entity halfband_decimator;

architecture rtl of halfband_decimator is
  constant NTAP : integer := HB_LEN;                -- 75
  constant CIDX : integer := HB_CENTER;             -- 37
  constant NMUL : integer := (CIDX + 1) / 2;        -- 19  (tap index = 2*j)
  constant SH   : integer := 17;                    -- coeff scale = 2^17
  constant ACCW : integer := 48;

  type sample_arr is array(0 to NTAP-1) of signed(15 downto 0);
  type lane_dl    is array(0 to 1)      of sample_arr;
  signal dl : lane_dl := (others => (others => (others => '0')));

  signal ph     : std_logic := '0';
  signal emit_s : std_logic := '0';

  type preadd_arr is array(0 to NMUL-1) of signed(16 downto 0);   -- 17-bit pre-add
  type lane_pre   is array(0 to 1)      of preadd_arr;
  type center_arr is array(0 to 1)      of signed(15 downto 0);
  type prod_arr   is array(0 to NMUL-1) of signed(34 downto 0);   -- 18*17 -> 35-bit
  type lane_prod  is array(0 to 1)      of prod_arr;
  type acc_arr    is array(0 to 1)      of signed(ACCW-1 downto 0);

  -- adder-tree node array: NMUL products + 1 center term = NMUL+1 = 20 addends.
  type addend_arr  is array(0 to NMUL) of signed(ACCW-1 downto 0);
  type lane_addend is array(0 to 1)    of addend_arr;

  signal pre   : lane_pre;
  signal cen   : center_arr;
  signal prod  : lane_prod;
  signal cterm : acc_arr;
  signal acc   : acc_arr;

  -- registered adder-tree levels (valid node counts after each: 10, 5, 3, 2)
  signal lvl1, lvl2, lvl3, lvl4 : lane_addend;

  signal v_pre, v_prod          : std_logic := '0';
  signal v_t1, v_t2, v_t3, v_t4 : std_logic := '0';
  signal v_acc                  : std_logic := '0';

  -- one pipelined level of a pairwise adder tree: sums the first n nodes of a
  -- into ceil(n/2) nodes (an odd tail node is carried straight up).  One adder
  -- deep, all pairs evaluated in parallel.
  function reduce(a : addend_arr; n : integer) return addend_arr is
    variable r : addend_arr := (others => (others => '0'));
  begin
    for j in 0 to (n-1)/2 loop
      if (2*j + 1) <= (n-1) then
        r(j) := a(2*j) + a(2*j+1);
      else
        r(j) := a(2*j);
      end if;
    end loop;
    return r;
  end function;

  function sat16(x : signed) return signed is
  begin
    if    x > to_signed(32767,  x'length) then return to_signed(32767,  16);
    elsif x < to_signed(-32768, x'length) then return to_signed(-32768, 16);
    else  return resize(x, 16);
    end if;
  end function;

begin
  process(clk)
    variable ad  : addend_arr;
    variable top : addend_arr;
    variable r   : signed(ACCW-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= '0'; emit_s <= '0';
        v_pre <= '0'; v_prod <= '0';
        v_t1 <= '0'; v_t2 <= '0'; v_t3 <= '0'; v_t4 <= '0';
        v_acc <= '0'; out_valid <= '0';
      else
        -- stage 0: shift delay lines, toggle phase, raise emit on every 2nd sample
        if in_valid = '1' then
          dl(0)(0) <= in_i;
          dl(1)(0) <= in_q;
          for i in 1 to NTAP-1 loop
            dl(0)(i) <= dl(0)(i-1);
            dl(1)(i) <= dl(1)(i-1);
          end loop;
          ph     <= not ph;
          emit_s <= ph;             -- ph='1' this cycle => this is the 2nd of a pair
        else
          emit_s <= '0';
        end if;

        -- stage 1: symmetric pre-adds (dl now reflects the just-shifted sample)
        v_pre <= emit_s;
        if emit_s = '1' then
          for lane in 0 to 1 loop
            for j in 0 to NMUL-1 loop
              pre(lane)(j) <= resize(dl(lane)(2*j), 17)
                            + resize(dl(lane)(NTAP-1-2*j), 17);
            end loop;
            cen(lane) <= dl(lane)(CIDX);
          end loop;
        end if;

        -- stage 2: 19 products + the center-tap shift (0.5 -> <<16)
        v_prod <= v_pre;
        if v_pre = '1' then
          for lane in 0 to 1 loop
            for j in 0 to NMUL-1 loop
              prod(lane)(j) <= HB_TAPS(2*j) * pre(lane)(j);
            end loop;
            cterm(lane) <= shift_left(resize(cen(lane), ACCW), SH-1);
          end loop;
        end if;

        -- stage 3a: assemble 20 addends (19 products + center), reduce 20 -> 10
        v_t1 <= v_prod;
        if v_prod = '1' then
          for lane in 0 to 1 loop
            for j in 0 to NMUL-1 loop
              ad(j) := resize(prod(lane)(j), ACCW);
            end loop;
            ad(NMUL) := cterm(lane);            -- index 19 = center term
            lvl1(lane) <= reduce(ad, NMUL+1);   -- 20 -> 10
          end loop;
        end if;

        -- stage 3b: 10 -> 5
        v_t2 <= v_t1;
        if v_t1 = '1' then
          for lane in 0 to 1 loop
            lvl2(lane) <= reduce(lvl1(lane), 10);
          end loop;
        end if;

        -- stage 3c: 5 -> 3
        v_t3 <= v_t2;
        if v_t2 = '1' then
          for lane in 0 to 1 loop
            lvl3(lane) <= reduce(lvl2(lane), 5);
          end loop;
        end if;

        -- stage 3d: 3 -> 2
        v_t4 <= v_t3;
        if v_t3 = '1' then
          for lane in 0 to 1 loop
            lvl4(lane) <= reduce(lvl3(lane), 3);
          end loop;
        end if;

        -- stage 3e: 2 -> 1 (final sum)
        v_acc <= v_t4;
        if v_t4 = '1' then
          for lane in 0 to 1 loop
            top := reduce(lvl4(lane), 2);
            acc(lane) <= top(0);
          end loop;
        end if;

        -- stage 4: round-half-up, arithmetic >>17, saturate to 16-bit
        out_valid <= v_acc;
        if v_acc = '1' then
          r := acc(0) + to_signed(2**(SH-1), ACCW);
          out_i <= sat16(shift_right(r, SH));
          r := acc(1) + to_signed(2**(SH-1), ACCW);
          out_q <= sat16(shift_right(r, SH));
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
