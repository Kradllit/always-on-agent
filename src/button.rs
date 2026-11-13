//! The BOOT button (the one that isn't PWR).

use anyhow::Result;
use esp_idf_svc::hal::gpio::{Input, InputPin, PinDriver, Pull};

pub enum Press {
    Down,
    Up { held_ms: u64 },
}

pub struct Button {
    pin: PinDriver<'static, Input>,
    down_since: Option<u64>,
}

impl Button {
    pub fn new(pin: impl InputPin + 'static) -> Result<Self> {
        Ok(Button { pin: PinDriver::input(pin, Pull::Up)?, down_since: None })
    }

    /// Call every pass of the main loop; that pace is also what steadies the contact.
    pub fn poll(&mut self, now: u64) -> Option<Press> {
        match (self.pin.is_low(), self.down_since) {
            (true, None) => {
                self.down_since = Some(now);
                Some(Press::Down)
            }
            (false, Some(since)) => {
                self.down_since = None;
                Some(Press::Up { held_ms: now - since })
            }
            _ => None,
        }
    }
}
