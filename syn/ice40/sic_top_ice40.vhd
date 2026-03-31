-------------------------------------------------------------------------------
-- sic_top_ice40.vhd
-- Top-Level SIC Receiver for iCE40UP5K-B-EVN
-------------------------------------------------------------------------------
-- Open Research Institute
-- Project: Polyphase Channelizer (MDT SIC Receiver)
-- Target: Lattice iCE40UP5K-B-EVN + STM32H7B3ZI-Q Nucleo
--
-------------------------------------------------------------------------------
-- OVERVIEW
-------------------------------------------------------------------------------
-- This is the iCE40-specific top level that wraps the polyphase channelizer
-- with:
--   1. SPI slave interface to STM32 (for data output and control)
--   2. I2S receiver for ADC input (audio/IQ samples)
--   3. PLL for clock generation from 12 MHz input
--   4. Status LEDs
--
-- The SPI interface streams complex I/Q channel data to the STM32 for
-- magnitude computation and signal detection (SIC algorithm runs on MCU).
--
-------------------------------------------------------------------------------
-- SPI PROTOCOL
-------------------------------------------------------------------------------
-- Simple streaming protocol:
--
--   Command byte (from STM32):
--     0x00 - NOP
--     0x01 - Read channel I/Q data (4 channels x 4 bytes = 16 bytes)
--     0x02 - Read status register
--     0x10 - Write config register
--     0x80 - Reset
--
--   Response (to STM32):
--     After cmd 0x01: [I0_H][I0_L][Q0_H][Q0_L][I1_H][I1_L][Q1_H][Q1_L]...
--     After cmd 0x02: [status_byte]
--
--   Each channel sends 16-bit signed I followed by 16-bit signed Q.
--   Magnitude computation is done on the STM32 (FPU is faster than FPGA LUTs).
--
-------------------------------------------------------------------------------
-- SPI TIMING
-------------------------------------------------------------------------------
-- SPI Mode 0: CPOL=0 (idle low), CPHA=0 (sample on rising edge)
-- FPGA shifts MISO on falling edge of SCLK
-- STM32 samples MISO on rising edge of SCLK
--
-- All SPI input signals (spi_sclk, spi_cs_n, spi_mosi) pass through a
-- 2-stage synchronizer before use. This prevents metastability when
-- asynchronous inputs cross into the 12 MHz clk_sys domain.
-- At 12 MHz FPGA clock / 1 MHz SPI clock = 12x oversampling, well above
-- the minimum 2x required for reliable synchronization.
--
-------------------------------------------------------------------------------
-- PIN MAPPING (see sic_top.pdc)
-------------------------------------------------------------------------------
--   clk_12m      - 12 MHz oscillator input (site 35)
--   spi_cs_n     - SPI chip select, active low (site 16, J52 SS)
--   spi_sclk     - SPI clock from STM32 (site 15, J52 SCK)
--   spi_mosi     - SPI data STM32->FPGA (site 17, J52 MOSI)
--   spi_miso     - SPI data FPGA->STM32 (site 12, J3 pin 22A)
--   fpga_rst_n   - Active-low reset from STM32 (site 18, J3 pin 18A)
--   fpga_done    - Configuration done signal (site 19, J3 pin 29B)
--   led_*        - RGB LED outputs (sites 39/40/41)
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
        clk_12m         : in  std_logic;
        
        ------------------------------------------------------------------------
        -- SPI Slave Interface (matches Martin's signals)
        ------------------------------------------------------------------------
        spi_cs_n        : in  std_logic;    -- FPGA_~{CS}
        spi_sclk        : in  std_logic;    -- FPGA_SCLK
        spi_mosi        : in  std_logic;    -- FPGA_MOSI
        spi_miso        : out std_logic;    -- FPGA_MISO
        
        ------------------------------------------------------------------------
        -- Control (matches Martin's signals)
        ------------------------------------------------------------------------
        fpga_rst_n      : in  std_logic;    -- FPGA_~{RST}
        fpga_done       : out std_logic;    -- FPGA_DONE
        
        ------------------------------------------------------------------------
        -- I2S ADC Input (matches Martin's signals)
        ------------------------------------------------------------------------
        adc_i2s_bclk    : in  std_logic;    -- ADC_I2S_CLK
        adc_i2s_ws      : in  std_logic;    -- ADC_I2S_WS
        adc_i2s_data    : in  std_logic;    -- ADC_I2S_DATA
        
        ------------------------------------------------------------------------
        -- I2S DAC Output (matches Martin's signals)
        ------------------------------------------------------------------------
        dac_i2s_bclk    : out std_logic;    -- DAC_I2S_CLK
        dac_i2s_ws      : out std_logic;    -- DAC_I2S_WS
        dac_i2s_data    : out std_logic;    -- DAC_I2S_DATA
        
        ------------------------------------------------------------------------
        -- RGB LED outputs (directly to pins 39/40/41)
        ------------------------------------------------------------------------
        led_red         : out std_logic;
        led_green       : out std_logic;
        led_blue        : out std_logic;
        
        ------------------------------------------------------------------------
        -- Debug PMOD (optional)
        ------------------------------------------------------------------------
        pmod_1          : out std_logic;
        pmod_2          : out std_logic;
        pmod_3          : out std_logic;
        pmod_4          : out std_logic
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
    
    ---------------------------------------------------------------------------
    -- Clocks and Reset
    ---------------------------------------------------------------------------
    signal clk_sys          : std_logic;
    signal reset            : std_logic;
    signal reset_sync       : std_logic_vector(2 downto 0) := (others => '1');
    
    ---------------------------------------------------------------------------
    -- I2S Receiver Signals
    ---------------------------------------------------------------------------
    signal i2s_sample_re    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_sample_im    : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_sample_valid : std_logic;
    
    ---------------------------------------------------------------------------
    -- Channelizer Signals
    ---------------------------------------------------------------------------
    signal chan_out         : std_logic_vector(N_CHANNELS * 2 * ACCUM_WIDTH - 1 downto 0);
    signal chan_valid       : std_logic;
    signal chan_ready       : std_logic;
    
    ---------------------------------------------------------------------------
    -- Channel I/Q Data (extracted from channelizer output)
    ---------------------------------------------------------------------------
    type iq_array_t is array (0 to N_CHANNELS - 1) of signed(15 downto 0);
    signal channel_i        : iq_array_t;
    signal channel_q        : iq_array_t;
    signal iq_valid         : std_logic;
    
    ---------------------------------------------------------------------------
    -- SPI Input Synchronizers
    -- 2-stage synchronizers prevent metastability on asynchronous SPI inputs.
    -- All SPI logic uses the _sync signals, never the raw port signals.
    ---------------------------------------------------------------------------
    signal sclk_sync1       : std_logic := '0';
    signal sclk_sync2       : std_logic := '0';
    signal cs_n_sync1       : std_logic := '1';
    signal cs_n_sync2       : std_logic := '1';
    signal mosi_sync1       : std_logic := '0';
    signal mosi_sync2       : std_logic := '0';

    ---------------------------------------------------------------------------
    -- SPI Slave Signals
    ---------------------------------------------------------------------------
    -- SPI state machine (for full I/Q protocol - currently simplified test)
    type spi_state_t is (IDLE, SEND_IQ, SEND_STATUS);
    signal spi_state        : spi_state_t := IDLE;
    signal spi_byte_cnt     : unsigned(4 downto 0) := (others => '0');

    -- SPI shift registers
    signal sclk_prev        : std_logic := '0';
    signal spi_bit_cnt      : unsigned(2 downto 0) := (others => '0');
    signal spi_rx_shift     : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_tx_shift     : std_logic_vector(7 downto 0) := (others => '0');

    -- Unused SPI signals (retained for future full protocol)
    signal spi_rx_data      : std_logic_vector(7 downto 0);
    signal spi_rx_valid     : std_logic;
    signal spi_tx_data      : std_logic_vector(7 downto 0);
    signal spi_tx_load      : std_logic;
    signal spi_byte_cnt_rx  : unsigned(4 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    signal status_reg       : std_logic_vector(7 downto 0);
    
    ---------------------------------------------------------------------------
    -- LED Heartbeat
    ---------------------------------------------------------------------------
    signal heartbeat_cnt    : unsigned(23 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Keep attribute for RGB driver primitive
    ---------------------------------------------------------------------------
    attribute syn_keep : boolean;
    attribute syn_keep of u_rgb_drv : label is true;

begin

    ---------------------------------------------------------------------------
    -- Clock: Use 12 MHz directly
    -- For higher performance, instantiate SB_PLL40_CORE
    ---------------------------------------------------------------------------
    clk_sys <= clk_12m;

    ---------------------------------------------------------------------------
    -- Reset Synchronizer
    -- Initializes to '1' (in reset), shifts in '0' after 3 cycles
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
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            heartbeat_cnt <= heartbeat_cnt + 1;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- SPI Input Synchronizers
    -- 2-stage flip-flop synchronizers for all asynchronous SPI inputs.
    -- Prevents metastability from async signals entering the clk_sys domain.
    -- At 12 MHz / 1 MHz = 12x oversampling, MTBF is extremely high.
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            -- SCLK synchronizer
            sclk_sync1 <= spi_sclk;
            sclk_sync2 <= sclk_sync1;
            -- CS_N synchronizer
            cs_n_sync1 <= spi_cs_n;
            cs_n_sync2 <= cs_n_sync1;
            -- MOSI synchronizer
            mosi_sync1 <= spi_mosi;
            mosi_sync2 <= mosi_sync1;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- I2S Receiver (test pattern generator for bring-up)
    -- Generates a complex ramp: re = incrementing counter, im = inverted
    -- Replace with real I2S receiver for production use
    ---------------------------------------------------------------------------
    process(clk_sys)
        variable sample_cnt : unsigned(15 downto 0) := (others => '0');
        variable div_cnt    : unsigned(9 downto 0) := (others => '0');
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                sample_cnt := (others => '0');
                div_cnt := (others => '0');
                i2s_sample_valid <= '0';
            else
                i2s_sample_valid <= '0';
                -- Generate sample at ~40 kHz from 12 MHz clock (div by 300)
                if div_cnt = 299 then
                    div_cnt := (others => '0');
                    i2s_sample_valid <= '1';
                    i2s_sample_re <= std_logic_vector(sample_cnt);
                    i2s_sample_im <= std_logic_vector(not sample_cnt);
                    sample_cnt := sample_cnt + 1;
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
    -- Extract I/Q from Channelizer Output
    -- Upper 16 bits of each 36-bit accumulator output
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            iq_valid <= chan_valid;
            if chan_valid = '1' then
                for i in 0 to N_CHANNELS - 1 loop
                    channel_i(i) <= signed(chan_out((i * 2 + 1) * ACCUM_WIDTH - 1
                                                downto (i * 2 + 1) * ACCUM_WIDTH - 16));
                    channel_q(i) <= signed(chan_out((i * 2 + 2) * ACCUM_WIDTH - 1
                                                downto (i * 2 + 2) * ACCUM_WIDTH - 16));
                end loop;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- SPI Slave - Simplified Test Pattern
    --
    -- Sends 0xA5 for every byte of every transfer.
    -- Uses synchronized SPI inputs (sclk_sync2, cs_n_sync2, mosi_sync2).
    --
    -- SPI Mode 0: CPOL=0 (SCLK idle low), CPHA=0 (sample on rising edge)
    -- MISO shifts out on falling edge of SCLK (changes after STM32 samples)
    -- MISO is driven combinatorially from spi_tx_shift(7)
    --
    -- TODO: Replace with full I/Q protocol once test pattern verified clean
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                -- Synchronous reset: load test pattern, clear state
                spi_tx_shift <= x"A5";
                spi_bit_cnt  <= (others => '0');
                sclk_prev    <= '0';
            elsif cs_n_sync2 = '1' then
                -- CS deasserted: reload test pattern for next transfer
                spi_tx_shift <= x"A5";
                spi_bit_cnt  <= (others => '0');
                sclk_prev    <= '0';  -- Reset to SCLK idle state (CPOL=0)
            else
                -- CS asserted: shift on falling edge of SCLK
                if sclk_sync2 = '0' and sclk_prev = '1' then
                    spi_tx_shift <= spi_tx_shift(6 downto 0) & '1';
                    spi_bit_cnt  <= spi_bit_cnt + 1;
                    -- After 8 bits, reload 0xA5 for next byte
                    -- Note: this assignment overrides the shift above (VHDL
                    -- last-assignment-wins in synchronous process)
                    if spi_bit_cnt = 7 then
                        spi_tx_shift <= x"A5";
                        spi_bit_cnt  <= (others => '0');
                    end if;
                end if;
                sclk_prev <= sclk_sync2;
            end if;
        end if;
    end process;

    -- MISO driven combinatorially from MSB of shift register
    -- Valid before first SCLK rising edge (0xA5 bit 7 = '1')
    spi_miso <= spi_tx_shift(7);

    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    status_reg(0) <= chan_ready;
    status_reg(1) <= iq_valid;
    status_reg(7 downto 2) <= (others => '0');
    
    ---------------------------------------------------------------------------
    -- RGB LED Driver (required for iCE40UP5K pins 39/40/41)
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
            RGB0PWM  => heartbeat_cnt(23),
            RGB1PWM  => chan_ready,
            RGB2PWM  => iq_valid,
            RGB0     => led_red,
            RGB1     => led_green,
            RGB2     => led_blue
        );
    
    ---------------------------------------------------------------------------
    -- FPGA Done
    ---------------------------------------------------------------------------
    fpga_done <= chan_ready;
    
    ---------------------------------------------------------------------------
    -- DAC I2S (loopback for testing)
    ---------------------------------------------------------------------------
    dac_i2s_bclk <= adc_i2s_bclk;
    dac_i2s_ws   <= adc_i2s_ws;
    dac_i2s_data <= adc_i2s_data;
    
    ---------------------------------------------------------------------------
    -- Debug PMOD
    ---------------------------------------------------------------------------
    pmod_1 <= chan_valid;
    pmod_2 <= iq_valid;
    pmod_3 <= cs_n_sync2;   -- Synchronized CS for debug
    pmod_4 <= sclk_sync2;   -- Synchronized SCLK for debug

end architecture rtl;