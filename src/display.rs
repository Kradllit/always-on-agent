//! The screen: a round 466 x 466 AMOLED behind a CO5300 chip, on an SPI bus with four
//! data lines. The chip is driven by Espressif's C driver (esp_lcd); this file wraps it.
//!
//! There is no picture of the whole screen in memory. A caller paints a rectangle one
//! band of rows at a time, and each band goes straight to the screen. Black pixels are
//! switched-off pixels on an AMOLED, so a mostly black face costs little power.

use core::ffi::c_void;
use core::ptr::null_mut;

use anyhow::{bail, Result};
use esp_idf_svc::sys::*;

use crate::board::{LCD_CLK, LCD_CS, LCD_DATA, LCD_RESET, SCREEN};

/// Rows sent to the screen in one go.
const BAND_ROWS: i32 = 20;
const BAND_BYTES: usize = (SCREEN * BAND_ROWS * 2) as usize;

/// What the chip is told at start: (command, data, wait afterwards in ms).
const INIT: &[(u8, &[u8], u32)] = &[
    (0xFE, &[0x20], 0), // the four-data-line mode
    (0x19, &[0x10], 0),
    (0x1C, &[0xA0], 0),
    (0xFE, &[0x00], 0),
    (0xC4, &[0x80], 0),
    (0x3A, &[0x55], 0), // 16 bits a pixel
    (0x35, &[0x00], 0),
    (0x53, &[0x20], 0),
    (0x51, &[0x00], 0), // brightness 0: nothing shows until the screen has been cleared
    (0x63, &[0xFF], 0),
    (0x2A, &[0x00, 0x06, 0x01, 0xD7], 0),
    (0x2B, &[0x00, 0x00, 0x01, 0xD1], 600),
    (0x11, &[], 600), // wake
    (0x29, &[], 0),   // on
];

pub struct Display {
    io: esp_lcd_panel_io_handle_t,
    panel: esp_lcd_panel_handle_t,
    // Two bands, used in turn: the screen may still be reading the one sent last while the
    // next is painted. (The driver finishes a transfer before it starts the one after.)
    bands: [*mut u8; 2],
    next: usize,
}

impl Display {
    pub fn new() -> Result<Self> {
        unsafe {
            let mut bus: spi_bus_config_t = core::mem::zeroed();
            bus.sclk_io_num = LCD_CLK;
            bus.__bindgen_anon_1.data0_io_num = LCD_DATA[0];
            bus.__bindgen_anon_2.data1_io_num = LCD_DATA[1];
            bus.__bindgen_anon_3.data2_io_num = LCD_DATA[2];
            bus.__bindgen_anon_4.data3_io_num = LCD_DATA[3];
            // Unused lines must say so: left at 0 they claim GPIO 0, the BOOT button.
            bus.data4_io_num = -1;
            bus.data5_io_num = -1;
            bus.data6_io_num = -1;
            bus.data7_io_num = -1;
            bus.max_transfer_sz = BAND_BYTES as i32;
            bus.flags = SPICOMMON_BUSFLAG_QUAD;
            // The bus's interrupt stays on core 0, with the task that draws (main). Spread
            // over two cores, ESP-IDF's bus lock can lose a hand-over and the drawing task
            // then waits for ever: seen on this board on 2026-11-12.
            bus.isr_cpu_id = esp_intr_cpu_affinity_t_ESP_INTR_CPU_AFFINITY_0;
            esp!(spi_bus_initialize(spi_host_device_t_SPI2_HOST, &bus, spi_common_dma_t_SPI_DMA_CH_AUTO))?;

            let mut io_config: esp_lcd_panel_io_spi_config_t = core::mem::zeroed();
            io_config.cs_gpio_num = LCD_CS;
            io_config.dc_gpio_num = -1;
            io_config.spi_mode = 0;
            io_config.pclk_hz = 40_000_000;
            io_config.trans_queue_depth = 10;
            io_config.lcd_cmd_bits = 32;
            io_config.lcd_param_bits = 8;
            io_config.flags.set_quad_mode(1);
            let mut io: esp_lcd_panel_io_handle_t = null_mut();
            esp!(esp_lcd_new_panel_io_spi(spi_host_device_t_SPI2_HOST as _, &io_config, &mut io))?;

            // The driver keeps pointers to these, so they are never freed.
            let commands: &'static [co5300_lcd_init_cmd_t] = Box::leak(
                INIT.iter()
                    .map(|&(cmd, data, delay_ms)| co5300_lcd_init_cmd_t {
                        cmd: cmd as i32,
                        data: if data.is_empty() { core::ptr::null() } else { data.as_ptr() as *const c_void },
                        data_bytes: data.len(),
                        delay_ms,
                    })
                    .collect::<Vec<_>>()
                    .into_boxed_slice(),
            );
            let vendor: &'static mut co5300_vendor_config_t = Box::leak(Box::new(core::mem::zeroed()));
            vendor.init_cmds = commands.as_ptr();
            vendor.init_cmds_size = commands.len() as u16;
            vendor.flags.set_use_qspi_interface(1);

            let mut config: esp_lcd_panel_dev_config_t = core::mem::zeroed();
            config.reset_gpio_num = LCD_RESET;
            config.__bindgen_anon_1.rgb_ele_order = lcd_rgb_element_order_t_LCD_RGB_ELEMENT_ORDER_RGB;
            config.bits_per_pixel = 16;
            config.vendor_config = vendor as *mut co5300_vendor_config_t as *mut c_void;
            let mut panel: esp_lcd_panel_handle_t = null_mut();
            esp!(esp_lcd_new_panel_co5300(io, &config, &mut panel))?;
            esp!(esp_lcd_panel_set_gap(panel, 6, 0))?;
            esp!(esp_lcd_panel_reset(panel))?;
            esp!(esp_lcd_panel_init(panel))?;
            esp!(esp_lcd_panel_invert_color(panel, false))?;
            esp!(esp_lcd_panel_disp_on_off(panel, true))?;

            // SPI sends straight out of these, so they must be in internal, DMA-able memory.
            let mut bands = [null_mut(); 2];
            for band in &mut bands {
                *band = heap_caps_malloc(BAND_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL) as *mut u8;
                if band.is_null() {
                    bail!("no memory for the screen's bands");
                }
            }
            let mut display = Display { io, panel, bands, next: 0 };
            display.paint(0, 0, SCREEN, SCREEN, |_, _, band| band.fill(0))?;
            Ok(display)
        }
    }

    /// Paint a rectangle of the screen. `x`, `y`, `w` and `h` must be even (the chip only
    /// takes even ones). `paint(first_row, rows, pixels)` is called for one band of rows
    /// after another; it fills `pixels` with `w * rows` pixels, two bytes each: RGB565,
    /// high byte first.
    pub fn paint(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        mut paint: impl FnMut(i32, i32, &mut [u8]),
    ) -> Result<()> {
        if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > SCREEN || y + h > SCREEN || (x | y | w | h) & 1 != 0 {
            bail!("a rectangle the screen can't take: {x},{y} {w}x{h}");
        }
        let mut row = y;
        while row < y + h {
            let rows = BAND_ROWS.min(y + h - row);
            let band = unsafe { core::slice::from_raw_parts_mut(self.bands[self.next], (w * rows * 2) as usize) };
            paint(row, rows, band);
            esp!(unsafe {
                esp_lcd_panel_draw_bitmap(self.panel, x, row, x + w, row + rows, band.as_ptr() as *const c_void)
            })?;
            self.next ^= 1;
            row += rows;
        }
        Ok(())
    }

    /// 0 (dark) to 100.
    pub fn brightness(&mut self, percent: u8) -> Result<()> {
        let value = [(percent.min(100) as u32 * 255 / 100) as u8];
        // On four data lines a command travels as: 0x02 (write), then the command, shifted.
        let command = (0x02 << 24) | (0x51 << 8);
        esp!(unsafe { esp_lcd_panel_io_tx_param(self.io, command, value.as_ptr() as *const c_void, 1) })?;
        Ok(())
    }

    /// Switch the picture off or on. Off, the screen draws next to no power.
    pub fn power(&mut self, on: bool) -> Result<()> {
        esp!(unsafe { esp_lcd_panel_disp_on_off(self.panel, on) })?;
        Ok(())
    }
}
