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
--     0x01 - Read channel I/Q data (4 channels Ã— 4 bytes = 16 bytes)
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
-- PIN MAPPING (see sic_top.pcf)
-------------------------------------------------------------------------------
--   clk_12m      - 12 MHz oscillator input
--   spi_*        - SPI interface to STM32
--   adc_i2s_*    - I2S ADC input
--   led_*        - Status LEDs
--   fpga_rst_n   - Active-low reset from STM32
--   fpga_done    - Configuration done signal
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
    signal counter : unsigned(23 downto 0) := (others => '0');
begin

    process(clk_12m)
    begin
        if rising_edge(clk_12m) then
            counter <= counter + 1;
        end if;
    end process;

    -- RGB LED
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
            RGB0PWM  => counter(23),
            RGB1PWM  => counter(22),
            RGB2PWM  => counter(21),
            RGB0     => led_red,
            RGB1     => led_green,
            RGB2     => led_blue
        );

    -- Tie off unused outputs
    spi_miso     <= '0';
    fpga_done    <= '1';
    dac_i2s_bclk <= '0';
    dac_i2s_ws   <= '0';
    dac_i2s_data <= '0';
    pmod_1       <= '0';
    pmod_2       <= '0';
    pmod_3       <= '0';
    pmod_4       <= '0';

end architecture rtl;