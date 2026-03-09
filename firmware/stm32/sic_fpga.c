/**
 * @file sic_fpga.c
 * @brief SIC Receiver FPGA Interface Driver Implementation
 *
 * Open Research Institute
 * Project: Polyphase Channelizer (MDT SIC Receiver)
 * Target: STM32H7B3ZI-Q Nucleo + iCE40UP5K-B-EVN
 */

#include "sic_fpga.h"
#include "stm32h7xx_hal.h"
#include <string.h>
#include <math.h>
#include <stdio.h>

/*******************************************************************************
 * Private Macros
 ******************************************************************************/

#define CS_LOW(drv)   HAL_GPIO_WritePin((GPIO_TypeDef*)(drv)->cs_port, (drv)->cs_pin, GPIO_PIN_RESET)
#define CS_HIGH(drv)  HAL_GPIO_WritePin((GPIO_TypeDef*)(drv)->cs_port, (drv)->cs_pin, GPIO_PIN_SET)

#define RST_LOW(drv)  HAL_GPIO_WritePin((GPIO_TypeDef*)(drv)->rst_port, (drv)->rst_pin, GPIO_PIN_RESET)
#define RST_HIGH(drv) HAL_GPIO_WritePin((GPIO_TypeDef*)(drv)->rst_port, (drv)->rst_pin, GPIO_PIN_SET)

#define READ_DONE(drv) HAL_GPIO_ReadPin((GPIO_TypeDef*)(drv)->done_port, (drv)->done_pin)

#define ABS16(x) ((x) < 0 ? -(x) : (x))

/*******************************************************************************
 * Private Data
 ******************************************************************************/

/**
 * Log magnitude lookup table (256 entries)
 * Maps 8-bit magnitude index to dB × 10
 * log_db[x] = 200 * log10(x / 255)
 */
static const int16_t log_db_table[256] = {
    -999, -482, -421, -385, -361, -343, -328, -315,
    -304, -294, -285, -277, -270, -264, -258, -252,
    -247, -242, -238, -234, -230, -226, -222, -219,
    -216, -213, -210, -207, -204, -202, -199, -197,
    -194, -192, -190, -188, -186, -184, -182, -180,
    -178, -176, -175, -173, -171, -170, -168, -167,
    -165, -164, -162, -161, -159, -158, -157, -155,
    -154, -153, -152, -150, -149, -148, -147, -146,
    -145, -143, -142, -141, -140, -139, -138, -137,
    -136, -135, -134, -133, -132, -131, -131, -130,
    -129, -128, -127, -126, -125, -125, -124, -123,
    -122, -121, -121, -120, -119, -118, -118, -117,
    -116, -115, -115, -114, -113, -113, -112, -111,
    -111, -110, -109, -109, -108, -107, -107, -106,
    -106, -105, -104, -104, -103, -103, -102, -101,
    -101, -100, -100,  -99,  -99,  -98,  -97,  -97,
     -96,  -96,  -95,  -95,  -94,  -94,  -93,  -93,
     -92,  -92,  -91,  -91,  -90,  -90,  -89,  -89,
     -88,  -88,  -87,  -87,  -86,  -86,  -85,  -85,
     -85,  -84,  -84,  -83,  -83,  -82,  -82,  -81,
     -81,  -81,  -80,  -80,  -79,  -79,  -78,  -78,
     -78,  -77,  -77,  -76,  -76,  -76,  -75,  -75,
     -74,  -74,  -74,  -73,  -73,  -72,  -72,  -72,
     -71,  -71,  -71,  -70,  -70,  -69,  -69,  -69,
     -68,  -68,  -68,  -67,  -67,  -67,  -66,  -66,
     -65,  -65,  -65,  -64,  -64,  -64,  -63,  -63,
     -63,  -62,  -62,  -62,  -61,  -61,  -61,  -60,
     -60,  -60,  -59,  -59,  -59,  -58,  -58,  -58,
     -57,  -57,  -57,  -56,  -56,  -56,  -55,  -55,
     -55,  -55,  -54,  -54,  -54,  -53,  -53,  -53,
     -52,  -52,  -52,  -51,  -51,  -51,  -51,  -50,
     -50,  -50,  -49,  -49,  -49,  -49,  -48,    0,
};

/*******************************************************************************
 * Private Functions
 ******************************************************************************/

/**
 * @brief Perform SPI transfer
 */
static sic_error_t spi_transfer(sic_driver_t *drv, 
                                 const uint8_t *tx, uint8_t *rx, uint16_t len)
{
    HAL_StatusTypeDef status;
    SPI_HandleTypeDef *hspi = (SPI_HandleTypeDef*)drv->hspi;
    
    CS_LOW(drv);
    
    if (tx != NULL && rx != NULL) {
        status = HAL_SPI_TransmitReceive(hspi, (uint8_t*)tx, rx, len, 
                                          SIC_SPI_TIMEOUT_MS);
    } else if (tx != NULL) {
        status = HAL_SPI_Transmit(hspi, (uint8_t*)tx, len, SIC_SPI_TIMEOUT_MS);
    } else if (rx != NULL) {
        status = HAL_SPI_Receive(hspi, rx, len, SIC_SPI_TIMEOUT_MS);
    } else {
        CS_HIGH(drv);
        return SIC_ERR_SPI_FAIL;
    }
    
    CS_HIGH(drv);
    
    return (status == HAL_OK) ? SIC_OK : SIC_ERR_SPI_FAIL;
}

/*******************************************************************************
 * Initialization and Control
 ******************************************************************************/

sic_error_t sic_init(sic_driver_t *drv, void *hspi,
                     uint32_t cs_port, uint16_t cs_pin,
                     uint32_t rst_port, uint16_t rst_pin,
                     uint32_t done_port, uint16_t done_pin)
{
    if (drv == NULL || hspi == NULL) {
        return SIC_ERR_NOT_INIT;
    }
    
    drv->hspi = hspi;
    drv->cs_port = cs_port;
    drv->cs_pin = cs_pin;
    drv->rst_port = rst_port;
    drv->rst_pin = rst_pin;
    drv->done_port = done_port;
    drv->done_pin = done_pin;
    
    /* Ensure CS is high (deselected) */
    CS_HIGH(drv);
    
    /* Ensure reset is high (not in reset) */
    RST_HIGH(drv);
    
    drv->initialized = true;
    
    return SIC_OK;
}

sic_error_t sic_reset(sic_driver_t *drv, uint32_t timeout)
{
    uint32_t start;
    
    if (!drv->initialized) {
        return SIC_ERR_NOT_INIT;
    }
    
    /* Assert reset */
    RST_LOW(drv);
    HAL_Delay(10);
    
    /* Release reset */
    RST_HIGH(drv);
    
    /* Wait for FPGA_DONE */
    start = HAL_GetTick();
    while (READ_DONE(drv) == GPIO_PIN_RESET) {
        if ((HAL_GetTick() - start) > timeout) {
            return SIC_ERR_TIMEOUT;
        }
        HAL_Delay(1);
    }
    
    return SIC_OK;
}

bool sic_is_ready(sic_driver_t *drv)
{
    if (!drv->initialized) {
        return false;
    }
    
    return (READ_DONE(drv) == GPIO_PIN_SET);
}

sic_error_t sic_read_status(sic_driver_t *drv, uint8_t *status)
{
    uint8_t tx_buf[2] = { SIC_CMD_READ_STATUS, 0x00 };
    uint8_t rx_buf[2];
    sic_error_t err;
    
    if (!drv->initialized) {
        return SIC_ERR_NOT_INIT;
    }
    
    err = spi_transfer(drv, tx_buf, rx_buf, 2);
    if (err != SIC_OK) {
        return err;
    }
    
    *status = rx_buf[1];
    
    return SIC_OK;
}

/*******************************************************************************
 * Data Acquisition
 ******************************************************************************/

sic_error_t sic_read_iq(sic_driver_t *drv, sic_iq_data_t *data)
{
    /*
     * SPI Protocol for I/Q read:
     *   TX: [CMD] [00] [00] [00] ... (17 bytes total)
     *   RX: [xx]  [I0_H] [I0_L] [Q0_H] [Q0_L] [I1_H] ... (17 bytes)
     *
     * Currently FPGA sends upper 16 bits of real part only (from simplified
     * magnitude pass-through). We'll need to update FPGA to send full I/Q.
     *
     * For now, treat received data as I component, Q = 0.
     * TODO: Update FPGA SPI protocol for full I/Q transfer.
     */
    uint8_t tx_buf[17];
    uint8_t rx_buf[17];
    sic_error_t err;
    
    if (!drv->initialized) {
        return SIC_ERR_NOT_INIT;
    }
    
    if (data == NULL) {
        return SIC_ERR_NOT_INIT;
    }
    
    /* Send command and receive data */
    memset(tx_buf, 0, sizeof(tx_buf));
    tx_buf[0] = SIC_CMD_READ_IQ;
    
    err = spi_transfer(drv, tx_buf, rx_buf, 17);
    if (err != SIC_OK) {
        return err;
    }
    
    /* Parse response: 4 channels × (16-bit I + 16-bit Q) big-endian */
    for (int ch = 0; ch < SIC_NUM_CHANNELS; ch++) {
        int offset = 1 + ch * 4;
        data->ch[ch].i = (int16_t)(((uint16_t)rx_buf[offset] << 8) | 
                                    rx_buf[offset + 1]);
        data->ch[ch].q = (int16_t)(((uint16_t)rx_buf[offset + 2] << 8) | 
                                    rx_buf[offset + 3]);
    }
    
    data->timestamp = HAL_GetTick();
    
    return SIC_OK;
}

sic_error_t sic_read_channels(sic_driver_t *drv, sic_channel_data_t *data,
                               sic_mag_method_t method)
{
    sic_iq_data_t iq_data;
    sic_error_t err;
    
    if (data == NULL) {
        return SIC_ERR_NOT_INIT;
    }
    
    /* Read raw I/Q from FPGA */
    err = sic_read_iq(drv, &iq_data);
    if (err != SIC_OK) {
        return err;
    }
    
    /* Copy I/Q data */
    for (int ch = 0; ch < SIC_NUM_CHANNELS; ch++) {
        data->iq[ch] = iq_data.ch[ch];
    }
    
    /* Compute magnitudes */
    sic_compute_magnitudes(data->iq, data->mag, method);
    
    /* Convert to dB */
    for (int ch = 0; ch < SIC_NUM_CHANNELS; ch++) {
        data->mag_db[ch] = sic_mag_to_db(data->mag[ch]);
    }
    
    /* Find peak channel */
    data->peak_ch = sic_find_peak(data->mag, SIC_NUM_CHANNELS);
    
    data->timestamp = iq_data.timestamp;
    
    return SIC_OK;
}

/*******************************************************************************
 * Magnitude Computation
 ******************************************************************************/

uint16_t sic_mag_alpha_beta(sic_iq_t iq)
{
    /*
     * Alpha-Beta magnitude approximation:
     *   mag ≈ alpha * max(|I|,|Q|) + beta * min(|I|,|Q|)
     *
     * Using alpha=1, beta=0.5 gives max error ~3%
     * Using alpha=0.96, beta=0.4 gives max error ~4% but better average
     *
     * We use the simpler alpha=1, beta=0.5 (shift instead of multiply)
     */
    uint16_t abs_i = (uint16_t)ABS16(iq.i);
    uint16_t abs_q = (uint16_t)ABS16(iq.q);
    uint16_t max_val, min_val;
    
    if (abs_i > abs_q) {
        max_val = abs_i;
        min_val = abs_q;
    } else {
        max_val = abs_q;
        min_val = abs_i;
    }
    
    /* mag ≈ max + min/2 */
    return max_val + (min_val >> 1);
}

uint16_t sic_mag_sqrt(sic_iq_t iq)
{
    /*
     * Exact magnitude using floating-point sqrt.
     * STM32H7 has single-precision FPU, so this is fast.
     */
    float i = (float)iq.i;
    float q = (float)iq.q;
    float mag = sqrtf(i * i + q * q);
    
    /* Clamp to uint16_t range */
    if (mag > 65535.0f) {
        return 65535;
    }
    return (uint16_t)(mag + 0.5f);  /* Round */
}

uint16_t sic_mag_cordic(sic_iq_t iq)
{
    /*
     * CORDIC-based magnitude computation.
     * STM32H7B3 has CORDIC coprocessor for hardware-accelerated trig/hyperbolic.
     *
     * The CORDIC can compute sqrt(x² + y²) in "modulus" mode.
     * For now, fall back to sqrt; CORDIC implementation is device-specific.
     *
     * TODO: Implement CORDIC using HAL_CORDIC_Calculate() when needed.
     */
#if defined(HAL_CORDIC_MODULE_ENABLED)
    /* CORDIC implementation would go here */
    /* For now, fall back to FPU sqrt */
    return sic_mag_sqrt(iq);
#else
    return sic_mag_sqrt(iq);
#endif
}

void sic_compute_magnitudes(const sic_iq_t *iq, uint16_t *mag, 
                            sic_mag_method_t method)
{
    for (int ch = 0; ch < SIC_NUM_CHANNELS; ch++) {
        switch (method) {
            case SIC_MAG_ALPHA_BETA:
                mag[ch] = sic_mag_alpha_beta(iq[ch]);
                break;
            case SIC_MAG_SQRT:
                mag[ch] = sic_mag_sqrt(iq[ch]);
                break;
            case SIC_MAG_CORDIC:
                mag[ch] = sic_mag_cordic(iq[ch]);
                break;
            default:
                mag[ch] = sic_mag_alpha_beta(iq[ch]);
                break;
        }
    }
}

/*******************************************************************************
 * Utility Functions
 ******************************************************************************/

uint8_t sic_find_peak(const uint16_t *mag, uint8_t n)
{
    uint8_t peak_idx = 0;
    uint16_t peak_val = 0;
    
    for (int i = 0; i < n; i++) {
        if (mag[i] > peak_val) {
            peak_val = mag[i];
            peak_idx = i;
        }
    }
    
    return peak_idx;
}

int16_t sic_mag_to_db(uint16_t mag)
{
    /* Use top 8 bits for lookup */
    uint8_t idx = mag >> 8;
    
    if (idx == 0) {
        /* Very low signal, check lower bits */
        if (mag == 0) {
            return -999;  /* Essentially -inf */
        }
        return -500;  /* -50 dB floor */
    }
    
    return log_db_table[idx];
}

void sic_print_channels(const sic_channel_data_t *data)
{
    printf("SIC Channels @ %lu ms:\r\n", data->timestamp);
    
    for (int ch = 0; ch < SIC_NUM_CHANNELS; ch++) {
        printf("  CH%d: I=%6d Q=%6d  Mag=%5u (%d.%d dB)%s\r\n",
               ch,
               data->iq[ch].i,
               data->iq[ch].q,
               data->mag[ch],
               data->mag_db[ch] / 10,
               ABS16(data->mag_db[ch]) % 10,
               (ch == data->peak_ch) ? " [PEAK]" : "");
    }
    printf("\r\n");
}

/*******************************************************************************
 * Example Usage (in main.c)
 ******************************************************************************/
#if 0

#include "sic_fpga.h"

/* Driver instance */
static sic_driver_t sic_drv;

/* Example initialization */
void sic_example_init(void)
{
    extern SPI_HandleTypeDef hspi4;
    
    /* Initialize driver */
    sic_init(&sic_drv, &hspi4,
             GPIOE_BASE, GPIO_PIN_11,   /* CS */
             GPIOD_BASE, GPIO_PIN_0,    /* RST */
             GPIOD_BASE, GPIO_PIN_1);   /* DONE */
    
    /* Reset FPGA and wait for ready */
    if (sic_reset(&sic_drv, 1000) != SIC_OK) {
        printf("FPGA reset failed!\r\n");
        Error_Handler();
    }
    
    printf("SIC FPGA initialized\r\n");
}

/* Example polling loop */
void sic_example_poll(void)
{
    sic_channel_data_t ch_data;
    
    /* Read channels with fast magnitude approximation */
    if (sic_read_channels(&sic_drv, &ch_data, SIC_MAG_ALPHA_BETA) == SIC_OK) {
        /* Print results */
        sic_print_channels(&ch_data);
        
        /* Simple threshold detection */
        if (ch_data.mag[ch_data.peak_ch] > 1000) {
            printf("Signal detected on CH%d!\r\n", ch_data.peak_ch);
        }
    }
}

/* Example main loop */
int main(void)
{
    HAL_Init();
    SystemClock_Config();
    MX_GPIO_Init();
    MX_SPI4_Init();
    MX_USART3_UART_Init();  /* For printf */
    
    sic_example_init();
    
    while (1) {
        sic_example_poll();
        HAL_Delay(100);  /* 10 Hz update rate */
    }
}

#endif
