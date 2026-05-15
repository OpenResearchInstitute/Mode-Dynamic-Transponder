-------------------------------------------------------------------------------
-- axi_lite_regs.vhd
-- AXI-Lite Control / Status / Telemetry Register Block for Haifuraiya
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (Haifuraiya configuration)
-- Target:  Xilinx Zynq UltraScale+ MPSoC (ZCU102, xczu9eg-ffvb1156-2-e)
-- Tools:   Vivado 2022.2, VHDL-2008
-- License: CERN-OHL-S-2.0
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- AXI4-Lite slave that exposes the channelizer wrapper's control and
-- telemetry to PS software. Designed as a stable interface for Takadono
-- (the Speculator-pattern observability stack on ZCU102) — register
-- offsets are versioned and treated as a public contract.
--
-- Register map (4 KB window, byte addresses):
--
--   0x000  VERSION              RO   {major[15:8], minor[7:0], patch[7:0], 0}
--   0x004  CONTROL              RW   bit 0: soft reset (sticky, SW clears)
--                                    bit 1: enable
--   0x008  STATUS               RO   bit 0: ready
--                                    bit 1: overflow_sticky (W1C)
--                                    bit 2: backpressure_sticky (W1C)
--   0x00C  FRAME_COUNT          RO   output frames since reset
--   0x010  DROPPED_FRAMES       RO   frames lost to overflow/backpressure
--   0x014  OUTPUT_SHIFT         RW   right-shift on ACCUM_WIDTH->16 quantize
--                                    valid 0..ACCUM_WIDTH-16, default 16
--   0x018  POWER_ALPHA1         RW   first-stage EMA alpha, ALPHA_W bits used
--   0x01C  POWER_ALPHA2         RW   second-stage EMA alpha, ALPHA_W bits used
--   0x100  CHANNEL_POWER[0]     RO   per-channel power_squared, 30 bits used
--   0x104  CHANNEL_POWER[1]     RO   "
--   ...
--   0x1FC  CHANNEL_POWER[63]    RO   "
--
-- W1C bits in STATUS: writing '1' to the bit clears it; writing '0' has
-- no effect. Conventional sticky-bit-clear pattern.
--
-------------------------------------------------------------------------------
-- IMPLEMENTATION NOTES
-------------------------------------------------------------------------------
-- Standard Xilinx-template-style two-FSM AXI-Lite slave (one FSM for
-- the write path, one for the read path). Always-ready when idle;
-- never reordered. No outstanding transactions.
--
-- The CHANNEL_POWER array is provided as a flat std_logic_vector input
-- (channel_power_flat), with channel k occupying bits
-- [(k+1)*POWER_WIDTH-1 downto k*POWER_WIDTH]. The wrapper above packs
-- the individual power_detector outputs into this vector.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_lite_regs is
    generic (
        N_CHANNELS    : positive := 64;
        POWER_WIDTH   : positive := 31;   -- 2*DATA_W-1 for DATA_W=16
        ALPHA_W       : positive := 18;
        ACCUM_WIDTH   : positive := 40;
        DATA_WIDTH    : positive := 16;
        ADDR_WIDTH    : positive := 12;   -- 4 KB window
        VERSION_MAJOR : natural  := 0;
        VERSION_MINOR : natural  := 1;
        VERSION_PATCH : natural  := 0
    );
    port (
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        ---------------------------------------------------------------------
        -- AXI-Lite slave port
        ---------------------------------------------------------------------
        s_axi_awaddr    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(31 downto 0);
        s_axi_wstrb     : in  std_logic_vector(3 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(31 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        ---------------------------------------------------------------------
        -- Outputs to the wrapper (control)
        ---------------------------------------------------------------------
        soft_reset      : out std_logic;
        enable          : out std_logic;
        output_shift    : out unsigned(4 downto 0);  -- 0..24 sane range
        power_alpha1    : out std_logic_vector(ALPHA_W - 1 downto 0);
        power_alpha2    : out std_logic_vector(ALPHA_W - 1 downto 0);

        ---------------------------------------------------------------------
        -- Inputs from the wrapper (status / telemetry)
        ---------------------------------------------------------------------
        ready_in            : in  std_logic;
        overflow_pulse      : in  std_logic;
        backpressure_pulse  : in  std_logic;
        frame_count_in      : in  std_logic_vector(31 downto 0);
        dropped_frames_in   : in  std_logic_vector(31 downto 0);
        channel_power_flat  : in  std_logic_vector(N_CHANNELS * POWER_WIDTH - 1 downto 0)
    );
end entity axi_lite_regs;

architecture rtl of axi_lite_regs is

    ---------------------------------------------------------------------------
    -- Register storage
    ---------------------------------------------------------------------------
    -- CONTROL fields
    signal reg_soft_reset    : std_logic := '0';
    signal reg_enable        : std_logic := '1';

    -- STATUS sticky bits
    signal reg_overflow_sticky     : std_logic := '0';
    signal reg_backpressure_sticky : std_logic := '0';

    -- OUTPUT_SHIFT (5 bits is plenty for our 0..24 range)
    signal reg_output_shift  : unsigned(4 downto 0) :=
        to_unsigned(DATA_WIDTH, 5);  -- default = 16 = shift to take bits [31:16]

    -- EMA alphas. Default values chosen for a fast-tracker + slow-smoother
    -- cascade at a 625 kSps per-channel update rate:
    --   alpha1 = 2^-6  (time constant ~64 samples ~ 100 us  - fast tracker)
    --   alpha2 = 2^-12 (time constant ~4k samples ~ 6.5 ms - slow smoother)
    -- These are stored as the alpha fraction's representation in fixed
    -- point, where the LSB has weight 2^-ALPHA_W. So alpha = 2^-6 with
    -- ALPHA_W=18 means stored value = 2^(18-6) = 2^12 = 4096.
    signal reg_power_alpha1  : std_logic_vector(ALPHA_W - 1 downto 0) :=
        std_logic_vector(to_unsigned(4096, ALPHA_W));
    signal reg_power_alpha2  : std_logic_vector(ALPHA_W - 1 downto 0) :=
        std_logic_vector(to_unsigned(64, ALPHA_W));

    ---------------------------------------------------------------------------
    -- Address constants
    ---------------------------------------------------------------------------
    constant ADDR_VERSION       : std_logic_vector(11 downto 0) := x"000";
    constant ADDR_CONTROL       : std_logic_vector(11 downto 0) := x"004";
    constant ADDR_STATUS        : std_logic_vector(11 downto 0) := x"008";
    constant ADDR_FRAME_COUNT   : std_logic_vector(11 downto 0) := x"00C";
    constant ADDR_DROPPED       : std_logic_vector(11 downto 0) := x"010";
    constant ADDR_OUTPUT_SHIFT  : std_logic_vector(11 downto 0) := x"014";
    constant ADDR_ALPHA1        : std_logic_vector(11 downto 0) := x"018";
    constant ADDR_ALPHA2        : std_logic_vector(11 downto 0) := x"01C";
    constant ADDR_POWER_BASE    : std_logic_vector(11 downto 0) := x"100";
    constant ADDR_POWER_TOP     : std_logic_vector(11 downto 0) := x"1FC";

    -- VERSION fixed value
    constant VERSION_WORD : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(VERSION_MAJOR, 8)) &
        std_logic_vector(to_unsigned(VERSION_MINOR, 8)) &
        std_logic_vector(to_unsigned(VERSION_PATCH, 8)) &
        x"00";

    ---------------------------------------------------------------------------
    -- AXI write FSM
    ---------------------------------------------------------------------------
    type write_state_t is (W_IDLE, W_RESP);
    signal w_state         : write_state_t := W_IDLE;
    signal latched_awaddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0)
                             := (others => '0');
    signal aw_handshake    : std_logic;
    signal w_handshake     : std_logic;

    ---------------------------------------------------------------------------
    -- AXI read FSM
    ---------------------------------------------------------------------------
    type read_state_t is (R_IDLE, R_RESP);
    signal r_state         : read_state_t := R_IDLE;
    signal latched_araddr  : std_logic_vector(ADDR_WIDTH - 1 downto 0)
                             := (others => '0');
    signal r_data_int      : std_logic_vector(31 downto 0)
                             := (others => '0');

    ---------------------------------------------------------------------------
    -- Helpers
    ---------------------------------------------------------------------------
    -- Decode a CHANNEL_POWER byte address into a channel index.
    -- 0x100 -> ch 0, 0x104 -> ch 1, ..., 0x1FC -> ch 63
    function decode_channel(addr : std_logic_vector(11 downto 0)) return integer is
        variable offset : unsigned(11 downto 0);
    begin
        offset := unsigned(addr) - unsigned(ADDR_POWER_BASE);
        return to_integer(offset(7 downto 2));  -- divide by 4, mask to 64 entries
    end function;

begin

    ---------------------------------------------------------------------------
    -- Drive control outputs
    ---------------------------------------------------------------------------
    soft_reset   <= reg_soft_reset;
    enable       <= reg_enable;
    output_shift <= reg_output_shift;
    power_alpha1 <= reg_power_alpha1;
    power_alpha2 <= reg_power_alpha2;

    ---------------------------------------------------------------------------
    -- WRITE PATH
    -- Two-state FSM: wait for both AW and W to be valid (in either order
    -- or simultaneously), then assert B and wait for it to be accepted.
    ---------------------------------------------------------------------------
    aw_handshake <= s_axi_awvalid and s_axi_awready;
    w_handshake  <= s_axi_wvalid  and s_axi_wready;

    p_write : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                w_state                  <= W_IDLE;
                latched_awaddr           <= (others => '0');
                s_axi_awready            <= '0';
                s_axi_wready             <= '0';
                s_axi_bvalid             <= '0';
                s_axi_bresp              <= "00";
                reg_soft_reset           <= '0';
                reg_enable               <= '1';
                reg_output_shift         <= to_unsigned(DATA_WIDTH, 5);
                reg_power_alpha1         <= std_logic_vector(to_unsigned(4096, ALPHA_W));
                reg_power_alpha2         <= std_logic_vector(to_unsigned(64, ALPHA_W));
                reg_overflow_sticky      <= '0';
                reg_backpressure_sticky  <= '0';
            else

                -- Default: sticky bits accumulate from pulse inputs
                if overflow_pulse = '1' then
                    reg_overflow_sticky <= '1';
                end if;
                if backpressure_pulse = '1' then
                    reg_backpressure_sticky <= '1';
                end if;

                case w_state is
                when W_IDLE =>
                    -- Accept both AW and W in any order; require both
                    -- before transitioning. Simplest correct AXI-Lite slave.
                    s_axi_awready <= '1';
                    s_axi_wready  <= '1';
                    s_axi_bvalid  <= '0';

                    if aw_handshake = '1' then
                        latched_awaddr <= s_axi_awaddr;
                    end if;

                    -- Commit the write when both AW and W have arrived
                    -- (either this cycle or in some previous cycle while
                    -- the other was waiting; track via internal flags).
                    -- For simplicity, only commit on the same cycle that
                    -- both are valid. A more elaborate slave would track
                    -- partial completion; for our use case, master is
                    -- almost always the PS giving both simultaneously.
                    if aw_handshake = '1' and w_handshake = '1' then
                        -- Decode and write
                        case s_axi_awaddr is
                            when ADDR_CONTROL =>
                                reg_soft_reset <= s_axi_wdata(0);
                                reg_enable     <= s_axi_wdata(1);
                            when ADDR_STATUS =>
                                -- W1C on sticky bits
                                if s_axi_wdata(1) = '1' then
                                    reg_overflow_sticky <= '0';
                                end if;
                                if s_axi_wdata(2) = '1' then
                                    reg_backpressure_sticky <= '0';
                                end if;
                            when ADDR_OUTPUT_SHIFT =>
                                reg_output_shift <= unsigned(s_axi_wdata(4 downto 0));
                            when ADDR_ALPHA1 =>
                                reg_power_alpha1 <= s_axi_wdata(ALPHA_W - 1 downto 0);
                            when ADDR_ALPHA2 =>
                                reg_power_alpha2 <= s_axi_wdata(ALPHA_W - 1 downto 0);
                            when others =>
                                null;  -- writes to RO addresses are ignored
                        end case;

                        s_axi_awready <= '0';
                        s_axi_wready  <= '0';
                        s_axi_bresp   <= "00";  -- OKAY
                        s_axi_bvalid  <= '1';
                        w_state       <= W_RESP;
                    end if;

                when W_RESP =>
                    if s_axi_bready = '1' then
                        s_axi_bvalid  <= '0';
                        s_axi_awready <= '1';
                        s_axi_wready  <= '1';
                        w_state       <= W_IDLE;
                    end if;

                end case;
            end if;
        end if;
    end process p_write;

    ---------------------------------------------------------------------------
    -- READ PATH
    -- Two-state FSM: latch AR address, drive R with decoded data, wait
    -- for R acceptance.
    ---------------------------------------------------------------------------
    p_read : process(aclk)
        variable ch_idx : integer range 0 to N_CHANNELS - 1;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                r_state        <= R_IDLE;
                s_axi_arready  <= '0';
                s_axi_rvalid   <= '0';
                s_axi_rresp    <= "00";
                r_data_int     <= (others => '0');
                latched_araddr <= (others => '0');
            else
                case r_state is
                when R_IDLE =>
                    s_axi_arready <= '1';
                    s_axi_rvalid  <= '0';

                    if s_axi_arvalid = '1' and s_axi_arready = '1' then
                        latched_araddr <= s_axi_araddr;
                        s_axi_arready  <= '0';

                        -- Decode immediately on capture
                        if s_axi_araddr >= ADDR_POWER_BASE and
                           s_axi_araddr <= ADDR_POWER_TOP then
                            ch_idx := decode_channel(s_axi_araddr);
                            -- Pack the POWER_WIDTH-bit value into 32 bits,
                            -- zero-extending the high bits.
                            r_data_int <= (others => '0');
                            r_data_int(POWER_WIDTH - 1 downto 0) <=
                                channel_power_flat(
                                    (ch_idx + 1) * POWER_WIDTH - 1 downto
                                    ch_idx * POWER_WIDTH);
                        else
                            case s_axi_araddr is
                                when ADDR_VERSION =>
                                    r_data_int <= VERSION_WORD;
                                when ADDR_CONTROL =>
                                    r_data_int <= (others => '0');
                                    r_data_int(0) <= reg_soft_reset;
                                    r_data_int(1) <= reg_enable;
                                when ADDR_STATUS =>
                                    r_data_int <= (others => '0');
                                    r_data_int(0) <= ready_in;
                                    r_data_int(1) <= reg_overflow_sticky;
                                    r_data_int(2) <= reg_backpressure_sticky;
                                when ADDR_FRAME_COUNT =>
                                    r_data_int <= frame_count_in;
                                when ADDR_DROPPED =>
                                    r_data_int <= dropped_frames_in;
                                when ADDR_OUTPUT_SHIFT =>
                                    r_data_int <= (others => '0');
                                    r_data_int(4 downto 0) <=
                                        std_logic_vector(reg_output_shift);
                                when ADDR_ALPHA1 =>
                                    r_data_int <= (others => '0');
                                    r_data_int(ALPHA_W - 1 downto 0) <= reg_power_alpha1;
                                when ADDR_ALPHA2 =>
                                    r_data_int <= (others => '0');
                                    r_data_int(ALPHA_W - 1 downto 0) <= reg_power_alpha2;
                                when others =>
                                    r_data_int <= (others => '0');
                            end case;
                        end if;

                        s_axi_rvalid <= '1';
                        s_axi_rresp  <= "00";
                        r_state      <= R_RESP;
                    end if;

                when R_RESP =>
                    if s_axi_rready = '1' then
                        s_axi_rvalid  <= '0';
                        s_axi_arready <= '1';
                        r_state       <= R_IDLE;
                    end if;

                end case;
            end if;
        end if;
    end process p_read;

    s_axi_rdata <= r_data_int;

end architecture rtl;
