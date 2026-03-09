/**
 * @file sic_fpga.h
 * @brief SIC Receiver FPGA Interface Driver for STM32H7
 *
 * Open Research Institute
 * Project: Polyphase Channelizer (MDT SIC Receiver)
 * Target: STM32H7B3ZI-Q Nucleo + iCE40UP5K-B-EVN
 *
 * This driver communicates with the iCE40 FPGA over SPI to:
 *   - Read raw I/Q channel data from the polyphase channelizer
 *   - Compute magnitude on the STM32 (faster than FPGA)
 *   - Control FPGA reset and configuration
 *   - Monitor FPGA status
 *
 * Data flow:
 *   FPGA: ADC -> Polyphase Filterbank -> FFT -> SPI
 *   STM32: SPI -> Magnitude -> Peak Detection -> SIC Algorithm
 *
 * Hardware connections (matching Martin Ling's design):
 *   STM32 SPI4_SCK  (PE12) -> FPGA spi_sclk
 *   STM32 SPI4_MISO (PE13) -> FPGA spi_miso  
 *   STM32 SPI4_MOSI (PE14) -> FPGA spi_mosi
 *   STM32 SPI4_NSS  (PE11) -> FPGA spi_cs_n
 *   STM32 GPIO      (PD0)  -> FPGA fpga_rst_n
 *   STM32 GPIO      (PD1)  <- FPGA fpga_done
 */

#ifndef SIC_FPGA_H
#define SIC_FPGA_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

/*******************************************************************************
 * Configuration
 ******************************************************************************/

/** Number of frequency channels in the channelizer */
#define SIC_NUM_CHANNELS        4

/** SPI clock frequency (Hz) - max 25 MHz for iCE40 */
#define SIC_SPI_CLOCK_HZ        10000000

/** Timeout for SPI operations (ms) */
#define SIC_SPI_TIMEOUT_MS      100

/*******************************************************************************
 * SPI Commands (matching FPGA protocol)
 ******************************************************************************/

#define SIC_CMD_NOP             0x00
#define SIC_CMD_READ_IQ         0x01    /**< Read raw I/Q data (was READ_MAGS) */
#define SIC_CMD_READ_STATUS     0x02
#define SIC_CMD_WRITE_CONFIG    0x10
#define SIC_CMD_RESET           0x80

/*******************************************************************************
 * Status Register Bits
 ******************************************************************************/

#define SIC_STATUS_READY        (1 << 0)    /**< Channelizer ready */
#define SIC_STATUS_DATA_VALID   (1 << 1)    /**< New data available */

/*******************************************************************************
 * Data Types
 ******************************************************************************/

/**
 * @brief Complex I/Q sample (16-bit signed)
 */
typedef struct {
    int16_t i;      /**< In-phase component */
    int16_t q;      /**< Quadrature component */
} sic_iq_t;

/**
 * @brief Raw channel data from FPGA (complex I/Q per channel)
 */
typedef struct {
    sic_iq_t ch[SIC_NUM_CHANNELS];  /**< Per-channel complex data */
    uint32_t timestamp;              /**< Capture timestamp (systick) */
} sic_iq_data_t;

/**
 * @brief Processed channel data with magnitudes
 */
typedef struct {
    sic_iq_t iq[SIC_NUM_CHANNELS];      /**< Raw I/Q (preserved) */
    uint16_t mag[SIC_NUM_CHANNELS];     /**< Computed magnitudes */
    int16_t  mag_db[SIC_NUM_CHANNELS];  /**< Magnitudes in 0.1 dB */
    uint8_t  peak_ch;                   /**< Index of strongest channel */
    uint32_t timestamp;                 /**< Capture timestamp */
} sic_channel_data_t;

/**
 * @brief Driver state
 */
typedef struct {
    void *hspi;                         /**< SPI handle (HAL) */
    uint32_t cs_port;                   /**< CS GPIO port base */
    uint16_t cs_pin;                    /**< CS GPIO pin */
    uint32_t rst_port;                  /**< Reset GPIO port base */
    uint16_t rst_pin;                   /**< Reset GPIO pin */
    uint32_t done_port;                 /**< Done GPIO port base */
    uint16_t done_pin;                  /**< Done GPIO pin */
    bool initialized;                   /**< Initialization flag */
} sic_driver_t;

/**
 * @brief Error codes
 */
typedef enum {
    SIC_OK = 0,
    SIC_ERR_NOT_INIT,
    SIC_ERR_SPI_FAIL,
    SIC_ERR_TIMEOUT,
    SIC_ERR_FPGA_NOT_READY,
} sic_error_t;

/**
 * @brief Magnitude computation method
 */
typedef enum {
    SIC_MAG_ALPHA_BETA,     /**< Fast approximation: max + 0.5*min (~3% error) */
    SIC_MAG_SQRT,           /**< Exact: sqrt(i² + q²) using FPU */
    SIC_MAG_CORDIC,         /**< Hardware CORDIC (if available) */
} sic_mag_method_t;

/*******************************************************************************
 * API Functions
 ******************************************************************************/

/**
 * @brief Initialize the SIC FPGA driver
 *
 * @param drv       Pointer to driver state structure
 * @param hspi      HAL SPI handle (SPI_HandleTypeDef*)
 * @param cs_port   Chip select GPIO port (e.g., GPIOE_BASE)
 * @param cs_pin    Chip select GPIO pin (e.g., GPIO_PIN_11)
 * @param rst_port  Reset GPIO port
 * @param rst_pin   Reset GPIO pin
 * @param done_port Done GPIO port
 * @param done_pin  Done GPIO pin
 *
 * @return SIC_OK on success
 */
sic_error_t sic_init(sic_driver_t *drv, void *hspi,
                     uint32_t cs_port, uint16_t cs_pin,
                     uint32_t rst_port, uint16_t rst_pin,
                     uint32_t done_port, uint16_t done_pin);

/**
 * @brief Reset the FPGA
 *
 * Pulses the reset line and waits for FPGA_DONE to assert.
 *
 * @param drv       Pointer to driver state
 * @param timeout   Timeout in milliseconds
 *
 * @return SIC_OK on success, SIC_ERR_TIMEOUT if FPGA doesn't come ready
 */
sic_error_t sic_reset(sic_driver_t *drv, uint32_t timeout);

/**
 * @brief Check if FPGA is ready
 *
 * @param drv       Pointer to driver state
 *
 * @return true if FPGA is ready (FPGA_DONE asserted)
 */
bool sic_is_ready(sic_driver_t *drv);

/**
 * @brief Read raw I/Q data from FPGA
 *
 * Retrieves complex I/Q values for all frequency channels.
 * This is the low-level read; use sic_read_channels() for processed data.
 *
 * @param drv       Pointer to driver state
 * @param data      Output: raw I/Q data
 *
 * @return SIC_OK on success
 */
sic_error_t sic_read_iq(sic_driver_t *drv, sic_iq_data_t *data);

/**
 * @brief Read and process channel data
 *
 * Reads raw I/Q from FPGA, computes magnitudes, finds peak channel.
 * This is the main function for SIC operation.
 *
 * @param drv       Pointer to driver state
 * @param data      Output: processed channel data
 * @param method    Magnitude computation method
 *
 * @return SIC_OK on success
 */
sic_error_t sic_read_channels(sic_driver_t *drv, sic_channel_data_t *data,
                               sic_mag_method_t method);

/**
 * @brief Read FPGA status register
 *
 * @param drv       Pointer to driver state
 * @param status    Output: status byte
 *
 * @return SIC_OK on success
 */
sic_error_t sic_read_status(sic_driver_t *drv, uint8_t *status);

/*******************************************************************************
 * Magnitude Computation Functions
 ******************************************************************************/

/**
 * @brief Compute magnitude using alpha-beta approximation
 *
 * Fast approximation: mag ≈ max(|i|,|q|) + 0.5 * min(|i|,|q|)
 * Maximum error: ~3%
 *
 * @param iq        Complex I/Q sample
 *
 * @return Magnitude (linear scale)
 */
uint16_t sic_mag_alpha_beta(sic_iq_t iq);

/**
 * @brief Compute magnitude using FPU sqrt
 *
 * Exact computation: mag = sqrt(i² + q²)
 *
 * @param iq        Complex I/Q sample
 *
 * @return Magnitude (linear scale)
 */
uint16_t sic_mag_sqrt(sic_iq_t iq);

/**
 * @brief Compute magnitude using CORDIC
 *
 * Uses STM32H7 CORDIC coprocessor for hardware-accelerated computation.
 * Falls back to sqrt if CORDIC not available.
 *
 * @param iq        Complex I/Q sample
 *
 * @return Magnitude (linear scale)
 */
uint16_t sic_mag_cordic(sic_iq_t iq);

/**
 * @brief Compute magnitudes for all channels
 *
 * @param iq        Array of I/Q samples (SIC_NUM_CHANNELS)
 * @param mag       Output: magnitudes (SIC_NUM_CHANNELS)
 * @param method    Computation method
 */
void sic_compute_magnitudes(const sic_iq_t *iq, uint16_t *mag, 
                            sic_mag_method_t method);

/*******************************************************************************
 * Utility Functions
 ******************************************************************************/

/**
 * @brief Find the channel with maximum magnitude
 *
 * @param mag       Array of magnitudes
 * @param n         Number of channels
 *
 * @return Index of channel with highest magnitude
 */
uint8_t sic_find_peak(const uint16_t *mag, uint8_t n);

/**
 * @brief Convert magnitude to dB (scaled by 10)
 *
 * Uses lookup table for fast conversion.
 *
 * @param mag       Linear magnitude value
 *
 * @return Magnitude in dB × 10 (e.g., -123 = -12.3 dB)
 */
int16_t sic_mag_to_db(uint16_t mag);

/**
 * @brief Print channel data to debug output
 *
 * Formats and prints I/Q values, magnitudes, and peak info.
 * Requires printf support.
 *
 * @param data      Processed channel data
 */
void sic_print_channels(const sic_channel_data_t *data);

#ifdef __cplusplus
}
#endif

#endif /* SIC_FPGA_H */
