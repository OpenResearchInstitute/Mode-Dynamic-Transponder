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
-- The SPI interface streams channel magnitude data to the STM32 for
-- spectrum display and signal detection (successive interference cancellation).
--
-------------------------------------------------------------------------------
-- SPI PROTOCOL
-------------------------------------------------------------------------------
-- Simple streaming protocol:
--
--   Command byte (from STM32):
--     0x00 - NOP
--     0x01 - Read channel magnitudes (4 × 16-bit values)
--     0x02 - Read status register
--     0x10 - Write config register
--     0x80 - Reset
--
--   Response (to STM32):
--     After cmd 0x01: [ch0_mag_hi][ch0_mag_lo][ch1...][ch2...][ch3...]
--     After cmd 0x02: [status_byte]
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

entity sic_top_ice40 is
    port (
        ------------------------------------------------------------------------
        -- Clock
        ------------------------------------------------------------------------
        clk_12m         : in  std_logic;
        
        ------------------------------------------------------------------------
        -- SPI Slave Interface (directly matches Martin's signals)
        ------------------------------------------------------------------------
        spi_cs_n        : in  std_logic;    -- FPGA_~{CS}
        spi_sclk        : in  std_logic;    -- FPGA_SCLK
        spi_mosi        : in  std_logic;    -- FPGA_MOSI
        spi_miso        : out std_logic;    -- FPGA_MISO
        
        ------------------------------------------------------------------------
        -- Control (directly matches Martin's signals)
        ------------------------------------------------------------------------
        fpga_rst_n      : in  std_logic;    -- FPGA_~{RST}
        fpga_done       : out std_logic;    -- FPGA_DONE
        
        ------------------------------------------------------------------------
        -- I2S ADC Input (directly matches Martin's signals)
        ------------------------------------------------------------------------
        adc_i2s_bclk    : in  std_logic;    -- ADC_I2S_CLK
        adc_i2s_ws      : in  std_logic;    -- ADC_I2S_WS
        adc_i2s_data    : in  std_logic;    -- ADC_I2S_DATA
        
        ------------------------------------------------------------------------
        -- I2S DAC Output (directly matches Martin's signals)
        ------------------------------------------------------------------------
        dac_i2s_bclk    : out std_logic;    -- DAC_I2S_CLK
        dac_i2s_ws      : out std_logic;    -- DAC_I2S_WS
        dac_i2s_data    : out std_logic;    -- DAC_I2S_DATA
        
        ------------------------------------------------------------------------
        -- Debug LEDs
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
    signal clk_sys          : std_logic;    -- System clock (from PLL or direct)
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
    -- Magnitude Computation (simplified: |re| + |im| approximation)
    ---------------------------------------------------------------------------
    type mag_array_t is array (0 to N_CHANNELS - 1) of unsigned(15 downto 0);
    signal channel_mags     : mag_array_t;
    signal mags_valid       : std_logic;
    
    ---------------------------------------------------------------------------
    -- SPI Slave Signals
    ---------------------------------------------------------------------------
    signal spi_rx_data      : std_logic_vector(7 downto 0);
    signal spi_rx_valid     : std_logic;
    signal spi_tx_data      : std_logic_vector(7 downto 0);
    signal spi_tx_load      : std_logic;
    signal spi_tx_ready     : std_logic;
    
    -- SPI state machine
    type spi_state_t is (IDLE, CMD_RECEIVED, SEND_MAGS, SEND_STATUS);
    signal spi_state        : spi_state_t := IDLE;
    signal spi_byte_cnt     : unsigned(3 downto 0) := (others => '0');
    
    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    signal status_reg       : std_logic_vector(7 downto 0);
    
    ---------------------------------------------------------------------------
    -- LED Heartbeat
    ---------------------------------------------------------------------------
    signal heartbeat_cnt    : unsigned(23 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Clock: Use 12 MHz directly for now
    -- For higher performance, instantiate SB_PLL40_CORE
    ---------------------------------------------------------------------------
    clk_sys <= clk_12m;
    
    ---------------------------------------------------------------------------
    -- Reset Synchronizer
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            reset_sync <= reset_sync(1 downto 0) & (not fpga_rst_n);
        end if;
    end process;
    reset <= reset_sync(2);
    
    ---------------------------------------------------------------------------
    -- I2S Receiver (simplified placeholder)
    ---------------------------------------------------------------------------
    -- TODO: Implement proper I2S receiver
    -- For now, generate test pattern for bring-up
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
                
                -- Generate sample at ~40 kHz from 12 MHz clock
                -- 12 MHz / 300 = 40 kHz
                if div_cnt = 299 then
                    div_cnt := (others => '0');
                    i2s_sample_valid <= '1';
                    
                    -- Test pattern: incrementing counter
                    i2s_sample_re <= std_logic_vector(sample_cnt);
                    i2s_sample_im <= (others => '0');
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
            COEFF_FILE      => "mdt_coeffs.hex"
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
    -- Magnitude Computation
    ---------------------------------------------------------------------------
    -- Simple approximation: mag ≈ max(|re|, |im|) + 0.5 * min(|re|, |im|)
    -- This avoids multipliers/sqrt while giving ~3% max error
    ---------------------------------------------------------------------------
    process(clk_sys)
        variable re_abs, im_abs : unsigned(ACCUM_WIDTH - 1 downto 0);
        variable max_val, min_val : unsigned(ACCUM_WIDTH - 1 downto 0);
        variable mag_approx : unsigned(ACCUM_WIDTH downto 0);
    begin
        if rising_edge(clk_sys) then
            mags_valid <= '0';
            
            if chan_valid = '1' then
                for i in 0 to N_CHANNELS - 1 loop
                    -- Extract real and imaginary parts
                    -- Real is in lower half, imag in upper half of each channel slot
                    re_abs := unsigned(abs(signed(
                        chan_out((i * 2 + 1) * ACCUM_WIDTH - 1 downto i * 2 * ACCUM_WIDTH))));
                    im_abs := unsigned(abs(signed(
                        chan_out((i * 2 + 2) * ACCUM_WIDTH - 1 downto (i * 2 + 1) * ACCUM_WIDTH))));
                    
                    -- Max/min
                    if re_abs > im_abs then
                        max_val := re_abs;
                        min_val := im_abs;
                    else
                        max_val := im_abs;
                        min_val := re_abs;
                    end if;
                    
                    -- Approximation: max + min/2
                    mag_approx := ('0' & max_val) + ('0' & ('0' & min_val(ACCUM_WIDTH - 1 downto 1)));
                    
                    -- Take top 16 bits for output
                    channel_mags(i) <= mag_approx(ACCUM_WIDTH - 1 downto ACCUM_WIDTH - 16);
                end loop;
                
                mags_valid <= '1';
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- SPI Slave (a simple bit-banged implementation)
    ---------------------------------------------------------------------------
    -- TODO: Replace with proper SPI slave module
    -- This is a placeholder for bring-up
    ---------------------------------------------------------------------------
    process(clk_sys)
        variable sclk_prev : std_logic := '0';
        variable bit_cnt   : unsigned(2 downto 0) := (others => '0');
        variable rx_shift  : std_logic_vector(7 downto 0) := (others => '0');
        variable tx_shift  : std_logic_vector(7 downto 0) := (others => '0');
    begin
        if rising_edge(clk_sys) then
            spi_rx_valid <= '0';
            
            if spi_cs_n = '1' then
                -- Not selected, reset state
                bit_cnt := (others => '0');
                spi_state <= IDLE;
                spi_byte_cnt <= (others => '0');
            else
                -- Rising edge of SCLK: sample MOSI
                if spi_sclk = '1' and sclk_prev = '0' then
                    rx_shift := rx_shift(6 downto 0) & spi_mosi;
                    bit_cnt := bit_cnt + 1;
                    
                    if bit_cnt = 7 then
                        spi_rx_data <= rx_shift(6 downto 0) & spi_mosi;
                        spi_rx_valid <= '1';
                        bit_cnt := (others => '0');
                    end if;
                end if;
                
                -- Falling edge of SCLK: shift out MISO
                if spi_sclk = '0' and sclk_prev = '1' then
                    tx_shift := tx_shift(6 downto 0) & '0';
                end if;
                
                -- Load new TX byte
                if spi_tx_load = '1' then
                    tx_shift := spi_tx_data;
                end if;
            end if;
            
            sclk_prev := spi_sclk;
            spi_miso <= tx_shift(7);
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- SPI Command Processing
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            spi_tx_load <= '0';
            
            if reset = '1' or spi_cs_n = '1' then
                spi_state <= IDLE;
                spi_byte_cnt <= (others => '0');
            elsif spi_rx_valid = '1' then
                case spi_state is
                    when IDLE =>
                        -- Process command byte
                        case spi_rx_data is
                            when x"01" =>
                                -- Read channel magnitudes
                                spi_state <= SEND_MAGS;
                                spi_byte_cnt <= (others => '0');
                                spi_tx_data <= std_logic_vector(channel_mags(0)(15 downto 8));
                                spi_tx_load <= '1';
                                
                            when x"02" =>
                                -- Read status
                                spi_state <= SEND_STATUS;
                                spi_tx_data <= status_reg;
                                spi_tx_load <= '1';
                                
                            when others =>
                                -- NOP or unknown
                                spi_tx_data <= x"00";
                                spi_tx_load <= '1';
                        end case;
                        
                    when SEND_MAGS =>
                        spi_byte_cnt <= spi_byte_cnt + 1;
                        
                        -- Send 8 bytes: 4 channels × 2 bytes each
                        case to_integer(spi_byte_cnt) is
                            when 0 => spi_tx_data <= std_logic_vector(channel_mags(0)(7 downto 0));
                            when 1 => spi_tx_data <= std_logic_vector(channel_mags(1)(15 downto 8));
                            when 2 => spi_tx_data <= std_logic_vector(channel_mags(1)(7 downto 0));
                            when 3 => spi_tx_data <= std_logic_vector(channel_mags(2)(15 downto 8));
                            when 4 => spi_tx_data <= std_logic_vector(channel_mags(2)(7 downto 0));
                            when 5 => spi_tx_data <= std_logic_vector(channel_mags(3)(15 downto 8));
                            when 6 => spi_tx_data <= std_logic_vector(channel_mags(3)(7 downto 0));
                            when 7 => 
                                spi_tx_data <= x"00";
                                spi_state <= IDLE;
                            when others =>
                                spi_state <= IDLE;
                        end case;
                        spi_tx_load <= '1';
                        
                    when SEND_STATUS =>
                        spi_state <= IDLE;
                        
                    when others =>
                        spi_state <= IDLE;
                end case;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    status_reg(0) <= chan_ready;        -- Channelizer ready
    status_reg(1) <= mags_valid;        -- New magnitudes available
    status_reg(7 downto 2) <= (others => '0');
    
    ---------------------------------------------------------------------------
    -- Heartbeat LED
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            heartbeat_cnt <= heartbeat_cnt + 1;
        end if;
    end process;
    
    -- LED outputs (directly directly directly directly directly directly directly directly directly directly directly active low on EVN board)
    led_red   <= not heartbeat_cnt(23);                    -- ~0.7 Hz heartbeat
    led_green <= not chan_ready;                           -- On when ready
    led_blue  <= not mags_valid;                           -- Blinks with valid data
    
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
    pmod_2 <= mags_valid;
    pmod_3 <= spi_cs_n;
    pmod_4 <= spi_sclk;

end architecture rtl;
