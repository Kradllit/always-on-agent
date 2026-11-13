//! The Waveshare ESP32-S3-Touch-AMOLED-1.75C: which pin goes where.
//!
//! One I2C bus carries the power chip, the touch controller, the motion sensor and the
//! audio chips. The screen has its own SPI bus with four data lines.

// I2C bus 0, 400 kHz: SDA is GPIO 15, SCL is GPIO 14 (main.rs hands those pins over).

/// AXP2101 power chip: battery, charging, the power rails, the PWR button.
pub const PMIC_ADDR: u8 = 0x34;
/// CST9217 touch controller.
pub const TOUCH_ADDR: u8 = 0x5A;
// Its reset line is GPIO 2 (main.rs hands that pin over).
/// Low while a finger is on the screen.
#[allow(dead_code)]
pub const TOUCH_INT: i32 = 11;

/// The screen: a round 466 x 466 AMOLED behind a CO5300 driver chip.
pub const SCREEN: i32 = 466;
pub const LCD_CS: i32 = 12;
pub const LCD_CLK: i32 = 38;
pub const LCD_DATA: [i32; 4] = [4, 5, 6, 7];
pub const LCD_RESET: i32 = 1;

// The BOOT button is GPIO 0, low when pressed (main.rs hands that pin over).

// On the board and not used yet (the team's to pick up):
//   QMI8658 gyroscope          I2C 0x6B (its accelerometer is in use: motion.rs)
//   ES8311 speaker codec       I2C 0x18, amplifier enable GPIO 46
//   ES7210 microphones         I2C 0x40
//   I2S audio                  MCLK 16, WS 45, BCLK 9, DIN 10, DOUT 8
//   Screen tearing signal      GPIO 13
