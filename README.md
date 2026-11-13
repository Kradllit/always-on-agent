# Basecamp badge

A starting firmware in Rust for a small round touchscreen badge, the Waveshare
ESP32-S3-Touch-AMOLED-1.75C.
It is a base to build on: two eyes, a touchscreen that reacts, text, a button, a shake
sensor, a speaker and microphones, a battery, Wi-Fi and Bluetooth, with one file
(`src/app.rs`) where features go.

What it does today:

- **Eyes.** Two white blocks on a black screen that blink and glance around.
- **Touch.** Put a finger on the screen and the eyes look at it. Tap and they widen, then
  blink. Stroke the screen (pet it) and they curve into happy pink arcs and bounce.
- **Text.** A caption of one or two lines under the eyes: `badge.say("hello")`.
- **Button and shake.** BOOT shows the battery and the Wi-Fi address; shaking the badge
  startles it.
- **Sound.** A beep on BOOT. Hold BOOT for a second and let go: the badge records three
  seconds and plays them back.
- **Battery.** The power chip is set up for charging; the level and charging state are read
  every five seconds. Below 15 % on battery the eyes droop. Untouched, the screen dims after
  30 seconds and, on battery, switches off after two minutes. A touch brings it back.
  Holding PWR for four seconds switches the badge off.
- **Wi-Fi.** Joins the network named at build time and rejoins when it drops.
- **Bluetooth.** Shows up as "Basecamp Badge". A status value to read and a few commands to
  write (`pet`, `blink`, `bright 60`); any other text written to it shows on the screen.
  See `src/ble.rs`.
- **Crash guard.** A firmware that crashes three times in a row at start stops in safe mode
  with a black screen, ready for the next flash.

## The platform

| Part | What | How it's connected |
|---|---|---|
| Chip | ESP32-S3R8: two cores at 240 MHz, Wi-Fi (2.4 GHz) and Bluetooth LE, 8 MB PSRAM, 16 MB flash | |
| Screen | 1.75" round AMOLED, 466 x 466, CO5300 driver chip | SPI with four data lines |
| Touch | CST9217 | I2C, address 0x5A |
| Power | AXP2101: battery charging, power rails, PWR button | I2C, address 0x34 |
| Motion | QMI8658 accelerometer and gyroscope (the accelerometer is in use) | I2C, address 0x6B |
| Sound | ES8311 speaker codec, ES7210 two microphones, a small speaker | I2C and I2S |
| Buttons | BOOT (GPIO 0), PWR (through the power chip) | |
| USB-C | Power, flashing and the log, all on the chip's own USB | |

The pins are in `src/board.rs`.

Where the knowledge of the board comes from: the pin map, the power chip's set-up and the
screen's start-up commands follow the board support for this badge in
[XiaoZhi](https://github.com/78/xiaozhi-esp32) (MIT licence), an open-source voice
assistant firmware in C++ that runs on it, and Waveshare's own examples. That firmware was
our baseline for what works on this hardware; this repository starts over in Rust.

How the Rust sits on the chip: this is Rust with the standard library on top of ESP-IDF,
Espressif's SDK, through the [esp-idf-svc](https://github.com/esp-rs/esp-idf-svc) crates.
Wi-Fi, storage and threads come from there; Bluetooth from
[esp32-nimble](https://github.com/taks/esp32-nimble). The one piece of C in use is
Espressif's drivers for the screen's chip and for the two audio chips. The power chip, the
touch controller, the motion sensor and the face are plain Rust in `src/`.

## The code

Features go in `src/app.rs`. The badge calls `on_event` there whenever something happens
and hands over a `Badge` to answer with:

```rust
pub fn on_event(&mut self, event: Event, badge: &mut Badge) {
    match event {
        Event::Shake => {
            badge.face.startle();
            badge.say("whoa!");
        }
        Event::Message(text) => badge.say_for(&text, 6000),
        _ => {}
    }
}
```

The events: `Start`, `TouchDown { x, y }`, `TouchMove { x, y }`, `TouchUp`, `Tap`, `Pet`,
`ButtonDown`, `ButtonUp { held_ms }`, `Shake`, `Tilt { x, y, z }`, `Message(text)` (a line sent
over Bluetooth), `Heard(recording)`, `Loudness(percent)` (how loud the room is, five times a
second, while `sound.meter(true)` is on) and `Second`. On the badge: `say`, `say_for`,
`say_and_keep`, `hush`, `face`, `sound` (`beep`, `play`, `listen`, `volume`, `meter`),
`battery`, `ip`, `tilt`, `now`.
Every event is also written to the log, except the ones that come many times a second
(`TouchMove`, `Tilt`, `Loudness`, `Second`).

The `app.rs` in the repository is a tour of the hardware, there to be replaced: it writes
what the badge senses under the eyes (a touch, a tap, petting, the button, a shake, the
microphone's level, text over Bluetooth). A press of BOOT shows the battery and the Wi-Fi
address, then the tilt for ten seconds; holding BOOT a second records three seconds and
plays them back.

| File | What |
|---|---|
| `src/app.rs` | Your features: what the badge does when something happens |
| `src/badge.rs` | The events an app gets and what it can do with the badge |
| `src/main.rs` | Start-up and the loop: read the hardware, tell the app, paint, rest the screen |
| `src/eyes.rs` | The face and what a touch does to it. No hardware in here |
| `src/text.rs` | The caption under the eyes |
| `src/button.rs` | The BOOT button |
| `src/motion.rs` | The motion sensor: tilt and shakes |
| `src/sound.rs` | The speaker and the microphones: beep, play, record |
| `src/bus.rs` | The I2C bus the chips share |
| `src/display.rs` | The screen: paint a rectangle, set the brightness |
| `src/touch.rs` | Where the finger is |
| `src/power.rs` | Battery level, charging, power off |
| `src/wifi.rs` | Joining Wi-Fi |
| `src/ble.rs` | The Bluetooth service |
| `src/guard.rs` | The crash guard |
| `src/usb.rs` | Brings the USB link back when a restart leaves the computer with a dead one |
| `src/board.rs` | Pins and addresses, and what on the board is still unused |

`AGENTS.md` has the working rules for coding agents (and is worth a read for people too).

## Working on it

Push to `main`. A laptop with the shared badge on USB builds every new commit on `main`
and flashes it, usually within a few minutes. The commit gets a status named **badge**:
building, flashed and started, build failed (with the compiler's errors as a comment on the
commit), or crashed at start (with the crash line). While it flashes, the badge's screen
stands still for about half a minute.

Only the newest commit is built when several land together, so a push can be skipped if
another follows it quickly.

### Building it yourself

You need Rust with Espressif's toolchain:

```sh
brew install rustup espflash && rustup default stable   # or https://rustup.rs
cargo install espup ldproxy --locked
espup install --targets esp32s3
```

Then:

```sh
./build.sh      # the first build fetches and builds ESP-IDF: about 15 minutes, once
./flash.sh      # writes the app to a badge on USB and shows its log
```

`./flash.sh` writes only the app and keeps the badge's settings. A badge that has never
had this firmware's layout needs everything once: `cargo run --release` (this erases its
settings, and has not been tried on our badge yet).

The Wi-Fi the badge joins is set at build time, in a file named `local.env` beside
`build.sh`, which git ignores:

```sh
BADGE_WIFI_SSID='the network name'
BADGE_WIFI_PASSWORD='its password'
```

The radio is 2.4 GHz only. A phone's hotspot works when it offers 2.4 GHz (on an iPhone:
Maximize Compatibility).

### Talking to it over Bluetooth

With nRF Connect or LightBlue on a phone, connect to "Basecamp Badge" and open the service
`ba5eca3b-0001-…`. Read `…0002…` for the status (battery, Wi-Fi address, mood, how many
times it has been petted) or subscribe to it. Write text to `…0003…`: `pet`, `blink`,
`bright 60`, or any other line, which the app shows on the screen. There is no pairing:
anyone nearby can do this.

## If the badge is stuck

A bad firmware cannot brick it: the chip's own loader is in ROM.

1. Unplug USB. If the screen is still lit, hold PWR about six seconds until it's dark.
2. Hold BOOT, plug USB in while holding it, let go after two seconds. The screen stays black.
3. Flash (`./flash.sh`, or push a fix and let the laptop do it).

## The build-and-flash laptop

`ci/flash-on-push.ts` is the watcher; `bun ci/flash-on-push.ts` starts it on the laptop the
badge is plugged into. It asks GitHub for the head of `main` every ten seconds (no webhook,
so the laptop needs no public address), builds in a clone of its own under `ci/work`, and
keeps its logs in `ci/logs`. The Wi-Fi settings come from that laptop's `local.env`.

Anyone who can push to `main` runs their build on that laptop. Keep the list of people
with push access to people you trust with it.
