-------------------------------------------------------------------------------
-- sic_top_ice40.vhd
-- Top-Level SIC Receiver for iCE40UP5K-B-EVN
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Mode Dynamic Transponder (MDT) SIC Receiver
-- Target:  Lattice iCE40UP5K-B-EVN + STM32H753ZI Nucleo
-- Author:  Open Research Institute Engineering Team
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the iCE40-specific top level for the MDT SIC (Successive
-- Interference Cancellation) receiver. It wraps the polyphase channelizer
-- with:
--
--   1. SPI slave interface to STM32H7 (data output and control)
--   2. I2S receiver for ADC input (audio/IQ samples from TLV320ADC6120)
--   3. Clock distribution from 12 MHz oscillator
--   4. Status LEDs for visual bringup feedback
--
-- SIC ALGORITHM OVERVIEW
-- ----------------------
-- The SIC algorithm cancels strong interfering signals so that weaker
-- signals of interest become detectable. Processing is split between
-- FPGA and MCU:
--
--   FPGA (this file):
--     - Receives wideband IQ samples from ADC over I2S
--     - Splits signal into N frequency channels using polyphase channelizer
--     - Outputs per-channel complex IQ data over SPI to STM32
--
--   STM32H7 (sic_fpga.c):
--     - Reads per-channel IQ data from FPGA over SPI
--     - Computes channel magnitudes using FPU (faster than FPGA LUTs)
--     - Identifies strongest signal (peak channel)
--     - Reconstructs time-domain signal for that channel
--     - Subtracts reconstructed signal from input (interference cancellation)
--     - Repeats for next strongest signal
--
-- This split keeps the FPGA within the ~0.5W power budget for CubeSat
-- deployment while leveraging the STM32H7's FPU for floating-point math.
--
-------------------------------------------------------------------------------
-- SPI PROTOCOL
-------------------------------------------------------------------------------
-- The STM32 is SPI master. The FPGA is SPI slave.
-- SPI Mode 0: CPOL=0 (clock idles low), CPHA=0 (sample on rising edge)
--
-- TRANSACTION STRUCTURE (17 bytes total):
--
--   Byte 0:  Command from STM32 (FPGA responds with 0x00 during this byte)
--   Bytes 1-16: Response data from FPGA (STM32 sends 0x00 during these bytes)
--
-- COMMANDS:
--   0x01 - READ_IQ: Read complex IQ data for all 4 channels
--   0x02 - READ_STATUS: Read FPGA status register
--   Others: NOP (FPGA responds with 0x00)
--
-- READ_IQ RESPONSE FORMAT (16 bytes, big-endian):
--
--   Byte  1: I0[15:8]  - Channel 0, I component, high byte
--   Byte  2: I0[7:0]   - Channel 0, I component, low byte
--   Byte  3: Q0[15:8]  - Channel 0, Q component, high byte
--   Byte  4: Q0[7:0]   - Channel 0, Q component, low byte
--   Byte  5: I1[15:8]  - Channel 1, I component, high byte
--   Byte  6: I1[7:0]   - Channel 1, I component, low byte
--   Byte  7: Q1[15:8]  - Channel 1, Q component, high byte
--   Byte  8: Q1[7:0]   - Channel 1, Q component, low byte
--   Byte  9: I2[15:8]  - Channel 2, I component, high byte
--   Byte 10: I2[7:0]   - Channel 2, I component, low byte
--   Byte 11: Q2[15:8]  - Channel 2, Q component, high byte
--   Byte 12: Q2[7:0]   - Channel 2, Q component, low byte
--   Byte 13: I3[15:8]  - Channel 3, I component, high byte
--   Byte 14: I3[7:0]   - Channel 3, I component, low byte
--   Byte 15: Q3[15:8]  - Channel 3, Q component, high byte
--   Byte 16: Q3[7:0]   - Channel 3, Q component, low byte
--
-- READ_STATUS RESPONSE FORMAT (1 byte):
--   Bit 0: chan_ready  - Channelizer is initialized and running
--   Bit 1: iq_valid    - IQ data has been updated at least once
--   Bits 7:2: reserved (0)
--
-- WHY COMPLEX IQ DATA?
-- --------------------
-- SIC requires time-domain signal reconstruction, which requires both
-- the I (in-phase) and Q (quadrature) components of each channel.
-- Magnitude alone is not sufficient -- you need the full complex sample
-- to reconstruct the waveform and subtract it from the input.
-- This is why the FPGA outputs 4 bytes per channel (2 bytes I + 2 bytes Q)
-- rather than a single magnitude value.
--
-------------------------------------------------------------------------------
-- SPI TIMING DETAILS
-------------------------------------------------------------------------------
-- FPGA clock:    12 MHz (83 ns period)
-- SPI clock:      1 MHz (1 us period) -- 12x oversampling
--
-- All SPI inputs are asynchronous to the FPGA clock. They pass through
-- 2-stage flip-flop synchronizers before use. This prevents metastability
-- when signals cross clock domains. At 12:1 oversampling, the MTBF after
-- synchronization is astronomically high (suitable for space hardware).
--
-- MISO timing:
--   - MISO is driven combinatorially from spi_tx_shift(7)
--   - spi_tx_shift is loaded at reset and at CS assertion
--   - MISO shifts on the falling edge of SCLK (after STM32 samples)
--   - MISO is stable before the first rising edge of SCLK
--
-- MOSI timing:
--   - MOSI is sampled on the rising edge of SCLK (standard Mode 0)
--   - After 2-stage synchronization, sampled by detecting rising edge
--
-------------------------------------------------------------------------------
-- PIN MAPPING
-------------------------------------------------------------------------------
-- See sic_top.pdc for Radiant constraint file.
--
--   Signal        Site  Location        Notes
--   clk_12m        35   J51 (osc)       12 MHz oscillator, J51 jumper required
--   spi_cs_n       16   J52 SS          SPI chip select, active low
--   spi_sclk       15   J52 SCK         SPI clock from STM32
--   spi_mosi       17   J52 MOSI        SPI data STM32 -> FPGA
--   spi_miso       12   J3 pin 22A      SPI data FPGA -> STM32 (NOT J52 MISO)
--   fpga_rst_n     18   J3 pin 18A      Active-low reset from STM32
--   fpga_done      19   J3 pin 29B      High when channelizer ready
--   led_red        39   RGB LED         Heartbeat (~0.7 Hz)
--   led_green      40   RGB LED         chan_ready
--   led_blue       41   RGB LED         iq_valid
--
-- IMPORTANT: spi_miso is on J3 pin 22A, NOT on J52 pin labeled "MISO".
-- J52 pin 14 (IOB_32A_SPI_SO) is the dedicated hardware SPI slave output
-- and does not function as a general-purpose GPIO output in Radiant.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library iCE40UP;
use iCE40UP.components.all;

entity sic_top_ice40 is
    port (
        ------------------------------------------------------------------------
        -- Clock
        ------------------------------------------------------------------------
        clk_12m         : in  std_logic;    -- 12 MHz oscillator (site 35)

        ------------------------------------------------------------------------
        -- SPI Slave Interface
        -- Connected to STM32H7 SPI4 peripheral (PE11-PE14)
        ------------------------------------------------------------------------
        spi_cs_n        : in  std_logic;    -- Chip select, active low (site 16)
        spi_sclk        : in  std_logic;    -- SPI clock from STM32 (site 15)
        spi_mosi        : in  std_logic;    -- Data from STM32 to FPGA (site 17)
        spi_miso        : out std_logic;    -- Data from FPGA to STM32 (site 12)

        ------------------------------------------------------------------------
        -- Control Signals
        ------------------------------------------------------------------------
        fpga_rst_n      : in  std_logic;    -- Active-low reset from STM32 (site 18)
        fpga_done       : out std_logic;    -- High when channelizer ready (site 19)

        ------------------------------------------------------------------------
        -- I2S ADC Input
        -- TLV320ADC6120 audio ADC (Martin's hardware)
        -- Currently replaced by test pattern generator for bringup
        ------------------------------------------------------------------------
        adc_i2s_bclk    : in  std_logic;    -- I2S bit clock
        adc_i2s_ws      : in  std_logic;    -- I2S word select (L/R)
        adc_i2s_data    : in  std_logic;    -- I2S serial data

        ------------------------------------------------------------------------
        -- I2S DAC Output (loopback for testing)
        ------------------------------------------------------------------------
        dac_i2s_bclk    : out std_logic;
        dac_i2s_ws      : out std_logic;
        dac_i2s_data    : out std_logic;

        ------------------------------------------------------------------------
        -- RGB LED Status Outputs
        -- iCE40UP5K pins 39/40/41 require the RGB primitive (not plain GPIO)
        ------------------------------------------------------------------------
        led_red         : out std_logic;    -- Heartbeat (site 39)
        led_green       : out std_logic;    -- chan_ready (site 40)
        led_blue        : out std_logic;    -- iq_valid (site 41)

        ------------------------------------------------------------------------
        -- Debug PMOD Header (U6)
        -- Useful for scope probing during bringup
        ------------------------------------------------------------------------
        pmod_1          : out std_logic;    -- chan_valid (site 43)
        pmod_2          : out std_logic;    -- iq_valid (site 38)
        pmod_3          : out std_logic;    -- cs_n_sync2 (site 34)
        pmod_4          : out std_logic     -- sclk_sync2 (site 37)
    );
end entity sic_top_ice40;

architecture rtl of sic_top_ice40 is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant N_CHANNELS      : positive := 4;
    constant TAPS_PER_BRANCH : positive := 16;
    constant DATA_WIDTH      : positive := 16;
    constant COEFF_WIDTH     : positive := 16;
    constant ACCUM_WIDTH     : positive := 36;

    -- SPI command bytes (must match sic_fpga.h on STM32)
    constant CMD_NOP         : std_logic_vector(7 downto 0) := x"00";
    constant CMD_READ_IQ     : std_logic_vector(7 downto 0) := x"01";
    constant CMD_READ_STATUS : std_logic_vector(7 downto 0) := x"02";

    -- Total bytes per READ_IQ transaction:
    -- 1 command byte + 4 channels * (2 bytes I + 2 bytes Q) = 17 bytes
    constant IQ_BYTES        : positive := 16;
    constant TOTAL_BYTES     : positive := 17;

    ---------------------------------------------------------------------------
    -- Clocks and Reset
    ---------------------------------------------------------------------------
    signal clk_sys          : std_logic;
    signal reset            : std_logic;
    -- Reset synchronizer: initializes to '1' (in reset), shifts in '0'
    -- After 3 rising edges, reset goes low and normal operation begins
    signal reset_sync       : std_logic_vector(2 downto 0) := (others => '1');

    ---------------------------------------------------------------------------
    -- I2S / ADC Signals
    ---------------------------------------------------------------------------
    signal i2s_sample_re    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_sample_im    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_sample_valid : std_logic;

    ---------------------------------------------------------------------------
    -- Polyphase Channelizer Signals
    ---------------------------------------------------------------------------
    signal chan_out         : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal chan_valid       : std_logic;
    signal chan_ready       : std_logic;

    ---------------------------------------------------------------------------
    -- Channel IQ Data
    -- Extracted from channelizer output and held for SPI readout.
    -- Updated whenever the channelizer produces new output (chan_valid).
    -- The SPI interface reads from these latched registers asynchronously
    -- (from the channelizer's perspective).
    --
    -- WHY LATCH? The SPI transfer takes ~17 us at 1 MHz. The channelizer
    -- produces new data every ~25 us (40 kHz / 4 channels). Latching
    -- prevents the data from changing mid-transfer.
    ---------------------------------------------------------------------------
    type iq_array_t is array (0 to N_CHANNELS - 1) of signed(DATA_WIDTH - 1 downto 0);
    signal channel_i        : iq_array_t;  -- I (real) component per channel
    signal channel_q        : iq_array_t;  -- Q (imaginary) component per channel
    signal iq_valid         : std_logic;   -- At least one valid IQ update received

    ---------------------------------------------------------------------------
    -- SPI Input Synchronizers
    -- -------------------------
    -- All three SPI inputs are asynchronous to clk_sys. Without synchronizers,
    -- a rising edge on spi_sclk could cause a flip-flop in the FPGA to
    -- enter a metastable state, producing unpredictable output for an
    -- indeterminate period. In the worst case this causes bit errors.
    --
    -- The 2-stage synchronizer works by passing the signal through two
    -- flip-flops in series, both clocked by clk_sys:
    --
    --   spi_sclk --> [FF1] --> sclk_sync1 --> [FF2] --> sclk_sync2
    --
    -- If FF1 goes metastable, it has one full clk_sys period (83 ns at
    -- 12 MHz) to resolve before FF2 samples it. The probability of FF2
    -- also going metastable is negligibly small.
    --
    -- At 12 MHz FPGA / 1 MHz SPI = 12x oversampling, this design is
    -- appropriate for space hardware. It remains correct when the SPI
    -- clock is increased, provided the oversampling ratio stays >= 2x.
    ---------------------------------------------------------------------------
    signal sclk_sync1       : std_logic := '0';
    signal sclk_sync2       : std_logic := '0';
    signal cs_n_sync1       : std_logic := '1';  -- Init high (CS deasserted)
    signal cs_n_sync2       : std_logic := '1';
    signal mosi_sync1       : std_logic := '0';
    signal mosi_sync2       : std_logic := '0';

    ---------------------------------------------------------------------------
    -- SPI State Machine
    ---------------------------------------------------------------------------
    type spi_state_t is (IDLE, CMD, SEND_IQ, SEND_STATUS);
    signal spi_state        : spi_state_t := IDLE;

    -- Transmit shift register: MSB drives MISO combinatorially.
    -- Shifts left on each falling SCLK edge.
    signal spi_tx_shift     : std_logic_vector(7 downto 0) := (others => '0');

    -- Receive shift register: MOSI shifts in on each rising SCLK edge.
    -- After 8 bits, contents are captured as the received byte.
    signal spi_rx_shift     : std_logic_vector(7 downto 0) := (others => '0');

    -- Captured command byte from STM32
    signal spi_cmd          : std_logic_vector(7 downto 0) := (others => '0');

    -- Bit counter: 0-7 within each byte
    signal spi_bit_cnt      : unsigned(2 downto 0) := (others => '0');

    -- Byte counter: which IQ byte we are currently sending (0-15)
    signal spi_byte_cnt     : unsigned(4 downto 0) := (others => '0');

    -- Previous synchronized SCLK value, used for edge detection
    signal sclk_prev        : std_logic := '0';

    -- Single-cycle edge strobes derived from sclk_sync2 vs sclk_prev
    signal sclk_rising      : std_logic;
    signal sclk_falling     : std_logic;

    ---------------------------------------------------------------------------
    -- IQ Transmit Buffer
    -- ------------------
    -- Flat byte array holding all 16 IQ bytes ready to shift out.
    -- Combinatorially populated from channel_i/channel_q.
    -- Indexed by spi_byte_cnt during SEND_IQ state.
    --
    -- Layout (big-endian, matches sic_fpga.c parser on STM32):
    --   Index 0,1:   I0 high byte, I0 low byte
    --   Index 2,3:   Q0 high byte, Q0 low byte
    --   Index 4,5:   I1 high byte, I1 low byte
    --   Index 6,7:   Q1 high byte, Q1 low byte
    --   Index 8,9:   I2 high byte, I2 low byte
    --   Index 10,11: Q2 high byte, Q2 low byte
    --   Index 12,13: I3 high byte, I3 low byte
    --   Index 14,15: Q3 high byte, Q3 low byte
    ---------------------------------------------------------------------------
    type iq_buf_t is array (0 to IQ_BYTES - 1) of std_logic_vector(7 downto 0);
    signal iq_buf           : iq_buf_t;

    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    signal status_reg       : std_logic_vector(7 downto 0);

    ---------------------------------------------------------------------------
    -- LED Heartbeat Counter
    ---------------------------------------------------------------------------
    signal heartbeat_cnt    : unsigned(23 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Keep attribute prevents synthesis optimizing away the RGB primitive
    ---------------------------------------------------------------------------
    attribute syn_keep : boolean;
    attribute syn_keep of u_rgb_drv : label is true;

begin

    ---------------------------------------------------------------------------
    -- Clock Assignment
    -- Using 12 MHz oscillator directly.
    -- A PLL (SB_PLL40_CORE) can be added here for higher SPI speeds.
    ---------------------------------------------------------------------------
    clk_sys <= clk_12m;

    ---------------------------------------------------------------------------
    -- Reset Synchronizer
    -- Produces a synchronous reset pulse at power-up.
    -- reset_sync(2) is high for 3 clk_sys cycles, then goes low permanently.
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            reset_sync <= reset_sync(1 downto 0) & '0';
        end if;
    end process;
    reset <= reset_sync(2);

    ---------------------------------------------------------------------------
    -- Heartbeat Counter
    -- 24-bit free-running counter. Bit 23 toggles at ~0.7 Hz (12 MHz / 2^24)
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            heartbeat_cnt <= heartbeat_cnt + 1;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- SPI Input Synchronizers
    -- All three SPI inputs synchronized to clk_sys before use in any logic.
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            sclk_sync1 <= spi_sclk;
            sclk_sync2 <= sclk_sync1;
            cs_n_sync1 <= spi_cs_n;
            cs_n_sync2 <= cs_n_sync1;
            mosi_sync1 <= spi_mosi;
            mosi_sync2 <= mosi_sync1;
        end if;
    end process;

    -- SCLK edge detection: single clk_sys cycle wide strobes
    sclk_rising  <= '1' when sclk_sync2 = '1' and sclk_prev = '0' else '0';
    sclk_falling <= '1' when sclk_sync2 = '0' and sclk_prev = '1' else '0';

    ---------------------------------------------------------------------------
    -- I2S / ADC Input (Test Pattern Generator)
    -- -----------------------------------------
    -- For hardware bringup, real I2S ADC input is replaced by a test pattern:
    --   I (real) = incrementing 16-bit counter
    --   Q (imag) = bitwise inverse of counter
    --
    -- This produces a complex ramp. When processed by the polyphase
    -- channelizer, energy appears across all channels in a predictable
    -- pattern useful for verifying correct channel separation.
    --
    -- TODO: Replace with real I2S receiver for production use.
    ---------------------------------------------------------------------------
    process(clk_sys)
        variable sample_cnt : unsigned(DATA_WIDTH - 1 downto 0) := (others => '0');
        variable div_cnt    : unsigned(9 downto 0) := (others => '0');
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                sample_cnt       := (others => '0');
                div_cnt          := (others => '0');
                i2s_sample_valid <= '0';
            else
                i2s_sample_valid <= '0';
                -- Divide 12 MHz by 300 -> ~40 kHz sample rate
                if div_cnt = 299 then
                    div_cnt          := (others => '0');
                    i2s_sample_valid <= '1';
                    i2s_sample_re    <= std_logic_vector(sample_cnt);
                    i2s_sample_im    <= std_logic_vector(not sample_cnt);
                    sample_cnt       := sample_cnt + 1;
                else
                    div_cnt := div_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Polyphase Channelizer
    ---------------------------------------------------------------------------
    u_channelizer : entity work.polyphase_channelizer_top
        generic map (
            N_CHANNELS      => N_CHANNELS,
            TAPS_PER_BRANCH => TAPS_PER_BRANCH,
            DATA_WIDTH      => DATA_WIDTH,
            COEFF_WIDTH     => COEFF_WIDTH,
            ACCUM_WIDTH     => ACCUM_WIDTH,
            COEFF_FILE      => "../../rtl/coeffs/mdt_coeffs.hex"
        )
        port map (
            clk           => clk_sys,
            reset         => reset,
            sample_re     => i2s_sample_re,
            sample_im     => i2s_sample_im,
            sample_valid  => i2s_sample_valid,
            channel_out   => chan_out,
            channel_valid => chan_valid,
            ready         => chan_ready
        );

    ---------------------------------------------------------------------------
    -- IQ Data Extraction and Latching
    -- --------------------------------
    -- Extract upper 16 bits of each 36-bit channelizer accumulator output.
    -- Latch into channel_i/channel_q on each chan_valid pulse.
    -- The SPI interface reads from these latched values.
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                iq_valid <= '0';
                for i in 0 to N_CHANNELS - 1 loop
                    channel_i(i) <= (others => '0');
                    channel_q(i) <= (others => '0');
                end loop;
            elsif chan_valid = '1' then
                iq_valid <= '1';
                for i in 0 to N_CHANNELS - 1 loop
                    channel_i(i) <= signed(chan_out(
                        (i * 2 + 1) * ACCUM_WIDTH - 1 downto
                        (i * 2 + 1) * ACCUM_WIDTH - DATA_WIDTH));
                    channel_q(i) <= signed(chan_out(
                        (i * 2 + 2) * ACCUM_WIDTH - 1 downto
                        (i * 2 + 2) * ACCUM_WIDTH - DATA_WIDTH));
                end loop;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- IQ Transmit Buffer Population
    -- --------------------------------
    -- Pack channel_i/channel_q into flat byte array for SPI readout.
    -- Combinatorial assignment, always reflects current latched IQ values.
    -- Big-endian byte order, I before Q, matching sic_fpga.c on STM32.
    ---------------------------------------------------------------------------
    process(channel_i, channel_q)
    begin
        for i in 0 to N_CHANNELS - 1 loop
            iq_buf(i * 4 + 0) <= std_logic_vector(channel_i(i)(DATA_WIDTH - 1 downto 8));
            iq_buf(i * 4 + 1) <= std_logic_vector(channel_i(i)(7 downto 0));
            iq_buf(i * 4 + 2) <= std_logic_vector(channel_q(i)(DATA_WIDTH - 1 downto 8));
            iq_buf(i * 4 + 3) <= std_logic_vector(channel_q(i)(7 downto 0));
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- SPI Slave State Machine
    -- -----------------------
    -- Synchronous SPI Mode 0 slave using synchronized SPI inputs.
    --
    -- KEY DESIGN DECISIONS:
    --
    -- 1. All SPI inputs use synchronized versions (sclk_sync2, cs_n_sync2,
    --    mosi_sync2) to prevent metastability. Raw port signals are never
    --    used directly in logic.
    --
    -- 2. Edge detection via sclk_prev register (registered, not combinatorial).
    --    Combinatorial edge detection creates glitches. Registered detection
    --    (comparing current vs previous clk_sys sample) is clean and safe.
    --
    -- 3. MISO driven from spi_tx_shift(7) combinatorially (outside process).
    --    This ensures MISO is valid as soon as spi_tx_shift is loaded, with
    --    no additional clock latency. MISO is stable before the first SCLK
    --    rising edge, satisfying setup time requirements.
    --
    -- 4. MISO shifts on FALLING SCLK edge (after STM32 samples on rising).
    --    This is standard SPI Mode 0. The master samples on rising, slave
    --    changes on falling, giving a full half-period of hold time.
    --
    -- 5. MOSI sampled on RISING SCLK edge (after 2-stage synchronization).
    --    Standard Mode 0: master presents MOSI before rising edge.
    --
    -- 6. CS deassert returns to IDLE and clears all state.
    --    sclk_prev reset to '0' matching CPOL=0 idle state.
    --    This prevents false edge detection at the start of the next transfer.
    --
    -- STATE TRANSITIONS:
    --
    --   Power-up/reset -> IDLE
    --
    --   IDLE:
    --     CS asserts -> CMD, load 0x00 into tx_shift (no data during cmd byte)
    --
    --   CMD: (receiving command byte from STM32)
    --     Rising SCLK: shift MOSI into rx_shift
    --     Falling SCLK: shift tx_shift (sending 0x00)
    --     After 8 bits: decode command
    --       CMD_READ_IQ     -> SEND_IQ,     load iq_buf(0) into tx_shift
    --       CMD_READ_STATUS -> SEND_STATUS, load status_reg into tx_shift
    --       Other           -> IDLE (NOP)
    --
    --   SEND_IQ: (sending 16 IQ bytes)
    --     Falling SCLK: shift tx_shift
    --     After 8 bits: load next byte from iq_buf, increment byte counter
    --     After byte 15: -> IDLE
    --
    --   SEND_STATUS: (sending 1 status byte)
    --     After 8 bits: -> IDLE
    --
    --   Any state: CS deasserts -> IDLE
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then

            -- Always update sclk_prev for edge detection
            sclk_prev <= sclk_sync2;

            if reset = '1' then
                spi_state    <= IDLE;
                spi_tx_shift <= (others => '0');
                spi_rx_shift <= (others => '0');
                spi_bit_cnt  <= (others => '0');
                spi_byte_cnt <= (others => '0');
                spi_cmd      <= (others => '0');
                sclk_prev    <= '0';

            elsif cs_n_sync2 = '1' then
                -- CS deasserted: reset all state, ready for next transaction
                spi_state    <= IDLE;
                spi_tx_shift <= (others => '0');
                spi_rx_shift <= (others => '0');
                spi_bit_cnt  <= (others => '0');
                spi_byte_cnt <= (others => '0');
                sclk_prev    <= '0';  -- Match CPOL=0 idle (prevents false edge)

            else
                -- CS asserted: process SPI clock edges

                -- Transition from IDLE to CMD on CS assertion
                if spi_state = IDLE then
                    spi_state    <= CMD;
                    spi_tx_shift <= (others => '0');  -- 0x00 during command byte
                    spi_bit_cnt  <= (others => '0');
                    spi_byte_cnt <= (others => '0');
                end if;

                -- RISING EDGE: sample MOSI
                -- STM32 presents MOSI stable before rising edge (Mode 0)
                if sclk_rising = '1' then
                    spi_rx_shift <= spi_rx_shift(6 downto 0) & mosi_sync2;
                end if;

                -- FALLING EDGE: shift MISO, handle byte boundaries
                if sclk_falling = '1' then

                    -- Shift transmit register: MSB goes out on MISO
                    spi_tx_shift <= spi_tx_shift(6 downto 0) & '0';
                    spi_bit_cnt  <= spi_bit_cnt + 1;

                    -- After 8 bits, a full byte has been exchanged
                    if spi_bit_cnt = 7 then

                        spi_bit_cnt <= (others => '0');

                        case spi_state is

                            when IDLE =>
                                -- Should not occur (handled above), but safe fallback
                                null;

                            when CMD =>
                                -- Full command byte received in rx_shift
                                -- (last bit was just shifted in on the rising edge
                                --  immediately before this falling edge)
                                spi_cmd <= spi_rx_shift;

                                if spi_rx_shift = CMD_READ_IQ then
                                    -- Start sending IQ data
                                    -- Load first byte now so MISO is valid
                                    -- before next rising edge
                                    spi_state    <= SEND_IQ;
                                    spi_byte_cnt <= (others => '0');
                                    spi_tx_shift <= iq_buf(0);

                                elsif spi_rx_shift = CMD_READ_STATUS then
                                    spi_state    <= SEND_STATUS;
                                    spi_tx_shift <= status_reg;

                                else
                                    -- NOP or unknown command
                                    spi_state    <= IDLE;
                                    spi_tx_shift <= (others => '0');
                                end if;

                            when SEND_IQ =>
                                -- Finished sending current IQ byte
                                if spi_byte_cnt = IQ_BYTES - 1 then
                                    -- All 16 bytes sent
                                    spi_state    <= IDLE;
                                    spi_tx_shift <= (others => '0');
                                else
                                    -- Load next IQ byte
                                    spi_byte_cnt <= spi_byte_cnt + 1;
                                    spi_tx_shift <= iq_buf(
                                        to_integer(spi_byte_cnt) + 1);
                                end if;

                            when SEND_STATUS =>
                                -- Status byte sent
                                spi_state    <= IDLE;
                                spi_tx_shift <= (others => '0');

                        end case;
                    end if; -- spi_bit_cnt = 7

                end if; -- sclk_falling

            end if; -- cs_n_sync2
        end if; -- rising_edge
    end process;

    ---------------------------------------------------------------------------
    -- MISO Output
    -- Combinatorial assignment from MSB of transmit shift register.
    -- MISO is valid immediately when spi_tx_shift is loaded, well before
    -- the first SCLK rising edge.
    ---------------------------------------------------------------------------
    spi_miso <= spi_tx_shift(7);

    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    status_reg(0)          <= chan_ready;
    status_reg(1)          <= iq_valid;
    status_reg(7 downto 2) <= (others => '0');

    ---------------------------------------------------------------------------
    -- RGB LED Driver
    -- iCE40UP5K requires the RGB primitive for pins 39/40/41.
    -- Direct GPIO assignment does not work for these pins.
    ---------------------------------------------------------------------------
    u_rgb_drv : RGB
        generic map (
            CURRENT_MODE => "0",
            RGB0_CURRENT => "0b000001",
            RGB1_CURRENT => "0b000001",
            RGB2_CURRENT => "0b000001"
        )
        port map (
            CURREN   => '1',
            RGBLEDEN => '1',
            RGB0PWM  => heartbeat_cnt(23),  -- Red:   ~0.7 Hz blink (FPGA alive)
            RGB1PWM  => chan_ready,          -- Green: channelizer ready
            RGB2PWM  => iq_valid,            -- Blue:  IQ data valid
            RGB0     => led_red,
            RGB1     => led_green,
            RGB2     => led_blue
        );

    ---------------------------------------------------------------------------
    -- FPGA Done
    -- Goes high when channelizer is initialized and producing data.
    -- STM32 polls this via fpga_done GPIO to detect FPGA boot completion.
    ---------------------------------------------------------------------------
    fpga_done <= chan_ready;

    ---------------------------------------------------------------------------
    -- DAC I2S Loopback
    ---------------------------------------------------------------------------
    dac_i2s_bclk <= adc_i2s_bclk;
    dac_i2s_ws   <= adc_i2s_ws;
    dac_i2s_data <= adc_i2s_data;

    ---------------------------------------------------------------------------
    -- Debug PMOD
    -- Synchronized SPI signals for accurate scope measurements
    ---------------------------------------------------------------------------
    pmod_1 <= chan_valid;
    pmod_2 <= iq_valid;
    pmod_3 <= cs_n_sync2;
    pmod_4 <= sclk_sync2;

end architecture rtl;
