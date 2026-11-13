//! The face: two white blocks on black that blink, glance around, follow a finger and
//! enjoy being petted.
//!
//! Nothing here touches hardware. `Face::update` takes the time and where the finger is
//! and moves the face along; `Face::look` says what the eyes look like right now; `paint`
//! turns a look into pixels. That makes this the easy file to play in.
//!
//! What a touch does:
//!   finger down          the eyes look at the finger
//!   a short tap          the eyes widen for a moment, then blink
//!   stroking (petting)   the eyes curve into happy arcs, turn pink and bounce, and stay
//!                        happy a little while after the finger lifts

const CENTER: f32 = 233.0;
const EYE_W: f32 = 96.0;
const EYE_H: f32 = 132.0;
/// From the middle of the screen to the middle of each eye.
const EYE_APART: f32 = 78.0;
/// How far a finger travels on the screen before it counts as petting, in pixels.
const PET_PATH: f32 = 90.0;
const PINK: [f32; 3] = [255.0, 140.0, 175.0];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Eye {
    pub cx: f32,
    pub cy: f32,
    pub w: f32,
    pub h: f32,
    /// 0 is the plain block; 1 is the happy arc.
    pub smile: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Look {
    pub eyes: [Eye; 2],
    pub color: [u8; 3],
}

/// What a finger just did, as far as the face can tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gesture {
    /// A short touch that didn't move.
    Tap,
    /// The finger has stroked far enough to count as petting. Once per stroke.
    Pet,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    Calm,
    Curious,
    Happy,
    Tired,
}

impl Mood {
    pub fn name(self) -> &'static str {
        match self {
            Mood::Calm => "calm",
            Mood::Curious => "curious",
            Mood::Happy => "happy",
            Mood::Tired => "tired",
        }
    }
}

pub struct Face {
    now: u64,
    gaze: (f32, f32),
    joy: f32,
    wide: f32,
    finger: Option<(i32, i32)>,
    down_at: u64,
    path: f32,
    petting: bool,
    pets: u32,
    joy_until: u64,
    wide_until: u64,
    blink_from: u64,
    blink_next: u64,
    glance: (f32, f32),
    glance_next: u64,
    tired: bool,
    random: u32,
}

impl Face {
    pub fn new() -> Self {
        Face {
            now: 0,
            gaze: (0.0, 0.0),
            joy: 0.0,
            wide: 0.0,
            finger: None,
            down_at: 0,
            path: 0.0,
            petting: false,
            pets: 0,
            joy_until: 0,
            wide_until: 0,
            blink_from: 0,
            blink_next: 1500,
            glance: (0.0, 0.0),
            glance_next: 3000,
            tired: false,
            random: 0x2F6E_2B1D,
        }
    }

    /// How many times the badge has been petted since it started.
    pub fn pets(&self) -> u32 {
        self.pets
    }

    pub fn mood(&self) -> Mood {
        if self.joy > 0.5 {
            Mood::Happy
        } else if self.finger.is_some() {
            Mood::Curious
        } else if self.tired {
            Mood::Tired
        } else {
            Mood::Calm
        }
    }

    /// A low battery makes the eyes droop.
    pub fn set_tired(&mut self, tired: bool) {
        self.tired = tired;
    }

    /// Be happy for a while, as after petting (for the Bluetooth "pet" command).
    pub fn pet(&mut self) {
        self.pets += 1;
        self.joy_until = self.now + 2500;
    }

    pub fn blink(&mut self) {
        self.blink_next = self.now;
    }

    /// Widen the eyes for a moment, as a tap does.
    pub fn startle(&mut self) {
        self.wide_until = self.now + 450;
        self.blink_next = self.now + 450;
    }

    fn next_random(&mut self) -> u32 {
        // xorshift: plenty for blinks and glances
        self.random ^= self.random << 13;
        self.random ^= self.random >> 17;
        self.random ^= self.random << 5;
        self.random
    }

    /// Move the face along to `now` (milliseconds since start). `finger` is where the
    /// screen is being touched, if it is. Returns what the finger just did, if anything.
    pub fn update(&mut self, now: u64, finger: Option<(i32, i32)>) -> Option<Gesture> {
        let dt = (now.saturating_sub(self.now) as f32 / 1000.0).min(0.1);
        self.now = now;
        let mut gesture = None;

        match (self.finger, finger) {
            (None, Some(_)) => {
                self.down_at = now;
                self.path = 0.0;
                self.petting = false;
            }
            (Some(was), Some(is)) => {
                let (dx, dy) = ((is.0 - was.0) as f32, (is.1 - was.1) as f32);
                self.path += (dx * dx + dy * dy).sqrt();
                if !self.petting && self.path > PET_PATH {
                    self.petting = true;
                    self.pets += 1;
                    gesture = Some(Gesture::Pet);
                }
            }
            (Some(_), None) => {
                if self.petting {
                    self.joy_until = now + 1800;
                } else if now - self.down_at < 300 && self.path < 25.0 {
                    self.startle();
                    gesture = Some(Gesture::Tap);
                }
                self.petting = false;
            }
            (None, None) => {}
        }
        self.finger = finger;

        // Where the eyes want to look: at the finger, or now and then somewhere else.
        if finger.is_none() && now >= self.glance_next {
            let r = self.next_random();
            self.glance = if r % 10 < 4 {
                (0.0, 0.0)
            } else {
                (((r >> 8) % 53) as f32 - 26.0, ((r >> 16) % 29) as f32 - 14.0)
            };
            self.glance_next = now + 1800 + (self.next_random() % 3200) as u64;
        }
        let target = match finger {
            Some((x, y)) => ((x as f32 - CENTER) / CENTER * 40.0, (y as f32 - CENTER) / CENTER * 30.0),
            None => self.glance,
        };
        let ease = |rate: f32| 1.0 - (-dt * rate).exp();
        self.gaze.0 += (target.0 - self.gaze.0) * ease(12.0);
        self.gaze.1 += (target.1 - self.gaze.1) * ease(12.0);

        let happy = self.petting || now < self.joy_until;
        self.joy += ((happy as u8 as f32) - self.joy) * ease(if happy { 9.0 } else { 3.5 });
        let startled = now < self.wide_until;
        self.wide += ((startled as u8 as f32) - self.wide) * ease(16.0);

        if now >= self.blink_next {
            self.blink_from = now;
            self.blink_next = now + 2500 + (self.next_random() % 3500) as u64;
        }
        gesture
    }

    /// What the face looks like right now.
    pub fn look(&self) -> Look {
        // A blink: 80 ms to close, 120 ms to open. Happy eyes don't blink.
        let since = self.now.saturating_sub(self.blink_from) as f32;
        let mut open = if self.now < 300 || since >= 200.0 {
            1.0
        } else if since < 80.0 {
            1.0 - since / 80.0
        } else {
            (since - 80.0) / 120.0
        };
        open = open + (1.0 - open) * self.joy;

        let w = EYE_W * (1.0 + 0.10 * self.wide + 0.06 * self.joy);
        let mut h = EYE_H * (1.0 + 0.18 * self.wide) * (1.0 - 0.12 * self.joy);
        if self.tired {
            h *= 0.6;
        }
        h = (h * open).max(10.0);
        let bounce = (self.now as f32 / 1000.0 * 10.0).sin() * 5.0 * self.joy;
        let cy = CENTER + self.gaze.1 + bounce + if self.tired { 12.0 } else { 0.0 };
        let eye = |side: f32| Eye { cx: CENTER + side * EYE_APART + self.gaze.0, cy, w, h, smile: self.joy };
        let mix = |i: usize| (255.0 + (PINK[i] - 255.0) * self.joy) as u8;
        Look { eyes: [eye(-1.0), eye(1.0)], color: [mix(0), mix(1), mix(2)] }
    }
}

/// The rectangle a look covers: (left, top, right, bottom), right and bottom not included.
pub fn bounds(look: &Look) -> (i32, i32, i32, i32) {
    let mut b = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for eye in &look.eyes {
        b.0 = b.0.min((eye.cx - eye.w / 2.0).floor() as i32 - 2);
        b.1 = b.1.min((eye.cy - eye.h / 2.0).floor() as i32 - 2);
        b.2 = b.2.max((eye.cx + eye.w / 2.0).ceil() as i32 + 2);
        b.3 = b.3.max((eye.cy + eye.h / 2.0).ceil() as i32 + 2);
    }
    b
}

/// Paint the rows `y0 .. y0 + rows` of a look, from column `x0`, `w` pixels wide, into
/// `out`: two bytes a pixel, RGB565 with the high byte first. Edges are smoothed.
pub fn paint(look: &Look, x0: i32, y0: i32, w: i32, rows: i32, out: &mut [u8]) {
    out.fill(0);
    let [red, green, blue] = look.color.map(|c| c as f32);
    for eye in &look.eyes {
        let (half_w, half_h) = (eye.w / 2.0, eye.h / 2.0);
        // A happy eye is an arc: its top corners round off, and a big circle rising from
        // below cuts the bottom away.
        let round = (eye.smile * half_w * 0.9).min(half_h);
        let cut_r = eye.w * 0.95;
        let cut_cy = eye.cy + half_h + cut_r - eye.smile * eye.h * 0.62;
        let smiling = eye.smile > 0.01;

        let left = ((eye.cx - half_w).floor() as i32 - 1).max(x0);
        let right = ((eye.cx + half_w).ceil() as i32 + 1).min(x0 + w - 1);
        let top = ((eye.cy - half_h).floor() as i32 - 1).max(y0);
        let bottom = ((eye.cy + half_h).ceil() as i32 + 1).min(y0 + rows - 1);
        for y in top..=bottom {
            let py = y as f32 + 0.5;
            let qy = (py - eye.cy).abs() - (half_h - round);
            for x in left..=right {
                let px = x as f32 + 0.5;
                // How far outside the (rounded) block this pixel is; negative inside.
                let qx = (px - eye.cx).abs() - (half_w - round);
                let outside = if qx > 0.0 && qy > 0.0 { (qx * qx + qy * qy).sqrt() } else { qx.max(qy) } - round;
                let mut cover = (0.5 - outside).clamp(0.0, 1.0);
                if cover > 0.0 && smiling {
                    let (dx, dy) = (px - eye.cx, py - cut_cy);
                    let d2 = dx * dx + dy * dy;
                    if d2 <= (cut_r - 1.0) * (cut_r - 1.0) {
                        cover = 0.0;
                    } else if d2 < (cut_r + 1.0) * (cut_r + 1.0) {
                        cover *= (d2.sqrt() - cut_r + 0.5).clamp(0.0, 1.0);
                    }
                }
                if cover <= 0.0 {
                    continue;
                }
                let (r, g, b) = ((red * cover) as u16, (green * cover) as u16, (blue * cover) as u16);
                let pixel = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
                let at = (((y - y0) * w + (x - x0)) * 2) as usize;
                out[at] = (pixel >> 8) as u8;
                out[at + 1] = pixel as u8;
            }
        }
    }
}
