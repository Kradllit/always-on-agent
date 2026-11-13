//! Your features go here.
//!
//! The badge calls `on_event` whenever something happens (see `Event` in badge.rs for the
//! list) and hands over a `Badge` to answer with: `badge.say("...")` for text under the
//! eyes, `badge.face` for the eyes, `badge.sound` for the speaker and the microphone,
//! `badge.battery`, `badge.ip`, `badge.tilt`.
//! Keep what you need between events in the `App` struct.
//!
//! What is here now is a tour of the hardware: whatever the badge senses, it says so under
//! the eyes, so anyone holding it can see what it is able to notice. It is there to be
//! replaced.
//!
//!   touch the screen       "touch 233, 120", following the finger
//!   tap                    "tap"
//!   stroke (pet)           "petted 3 times"
//!   press BOOT             "button pressed", then the battery and the Wi-Fi address,
//!                          then "tilt 12°, -34°" following the badge for ten seconds
//!   hold BOOT a second     records three seconds and plays them back
//!   shake                  "shake!"
//!   make a noise           "mic 23% |||||"
//!   text over Bluetooth    the text

use crate::badge::{Badge, Event};

pub struct App {
    /// Until then, what is on the screen stays: the running readouts (tilt, microphone)
    /// wait their turn.
    hold_until: u64,
    touching: bool,
    /// The tilt readout runs until then. A badge in a hand never stops moving, so it is
    /// shown only when asked for (a press of BOOT), not all the time.
    tilt_until: u64,
    recording: bool,
}

impl App {
    pub fn new() -> Self {
        App { hold_until: 0, touching: false, tilt_until: 0, recording: false }
    }

    /// Say something that should stay readable for a moment.
    fn announce(&mut self, badge: &mut Badge, text: &str, ms: u64) {
        badge.say_for(text, ms);
        self.hold_until = badge.now + ms.min(1500);
    }

    fn show_tilt(&self, badge: &mut Badge) {
        if badge.now < self.hold_until || badge.now >= self.tilt_until || self.touching {
            return;
        }
        let [x, y, z] = badge.tilt;
        let (side, front) = (x.atan2(z).to_degrees(), y.atan2(z).to_degrees());
        badge.say_for(&format!("tilt {side:.0}\u{b0}, {front:.0}\u{b0}"), 1500);
    }

    pub fn on_event(&mut self, event: Event, badge: &mut Badge) {
        let free = badge.now >= self.hold_until;
        match event {
            Event::Start => {
                badge.sound.meter(true);
                self.announce(badge, "hello", 2000);
            }

            Event::TouchDown { x, y } | Event::TouchMove { x, y } => {
                self.touching = true;
                if free {
                    badge.say_for(&format!("touch {x}, {y}"), 1500);
                }
            }
            Event::TouchUp => self.touching = false,
            Event::Tap => self.announce(badge, "tap", 1200),
            Event::Pet => {
                let pets = badge.face.pets();
                let text = if pets == 1 { "petted once".to_string() } else { format!("petted {pets} times") };
                self.announce(badge, &text, 2000);
            }

            Event::ButtonDown => self.announce(badge, "button pressed", 1500),
            // Held for a second: record three seconds and play them back.
            Event::ButtonUp { held_ms } if held_ms >= 800 => {
                self.recording = true;
                badge.sound.beep(660, 80);
                badge.sound.listen(3000);
                self.announce(badge, "recording 3 s", 3300);
                self.hold_until = badge.now + 3300;
            }
            // Pressed: how the badge is doing, then which way it is leaning.
            Event::ButtonUp { .. } => {
                badge.sound.beep(880, 60);
                let power = match (badge.battery.charging, badge.battery.on_usb) {
                    (true, _) => "charging",
                    (false, true) => "on USB",
                    (false, false) => "on battery",
                };
                let net = badge.ip.clone().unwrap_or_else(|| "no Wi-Fi".into());
                let text = format!("{}% {} {}", badge.battery.percent, power, net);
                self.announce(badge, &text, 4000);
                self.hold_until = badge.now + 4000;
                self.tilt_until = badge.now + 14_000;
            }
            Event::Heard(recording) => {
                self.recording = false;
                let text = format!("heard {:.0} s, loudest {}%", recording.seconds(), recording.loudest());
                self.announce(badge, &text, 3500);
                badge.sound.play(recording.samples);
            }

            Event::Shake => {
                badge.face.startle();
                self.announce(badge, "shake!", 1500);
            }
            Event::Tilt { .. } => self.show_tilt(badge),

            // The microphone gets the caption when nothing else wants it.
            Event::Loudness(level) => {
                let tilting = badge.now < self.tilt_until;
                if free && !tilting && !self.touching && !self.recording && level >= 6 {
                    let bar = "|".repeat((level as usize / 4).clamp(1, 16));
                    badge.say_for(&format!("mic {level}% {bar}"), 600);
                }
            }

            // Text sent over Bluetooth shows on the screen.
            Event::Message(text) => self.announce(badge, &text, 6000),

            // A badge lying still sends no tilt events: keep its readout on the screen.
            Event::Second => self.show_tilt(badge),
        }
    }
}
