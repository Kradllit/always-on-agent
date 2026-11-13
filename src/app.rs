//! Your features go here.
//!
//! The badge calls `on_event` whenever something happens (see `Event` in badge.rs for the
//! list) and hands over a `Badge` to answer with: `badge.say("...")` for text under the
//! eyes, `badge.face` for the eyes, `badge.sound` for the speaker and the microphone,
//! `badge.battery`, `badge.ip`, `badge.tilt`.
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

            // BOOT held for a second: record three seconds and play them back.
            Event::ButtonUp { held_ms } if held_ms >= 800 => {
                badge.sound.beep(660, 80);
                badge.sound.listen(3000);
                badge.say_for("listening", 3200);
            }
            Event::Heard(recording) => {
                badge.say(&format!("heard {:.0} s, loudest {}%", recording.seconds(), recording.loudest()));
                badge.sound.play(recording.samples);
            }

            // BOOT pressed: how the badge is doing.
            Event::ButtonUp { .. } => {
                badge.sound.beep(880, 60);
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
