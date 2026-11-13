//! The AXP2101 power chip: it feeds the board, charges the battery and knows how full it is.

use anyhow::Result;
use esp_idf_svc::hal::delay::BLOCK;
use esp_idf_svc::hal::i2c::I2cDriver;

use crate::board::PMIC_ADDR;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Battery {
    /// 0 to 100.
    pub percent: u8,
    pub charging: bool,
    /// Power is coming in over USB.
    pub on_usb: bool,
}

fn write(i2c: &mut I2cDriver, reg: u8, value: u8) -> Result<()> {
    Ok(i2c.write(PMIC_ADDR, &[reg, value], BLOCK)?)
}

fn read(i2c: &mut I2cDriver, reg: u8) -> Result<u8> {
    let mut value = [0u8];
    i2c.write_read(PMIC_ADDR, &[reg], &mut value, BLOCK)?;
    Ok(value[0])
}

/// Set the board's power up. Call once, before anything else on the board is used.
pub fn init(i2c: &mut I2cDriver) -> Result<()> {
    write(i2c, 0x22, 0b110)?; // holding PWR switches the badge off
    write(i2c, 0x27, 0x10)?; // ...after 4 seconds

    write(i2c, 0x80, 0x01)?; // of the DC rails, only DC1 on
    write(i2c, 0x90, 0x00)?; // all LDOs off
    write(i2c, 0x91, 0x00)?;
    write(i2c, 0x82, ((3300 - 1500) / 100) as u8)?; // DC1 at 3.3 V: the chip and the screen
    write(i2c, 0x92, ((3300 - 500) / 100) as u8)?; // ALDO1 at 3.3 V
    write(i2c, 0x90, 0x01)?; // ALDO1 on (the microphones)

    write(i2c, 0x64, 0x02)?; // charge up to 4.1 V
    write(i2c, 0x61, 0x02)?; // precharge at 50 mA
    write(i2c, 0x62, 0x08)?; // charge at 200 mA
    write(i2c, 0x63, 0x01)?; // stop charging below 25 mA
    Ok(())
}

pub fn battery(i2c: &mut I2cDriver) -> Result<Battery> {
    let status = read(i2c, 0x01)?;
    Ok(Battery {
        percent: read(i2c, 0xA4)?.min(100),
        charging: (status >> 5) & 0b11 == 1,
        on_usb: read(i2c, 0x00)? & 0b0010_0000 != 0,
    })
}

/// Switch the badge off. PWR switches it on again.
#[allow(dead_code)]
pub fn off(i2c: &mut I2cDriver) -> Result<()> {
    let value = read(i2c, 0x10)?;
    write(i2c, 0x10, value | 0x01)
}
