//! What an app sees of the badge: the events it gets and the things it can do.
//!
//! main.rs reads the hardware and turns what happens into `Event`s; app.rs answers them
//! through a `Badge`. A feature should need nothing but these two types.

// Not everything here is used by the starting app; it is here for the next one.
#![allow(dead_code)]

use crate::eyes::Face;
use crate::power::Battery;
use crate::sound::{Recording, Sound};
use crate::text::Caption;

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// Once, when the badge has started.
    Start,
    /// A finger landed on the screen, at this pixel (0,0 is top left, 466 across).
    TouchDown { x: i32, y: i32 },
    /// The finger lifted.
    TouchUp,
    /// A short touch that didn't move. The eyes have already widened.
    Tap,
    /// The finger has stroked the screen far enough to count as petting. Once per stroke;
    /// the eyes are already happy.
    Pet,
    /// BOOT went down.
    ButtonDown,
    /// BOOT came up, after this long.
    ButtonUp { held_ms: u64 },
    /// The badge was shaken: three hard jolts.
    Shake,
    /// A line of text written to the badge over Bluetooth that isn't a built-in command.
    Message(String),
    /// A recording asked for with `badge.sound.listen(ms)` is ready.
    Heard(Recording),
    /// Once a second.
    Second,
}

pub struct Badge<'a> {
    /// The eyes. See eyes.rs for what they can do (`pet`, `blink`, `startle`, ...).
    pub face: &'a mut Face,
    pub(crate) caption: &'a mut Caption,
    /// The speaker and the microphone: `beep`, `play`, `listen`, `volume`. See sound.rs.
    pub sound: Sound,
    /// Milliseconds since the badge started.
    pub now: u64,
    pub battery: Battery,
    /// The badge's address on Wi-Fi; None while it is offline.
    pub ip: Option<String>,
    /// The pull on each axis, in g: at rest the three together are 1 g, pointing down.
    pub tilt: [f32; 3],
}

impl Badge<'_> {
    /// Show a line or two of text under the eyes for three seconds.
    pub fn say(&mut self, text: &str) {
        self.say_for(text, 3000);
    }

    /// Show text under the eyes for `ms` milliseconds.
    pub fn say_for(&mut self, text: &str, ms: u64) {
        self.caption.show(text, Some(self.now + ms));
    }

    /// Show text under the eyes until something else is said.
    pub fn say_and_keep(&mut self, text: &str) {
        self.caption.show(text, None);
    }

    /// Take the text away.
    pub fn hush(&mut self) {
        self.caption.show("", None);
    }
}
