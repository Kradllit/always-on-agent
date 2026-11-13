//! The board's I2C bus: the power chip, the touch controller, the motion sensor and the
//! two audio chips all hang off it.
//!
//! This wraps ESP-IDF's I2C master driver directly, because the audio component needs the
//! same bus handle (`I2c::handle`).

use core::ptr::null_mut;

use anyhow::Result;
use esp_idf_svc::sys::*;

const SPEED_HZ: u32 = 400_000;
const TIMEOUT_MS: i32 = 50;

pub struct I2c {
    bus: i2c_master_bus_handle_t,
    devices: Vec<(u8, i2c_master_dev_handle_t)>,
}

impl I2c {
    pub fn new(sda: i32, scl: i32) -> Result<Self> {
        let mut config: i2c_master_bus_config_t = unsafe { core::mem::zeroed() };
        config.i2c_port = 0;
        config.sda_io_num = sda;
        config.scl_io_num = scl;
        config.__bindgen_anon_1.clk_source = soc_periph_i2c_clk_src_t_I2C_CLK_SRC_DEFAULT;
        config.glitch_ignore_cnt = 7;
        config.flags.set_enable_internal_pullup(1);
        let mut bus: i2c_master_bus_handle_t = null_mut();
        esp!(unsafe { i2c_new_master_bus(&config, &mut bus) })?;
        Ok(I2c { bus, devices: Vec::new() })
    }

    /// The driver's own handle, for C components that share the bus.
    pub fn handle(&self) -> i2c_master_bus_handle_t {
        self.bus
    }

    fn device(&mut self, address: u8) -> Result<i2c_master_dev_handle_t> {
        if let Some(&(_, device)) = self.devices.iter().find(|(a, _)| *a == address) {
            return Ok(device);
        }
        let mut config: i2c_device_config_t = unsafe { core::mem::zeroed() };
        config.dev_addr_length = i2c_addr_bit_len_t_I2C_ADDR_BIT_LEN_7;
        config.device_address = address as u16;
        config.scl_speed_hz = SPEED_HZ;
        let mut device: i2c_master_dev_handle_t = null_mut();
        esp!(unsafe { i2c_master_bus_add_device(self.bus, &config, &mut device) })?;
        self.devices.push((address, device));
        Ok(device)
    }

    /// Whether a chip answers at this address.
    pub fn probe(&mut self, address: u8) -> bool {
        unsafe { i2c_master_probe(self.bus, address as u16, TIMEOUT_MS) == ESP_OK }
    }

    pub fn write(&mut self, address: u8, bytes: &[u8]) -> Result<()> {
        let device = self.device(address)?;
        esp!(unsafe { i2c_master_transmit(device, bytes.as_ptr(), bytes.len(), TIMEOUT_MS) })?;
        Ok(())
    }

    pub fn read(&mut self, address: u8, into: &mut [u8]) -> Result<()> {
        let device = self.device(address)?;
        esp!(unsafe { i2c_master_receive(device, into.as_mut_ptr(), into.len(), TIMEOUT_MS) })?;
        Ok(())
    }

    /// Write `bytes` (usually a register number), then read `into`, in one exchange.
    pub fn write_read(&mut self, address: u8, bytes: &[u8], into: &mut [u8]) -> Result<()> {
        let device = self.device(address)?;
        esp!(unsafe {
            i2c_master_transmit_receive(device, bytes.as_ptr(), bytes.len(), into.as_mut_ptr(), into.len(), TIMEOUT_MS)
        })?;
        Ok(())
    }
}
