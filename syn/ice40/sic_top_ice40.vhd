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
--     0x01 - Read channel I/Q data (4 channels × 4 bytes = 16 bytes)
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
    -- SPI Slave Signals
    ---------------------------------------------------------------------------
    signal spi_rx_data      : std_logic_vector(7 downto 0);
    signal spi_rx_valid     : std_logic;
    signal spi_tx_data      : std_logic_vector(7 downto 0);
    signal spi_tx_load      : std_logic;
    
    -- SPI state machine
    type spi_state_t is (IDLE, SEND_IQ, SEND_STATUS);
    signal spi_state        : spi_state_t := IDLE;
    signal spi_byte_cnt     : unsigned(4 downto 0) := (others => '0');  -- 5 bits for 0-16
    
    -- SPI shift registers
    signal sclk_prev        : std_logic := '0';
    signal spi_bit_cnt      : unsigned(2 downto 0) := (others => '0');
    signal spi_rx_shift     : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_tx_shift     : std_logic_vector(7 downto 0) := (others => '0');
    
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
    -- I2S Receiver (test pattern generator for bring-up)
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
                if div_cnt = 299 then
                    div_cnt := (others => '0');
                    i2s_sample_valid <= '1';
                    
                    -- Test pattern: incrementing counter (real), inverted (imag)
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
    ---------------------------------------------------------------------------
    -- The channelizer outputs complex data. We extract the upper 16 bits
    -- of both real (I) and imaginary (Q) components for each channel.
    -- Full magnitude computation is done on the STM32 (FPU is faster).
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            iq_valid <= chan_valid;
            if chan_valid = '1' then
                for i in 0 to N_CHANNELS - 1 loop
                    -- Extract upper 16 bits of real part (I)
                    channel_i(i) <= signed(chan_out((i * 2 + 1) * ACCUM_WIDTH - 1 
                                                downto (i * 2 + 1) * ACCUM_WIDTH - 16));
                    -- Extract upper 16 bits of imaginary part (Q)
                    channel_q(i) <= signed(chan_out((i * 2 + 2) * ACCUM_WIDTH - 1 
                                                downto (i * 2 + 2) * ACCUM_WIDTH - 16));
                end loop;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- SPI Slave (single unified process)
    ---------------------------------------------------------------------------
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            spi_rx_valid <= '0';
            spi_tx_load <= '0';
            
            if reset = '1' or spi_cs_n = '1' then
                -- Not selected or in reset
                spi_bit_cnt <= (others => '0');
                spi_state <= IDLE;
                spi_byte_cnt <= (others => '0');
                sclk_prev <= '0';
            else
                -- Rising edge of SCLK: sample MOSI
                if spi_sclk = '1' and sclk_prev = '0' then
                    spi_rx_shift <= spi_rx_shift(6 downto 0) & spi_mosi;
                    spi_bit_cnt <= spi_bit_cnt + 1;
                    
                    if spi_bit_cnt = 7 then
                        spi_rx_data <= spi_rx_shift(6 downto 0) & spi_mosi;
                        spi_rx_valid <= '1';
                        spi_bit_cnt <= (others => '0');
                    end if;
                end if;
                
                -- Falling edge of SCLK: shift out MISO
                if spi_sclk = '0' and sclk_prev = '1' then
                    spi_tx_shift <= spi_tx_shift(6 downto 0) & '0';
                end if;
                
                -- Load new TX byte when requested
                if spi_tx_load = '1' then
                    spi_tx_shift <= spi_tx_data;
                end if;
                
                -- Process received bytes
                if spi_rx_valid = '1' then
                    case spi_state is
                        when IDLE =>
                            case spi_rx_data is
                                when x"01" =>
                                    -- Read channel I/Q data
                                    spi_state <= SEND_IQ;
                                    spi_byte_cnt <= (others => '0');
                                    spi_tx_data <= std_logic_vector(channel_i(0)(15 downto 8));
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
                            
                        when SEND_IQ =>
                            spi_byte_cnt <= spi_byte_cnt + 1;
                            
                            -- Send 16 bytes: 4 channels × (2 bytes I + 2 bytes Q)
                            -- Format: [I0_H][I0_L][Q0_H][Q0_L][I1_H][I1_L][Q1_H][Q1_L]...
                            case to_integer(spi_byte_cnt) is
                                -- Channel 0
                                when 0  => spi_tx_data <= std_logic_vector(channel_i(0)(7 downto 0));
                                when 1  => spi_tx_data <= std_logic_vector(channel_q(0)(15 downto 8));
                                when 2  => spi_tx_data <= std_logic_vector(channel_q(0)(7 downto 0));
                                -- Channel 1
                                when 3  => spi_tx_data <= std_logic_vector(channel_i(1)(15 downto 8));
                                when 4  => spi_tx_data <= std_logic_vector(channel_i(1)(7 downto 0));
                                when 5  => spi_tx_data <= std_logic_vector(channel_q(1)(15 downto 8));
                                when 6  => spi_tx_data <= std_logic_vector(channel_q(1)(7 downto 0));
                                -- Channel 2
                                when 7  => spi_tx_data <= std_logic_vector(channel_i(2)(15 downto 8));
                                when 8  => spi_tx_data <= std_logic_vector(channel_i(2)(7 downto 0));
                                when 9  => spi_tx_data <= std_logic_vector(channel_q(2)(15 downto 8));
                                when 10 => spi_tx_data <= std_logic_vector(channel_q(2)(7 downto 0));
                                -- Channel 3
                                when 11 => spi_tx_data <= std_logic_vector(channel_i(3)(15 downto 8));
                                when 12 => spi_tx_data <= std_logic_vector(channel_i(3)(7 downto 0));
                                when 13 => spi_tx_data <= std_logic_vector(channel_q(3)(15 downto 8));
                                when 14 => spi_tx_data <= std_logic_vector(channel_q(3)(7 downto 0));
                                when 15 =>
                                    spi_tx_data <= x"00";
                                    spi_state <= IDLE;
                                when others =>
                                    spi_state <= IDLE;
                            end case;
                            spi_tx_load <= '1';
                            
                        when SEND_STATUS =>
                            spi_state <= IDLE;
                    end case;
                end if;
                
                sclk_prev <= spi_sclk;
            end if;
            
            spi_miso <= spi_tx_shift(7);
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Status Register
    ---------------------------------------------------------------------------
    status_reg(0) <= chan_ready;
    status_reg(1) <= iq_valid;
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
    
    -- LED outputs (active low on EVN board)
    led_red   <= not heartbeat_cnt(23);
    led_green <= not chan_ready;
    led_blue  <= not iq_valid;
    
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
    pmod_3 <= spi_cs_n;
    pmod_4 <= spi_sclk;

end architecture rtl;
