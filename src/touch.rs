//! The CST9217 touch controller: where the finger is, if one is on the screen.

use anyhow::Result;
use esp_idf_svc::hal::delay::{FreeRtos, BLOCK};
use esp_idf_svc::hal::gpio::{AnyOutputPin, Output, PinDriver};
use esp_idf_svc::hal::i2c::I2cDriver;

use crate::board::{SCREEN, TOUCH_ADDR};

pub struct Touch {
    reset: PinDriver<'static, Output>,
}

impl Touch {
    pub fn new(reset: AnyOutputPin<'static>) -> Result<Self> {
        let mut touch = Touch { reset: PinDriver::output(reset)? };
        touch.restart()?;
        Ok(touch)
    }

    fn restart(&mut self) -> Result<()> {
        self.reset.set_low()?;
        FreeRtos::delay_ms(10);
        self.reset.set_high()?;
        FreeRtos::delay_ms(50);
        Ok(())
    }

    /// The finger's place on the screen in pixels (0,0 is top left), or None.
    /// A read the controller answers wrongly (it does now and then) counts as no finger.
    pub fn read(&mut self, i2c: &mut I2cDriver) -> Option<(i32, i32)> {
        let mut data = [0u8; 10];
        i2c.write(TOUCH_ADDR, &[0xD0, 0x00], BLOCK).ok()?;
        FreeRtos::delay_ms(2);
        i2c.read(TOUCH_ADDR, &mut data, BLOCK).ok()?;
        // 0xAB marks a real answer; the low bits of byte 5 count the fingers; 0x06 is "down".
        if data[6] != 0xAB || data[5] & 0x7F == 0 || data[0] & 0x0F != 0x06 {
            return None;
        }
        let x = ((data[1] as i32) << 4) | (data[3] as i32 >> 4);
        let y = ((data[2] as i32) << 4) | (data[3] as i32 & 0x0F);
        // The controller sits upside down relative to the screen.
        Some(((SCREEN - 1 - x).clamp(0, SCREEN - 1), (SCREEN - 1 - y).clamp(0, SCREEN - 1)))
    }
}
