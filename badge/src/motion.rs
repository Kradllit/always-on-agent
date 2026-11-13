//! The QMI8658 motion sensor: which way is down, and whether the badge is being shaken.

use crate::bus::I2c;

const COUNTS_PER_G: f32 = 4096.0; // at +-8 g
/// A shake is three hard jolts (this much change between two readings, in g) within the
/// window; after one, nothing counts for a moment.
const JOLT_G: f32 = 1.2;
const JOLTS: u8 = 3;
const WINDOW_MS: u64 = 700;
const QUIET_AFTER_MS: u64 = 1500;

pub struct Motion {
    address: Option<u8>,
    last: [f32; 3],
    settling: u8,
    jolts: u8,
    first_jolt: u64,
    quiet_until: u64,
}

impl Motion {
    /// Finds and starts the sensor. A badge without one (or one that doesn't answer) just
    /// never reports anything.
    pub fn new(i2c: &mut I2c) -> Self {
        let mut motion = Motion { address: None, last: [0.0; 3], settling: 10, jolts: 0, first_jolt: 0, quiet_until: 0 };
        for address in [0x6B, 0x6A] {
            let mut who = [0u8];
            let found = i2c.probe(address) && i2c.write_read(address, &[0x00], &mut who).is_ok() && who[0] == 0x05;
            // Registers: 0x02 read several in a row, 0x03 the accelerometer at +-8 g, 0x08 switch it on.
            if found && [[0x02, 0x40], [0x03, 0x27], [0x08, 0x01]].iter().all(|w| i2c.write(address, w).is_ok()) {
                motion.address = Some(address);
                break;
            }
        }
        if motion.address.is_none() {
            log::warn!("motion sensor: not found");
        }
        motion
    }

    /// Call every pass of the main loop. Returns the pull on each axis in g (at rest, the
    /// three together are 1 g pointing down) and whether the badge was just shaken.
    pub fn poll(&mut self, i2c: &mut I2c, now: u64) -> Option<([f32; 3], bool)> {
        let address = self.address?;
        let mut raw = [0u8; 6];
        i2c.write_read(address, &[0x35], &mut raw).ok()?;
        let mut g = [0.0f32; 3];
        let mut change = 0.0;
        for i in 0..3 {
            g[i] = i16::from_le_bytes([raw[2 * i], raw[2 * i + 1]]) as f32 / COUNTS_PER_G;
            change += (g[i] - self.last[i]) * (g[i] - self.last[i]);
        }
        self.last = g;
        if self.settling > 0 {
            self.settling -= 1;
            return Some((g, false));
        }
        if now < self.quiet_until || change.sqrt() < JOLT_G {
            return Some((g, false));
        }
        if self.jolts == 0 || now - self.first_jolt > WINDOW_MS {
            self.jolts = 0;
            self.first_jolt = now;
        }
        self.jolts += 1;
        if self.jolts < JOLTS {
            return Some((g, false));
        }
        self.jolts = 0;
        self.quiet_until = now + QUIET_AFTER_MS;
        Some((g, true))
    }
}
