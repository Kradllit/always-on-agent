//! Text on the screen: a caption of one or two lines under the eyes.
//!
//! The caption has its own strip of the screen, below where the eyes ever reach, so the
//! two never paint over each other. Plain ASCII and Latin-1 letters; no emoji.

use core::convert::Infallible;

use embedded_graphics_core::draw_target::DrawTarget;
use embedded_graphics_core::geometry::{OriginDimensions, Point, Size};
use embedded_graphics_core::pixelcolor::{IntoStorage, Rgb565, RgbColor};
use embedded_graphics_core::Pixel;
use u8g2_fonts::types::{FontColor, HorizontalAlignment, VerticalPosition};
use u8g2_fonts::{fonts, FontRenderer};

/// The caption's strip of the screen. All even, as the screen wants.
pub const X: i32 = 76;
pub const Y: i32 = 364;
pub const W: i32 = 314;
pub const H: i32 = 64;
/// The screen is round: the second line has less room than the first.
const LINE_WIDTH: [i32; 2] = [300, 250];
const LINE_BASELINE: [i32; 2] = [24, 54];

type Font = fonts::u8g2_font_helvB18_tf;

struct Canvas {
    pixels: Vec<u8>,
}

impl OriginDimensions for Canvas {
    fn size(&self) -> Size {
        Size::new(W as u32, H as u32)
    }
}

impl DrawTarget for Canvas {
    type Color = Rgb565;
    type Error = Infallible;

    fn draw_iter<I: IntoIterator<Item = Pixel<Rgb565>>>(&mut self, pixels: I) -> Result<(), Infallible> {
        for Pixel(at, color) in pixels {
            if at.x >= 0 && at.x < W && at.y >= 0 && at.y < H {
                let i = ((at.y * W + at.x) * 2) as usize;
                let raw = color.into_storage();
                self.pixels[i] = (raw >> 8) as u8;
                self.pixels[i + 1] = raw as u8;
            }
        }
        Ok(())
    }
}

pub struct Caption {
    text: String,
    until: Option<u64>,
    canvas: Canvas,
    changed: bool,
}

fn width(font: &FontRenderer, text: &str) -> i32 {
    font.get_rendered_dimensions(text, Point::zero(), VerticalPosition::Baseline)
        .ok()
        .and_then(|d| d.bounding_box)
        .map(|b| b.size.width as i32)
        .unwrap_or(0)
}

/// Break `text` into at most two lines that fit. What doesn't fit is cut, with "..".
fn wrap(font: &FontRenderer, text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut words = text.split_whitespace().peekable();
    while let Some(word) = words.next() {
        let longer = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
        if width(font, &longer) <= LINE_WIDTH[lines.len()] || line.is_empty() {
            line = longer;
        } else if lines.is_empty() {
            lines.push(core::mem::take(&mut line));
            line = word.to_string();
        } else {
            line.push_str("..");
            words.by_ref().for_each(drop);
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    // A single word too long for its line is cut letter by letter.
    for (i, line) in lines.iter_mut().enumerate() {
        while width(font, line) > LINE_WIDTH[i] && line.pop().is_some() {}
    }
    lines
}

impl Caption {
    pub fn new() -> Self {
        Caption {
            text: String::new(),
            until: None,
            canvas: Canvas { pixels: vec![0; (W * H * 2) as usize] },
            changed: false,
        }
    }

    /// Show `text` until the time `until` (milliseconds since start), or until it is
    /// replaced if `until` is None. An empty text clears the caption.
    pub fn show(&mut self, text: &str, until: Option<u64>) {
        self.until = until;
        if text == self.text {
            return;
        }
        self.text = text.to_string();
        self.canvas.pixels.fill(0);
        let font = FontRenderer::new::<Font>();
        for (i, line) in wrap(&font, text).iter().enumerate() {
            let _ = font.render_aligned(
                line.as_str(),
                Point::new(W / 2, LINE_BASELINE[i]),
                VerticalPosition::Baseline,
                HorizontalAlignment::Center,
                FontColor::Transparent(Rgb565::WHITE),
                &mut self.canvas,
            );
        }
        self.changed = true;
    }

    /// Clear a caption whose time is up.
    pub fn tick(&mut self, now: u64) {
        if self.until.is_some_and(|until| now >= until) {
            self.show("", None);
        }
    }

    /// True once after every change: the strip needs painting.
    pub fn take_changed(&mut self) -> bool {
        core::mem::take(&mut self.changed)
    }

    /// Copy the screen rows `row .. row + rows` of the strip into `out`.
    pub fn paint(&self, row: i32, rows: i32, out: &mut [u8]) {
        let from = ((row - Y) * W * 2) as usize;
        out.copy_from_slice(&self.canvas.pixels[from..from + (rows * W * 2) as usize]);
    }
}
