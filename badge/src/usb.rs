//! The USB link to a computer (the log and flashing travel over it).
//!
//! Now and then a restart leaves the computer with a dead link: the port is still listed,
//! but nothing answers, until the cable is pulled and put back. This watches for that from
//! the badge's side: when USB power is there but no computer is talking, the badge drops
//! off the bus for a moment and comes back, which is what replugging the cable does.

use esp_idf_svc::sys::{usb_serial_jtag_is_connected, DR_REG_USB_SERIAL_JTAG_BASE};

const CONF0: *mut u32 = (DR_REG_USB_SERIAL_JTAG_BASE + 0x18) as *mut u32;
const PAD_PULL_OVERRIDE: u32 = 1 << 8;
const DP_PULLUP: u32 = 1 << 9;
const DP_PULLDOWN: u32 = 1 << 10;

/// No computer for this long before the badge tries; then no more often than this.
const QUIET_MS: u64 = 8_000;
/// How long the badge stays off the bus.
const AWAY_MS: u64 = 400;

pub struct Usb {
    quiet_since: Option<u64>,
    away_until: Option<u64>,
    tries: u32,
}

impl Usb {
    pub fn new() -> Self {
        Usb { quiet_since: None, away_until: None, tries: 0 }
    }

    /// Call every pass of the main loop. `powered` is whether USB power is coming in.
    pub fn tick(&mut self, now: u64, powered: bool) {
        if let Some(until) = self.away_until {
            if now >= until {
                // Back to the chip's own handling of the lines: it shows up again.
                unsafe { CONF0.write_volatile(CONF0.read_volatile() & !PAD_PULL_OVERRIDE) };
                self.away_until = None;
                self.quiet_since = Some(now);
            }
            return;
        }
        if !powered || unsafe { usb_serial_jtag_is_connected() } {
            self.quiet_since = None;
            self.tries = 0;
            return;
        }
        let since = *self.quiet_since.get_or_insert(now);
        // A charger never talks: after a few tries, leave it be.
        if now - since >= QUIET_MS && self.tries < 5 {
            self.tries += 1;
            ::log::info!("USB: power but no computer talking; dropping off the bus and coming back (try {})", self.tries);
            unsafe {
                let value = CONF0.read_volatile();
                CONF0.write_volatile((value | PAD_PULL_OVERRIDE | DP_PULLDOWN) & !DP_PULLUP);
            }
            self.away_until = Some(now + AWAY_MS);
        }
    }
}
