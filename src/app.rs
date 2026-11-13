//! Your features go here.
//!
//! The badge calls `on_event` whenever something happens (see `Event` in badge.rs for the
//! list) and hands over a `Badge` to answer with: `badge.say("...")` for text under the
//! eyes, `badge.face` for the eyes, `badge.battery`, `badge.ip`, `badge.tilt`.
//! Keep what you need between events in the `App` struct.
//!
//! What is here now is a small tour of the hardware, there to be replaced.

use crate::badge::{Badge, Event};

pub struct App {
    pets: u32,
}

impl App {
    pub fn new() -> Self {
        App { pets: 0 }
    }

    pub fn on_event(&mut self, event: Event, badge: &mut Badge) {
        match event {
            Event::Start => badge.say("hello"),

            // Every fifth pet gets a word.
            Event::Pet => {
                self.pets += 1;
                if self.pets % 5 == 0 {
                    badge.say(&format!("{} pets!", self.pets));
                }
            }

            // BOOT: how the badge is doing.
            Event::ButtonUp { held_ms } if held_ms < 1000 => {
                let power = match (badge.battery.charging, badge.battery.on_usb) {
                    (true, _) => "charging",
                    (false, true) => "on USB",
                    (false, false) => "on battery",
                };
                let net = badge.ip.clone().unwrap_or_else(|| "no Wi-Fi".into());
                badge.say_for(&format!("{}% {} {}", badge.battery.percent, power, net), 4000);
            }

            Event::Shake => {
                badge.face.startle();
                badge.say("whoa!");
            }

            // Text sent over Bluetooth shows on the screen.
            Event::Message(text) => badge.say_for(&text, 6000),

            _ => {}
        }
    }
}
