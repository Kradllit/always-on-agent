//! Basecamp badge: the starting firmware for the Waveshare ESP32-S3-Touch-AMOLED-1.75C.
//!
//! Two eyes on a black screen that blink, look around, follow a finger and enjoy being
//! petted. Around them: the battery, Wi-Fi, Bluetooth and a crash guard. Start in eyes.rs.
//!
//!   board.rs    which pin goes where
//!   power.rs    the power chip: rails, charging, battery level
//!   display.rs  the screen
//!   touch.rs    the touch controller
//!   eyes.rs     the face and what a touch does to it
//!   wifi.rs     joining the Wi-Fi built into the firmware
//!   ble.rs      Bluetooth: a status to read, a few commands to write
//!   guard.rs    safe mode after repeated crashes at start

mod ble;
mod board;
mod display;
mod eyes;
mod guard;
mod power;
mod touch;
mod wifi;

use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use esp_idf_svc::eventloop::EspSystemEventLoop;
use esp_idf_svc::hal::delay::FreeRtos;
use esp_idf_svc::hal::i2c::{I2cConfig, I2cDriver};
use esp_idf_svc::hal::peripherals::Peripherals;
use esp_idf_svc::hal::units::FromValueType;
use esp_idf_svc::nvs::EspDefaultNvsPartition;

use crate::board::SCREEN;
use crate::display::Display;
use crate::eyes::Face;
use crate::power::Battery;

/// What the badge would tell anyone who asks (over Bluetooth, for now).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Status {
    pub battery: Battery,
    /// The badge's address on Wi-Fi, once it is online.
    pub ip: Option<String>,
    pub mood: &'static str,
    pub pets: u32,
}

impl Status {
    pub fn json(&self) -> String {
        let ip = self.ip.as_deref().map(|ip| format!("\"{ip}\"")).unwrap_or_else(|| "null".into());
        format!(
            "{{\"battery\":{},\"charging\":{},\"usb\":{},\"ip\":{},\"mood\":\"{}\",\"pets\":{}}}",
            self.battery.percent, self.battery.charging, self.battery.on_usb, ip, self.mood, self.pets
        )
    }
}

/// What a phone can ask for over Bluetooth.
pub enum Command {
    Pet,
    Blink,
    Brightness(u8),
}

/// Screen brightness in use, and at rest. Percent.
const BRIGHT: u8 = 70;
const DIM: u8 = 12;
/// Untouched this long, the screen dims; this long, it switches off. A touch brings it back.
/// On USB power the screen dims but stays on.
const DIM_AFTER_MS: u64 = 30_000;
const OFF_AFTER_MS: u64 = 120_000;
/// Below this, on battery, the eyes droop.
const LOW_BATTERY: u8 = 15;

fn now_ms() -> u64 {
    (unsafe { esp_idf_svc::sys::esp_timer_get_time() } / 1000) as u64
}

#[derive(Clone, Copy, PartialEq)]
enum Screen {
    Bright,
    Dim,
    Off,
}

fn main() -> Result<()> {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    log::info!("basecamp badge, build {}", env!("BADGE_BUILD"));

    let nvs = EspDefaultNvsPartition::take()?;
    let mut guard = guard::Guard::start(nvs.clone())?;
    if guard.safe_mode() {
        // Nothing is switched on: the screen stays black and USB waits for a new firmware.
        loop {
            log::warn!("safe mode: this firmware crashed three times at start. Flash another build.");
            FreeRtos::delay_ms(5000);
        }
    }

    let peripherals = Peripherals::take()?;
    let events = EspSystemEventLoop::take()?;
    let pins = peripherals.pins;
    let mut i2c = I2cDriver::new(
        peripherals.i2c0,
        pins.gpio15,
        pins.gpio14,
        &I2cConfig::new().baudrate(400.kHz().into()),
    )?;

    // The power chip sometimes misses the first words after a restart: ask again before
    // giving up, and carry on either way (its rails keep what they had).
    for attempt in 1..=5 {
        match power::init(&mut i2c) {
            Ok(()) => break,
            Err(error) => {
                log::warn!("power chip, attempt {attempt}: {error}");
                FreeRtos::delay_ms(50);
            }
        }
    }

    let mut display = Display::new()?;
    let mut touch = touch::Touch::new(pins.gpio2.degrade_output())?;
    let mut face = Face::new();

    let status = Arc::new(Mutex::new(Status::default()));
    let (send_command, commands) = mpsc::channel::<Command>();
    if let Err(error) = wifi::start(peripherals.modem, events, nvs, status.clone()) {
        log::error!("Wi-Fi did not start: {error:?}");
    }
    if let Err(error) = ble::start(status.clone(), send_command) {
        log::error!("Bluetooth did not start: {error:?}");
    }

    let mut battery = Battery::default();
    let mut battery_read_at = 0u64;
    let mut touched_at = now_ms();
    let mut bright = BRIGHT;
    let mut screen = Screen::Off; // nothing shows until the first frame is on the screen
    let mut shown: Option<eyes::Look> = None;
    let mut said = String::new();

    loop {
        let now = now_ms();
        guard.tick(now);

        let finger = touch.read(&mut i2c);
        if finger.is_some() {
            touched_at = now;
        }
        for command in commands.try_iter() {
            touched_at = now;
            match command {
                Command::Pet => face.pet(),
                Command::Blink => face.blink(),
                Command::Brightness(percent) => {
                    bright = percent;
                    screen = Screen::Off; // set again below
                }
            }
        }

        if battery_read_at == 0 || now - battery_read_at >= 5000 {
            battery_read_at = now.max(1);
            match power::battery(&mut i2c) {
                Ok(read) => battery = read,
                Err(error) => log::warn!("battery: {error}"),
            }
            face.set_tired(!battery.on_usb && battery.percent < LOW_BATTERY);
        }

        // The screen rests when nobody touches the badge.
        let idle = now - touched_at;
        let want = if idle < DIM_AFTER_MS {
            Screen::Bright
        } else if idle < OFF_AFTER_MS || battery.on_usb {
            Screen::Dim
        } else {
            Screen::Off
        };

        face.update(now, finger);
        if want != Screen::Off {
            let look = face.look();
            if shown != Some(look) {
                // Repaint what the eyes covered before and what they cover now.
                let mut area = eyes::bounds(&look);
                if let Some(before) = &shown {
                    let b = eyes::bounds(before);
                    area = (area.0.min(b.0), area.1.min(b.1), area.2.max(b.2), area.3.max(b.3));
                }
                let x = area.0.max(0) & !1;
                let y = area.1.max(0) & !1;
                let w = ((area.2.min(SCREEN) + 1) & !1) - x;
                let h = ((area.3.min(SCREEN) + 1) & !1) - y;
                if let Err(error) = display.paint(x, y, w, h, |row, rows, band| eyes::paint(&look, x, row, w, rows, band)) {
                    log::warn!("screen: {error}");
                }
                shown = Some(look);
            }
        }
        if want != screen {
            let result = match want {
                Screen::Bright => display.power(true).and_then(|_| display.brightness(bright)),
                Screen::Dim => display.power(true).and_then(|_| display.brightness(DIM.min(bright))),
                Screen::Off => display.brightness(0).and_then(|_| display.power(false)),
            };
            if let Err(error) = result {
                log::warn!("screen: {error}");
            }
            screen = want;
        }

        {
            let mut status = status.lock().unwrap();
            status.battery = battery;
            status.mood = face.mood().name();
            status.pets = face.pets();
            let line = format!(
                "battery {}%{}, {}, mood {}, pets {}",
                battery.percent,
                if battery.charging { " charging" } else if battery.on_usb { " on USB" } else { "" },
                status.ip.as_deref().map(|ip| format!("Wi-Fi {ip}")).unwrap_or_else(|| "no Wi-Fi".into()),
                status.mood,
                status.pets
            );
            if line != said {
                log::info!("{line}");
                said = line;
            }
        }

        // About 30 frames a second while the screen is on; a slow watch for a touch when off.
        FreeRtos::delay_ms(if want == Screen::Off { 100 } else { 25 });
    }
}
