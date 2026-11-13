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
//!   press BOOT             "button pressed", then the battery and the Wi-Fi address
//!   hold BOOT a second     records three seconds and plays them back
//!   shake                  "shake!"
//!   turn the badge         "tilt 12°, -34°" (a real turn; a hand's small movements don't count)
//!   make a noise           "mic 23% |||||"
//!   text over Bluetooth    the text

use crate::badge::{Badge, Event};

pub struct App {
    /// Until then, what is on the screen stays: the running readouts (tilt, microphone)
    /// wait their turn.
    hold_until: u64,
    touching: bool,
    /// Which way was down when the tilt was last shown, and when that was. A badge in a
    /// hand never stops moving, so the tilt is shown only once it has turned this far from
    /// there; anything less leaves the caption to the microphone.
    tilt_shown: [f32; 3],
    tilt_at: u64,
    recording: bool,
}

impl App {
    pub fn new() -> Self {
        App { hold_until: 0, touching: false, tilt_shown: [0.0, 0.0, 1.0], tilt_at: 0, recording: false }
    }

    /// Say something that should stay readable for a moment.
    fn announce(&mut self, badge: &mut Badge, text: &str, ms: u64) {
        badge.say_for(text, ms);
        self.hold_until = badge.now + ms.min(1500);
    }

    /// Shows the tilt when the badge has turned at least `TURN` from where it was last shown.
    fn show_tilt(&mut self, badge: &mut Badge, pull: [f32; 3]) {
        const TURN: f32 = 15.0;
        let strength = (pull[0] * pull[0] + pull[1] * pull[1] + pull[2] * pull[2]).sqrt();
        if badge.now < self.hold_until || self.touching || strength < 0.5 {
            return;
        }
        let down = [pull[0] / strength, pull[1] / strength, pull[2] / strength];
        let same: f32 = (0..3).map(|i| down[i] * self.tilt_shown[i]).sum();
        if same > TURN.to_radians().cos() {
            return;
        }
        self.tilt_shown = down;
        self.tilt_at = badge.now;
        // Degrees to the side and to the front; 0, 0 is lying flat, face up.
        let (side, front) = (down[0].asin().to_degrees(), down[1].asin().to_degrees());
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
            // Pressed: how the badge is doing.
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
            Event::Tilt { x, y, z } => self.show_tilt(badge, [x, y, z]),

            // The microphone gets the caption when nothing else wants it.
            Event::Loudness(level) => {
                let turning = badge.now - self.tilt_at < 1000;
                if free && !turning && !self.touching && !self.recording && level >= 6 {
                    let bar = "|".repeat((level as usize / 4).clamp(1, 16));
                    badge.say_for(&format!("mic {level}% {bar}"), 600);
                }
            }

            // Text sent over Bluetooth shows on the screen.
            Event::Message(text) => self.announce(badge, &text, 6000),

            Event::Second => {}
        }
    }
}
