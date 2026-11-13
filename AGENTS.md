# For coding agents working in this repo

Firmware in Rust for one small round touchscreen badge (Waveshare ESP32-S3-Touch-AMOLED-1.75C).
The README explains the hardware and the code layout; read it first. This file holds what
the README doesn't: how work reaches the badge, and what this board punishes.

## There is one badge, and `main` flashes it

A laptop watches `main`. Every new commit there is built and flashed onto the team's badge
within a couple of minutes, and the badge's screen stands still for half a minute while it
writes. So:

- Work on a branch. Merge to `main` when the change compiles and is worth seeing on the badge.
- After a push to `main`, read the result: the commit gets a status named `badge`
  (`gh api repos/{owner}/{repo}/commits/<sha>/status`). A failed build also posts the
  compiler's errors as a comment on the commit; a crash at start posts the crash line.
- Only the newest commit is built when several land together.
- You cannot see the screen or hear the speaker. Say so when a change needs a person to
  look or listen, and say what they should see. The badge's log does tell you a lot: every
  event the app gets is logged (`event: Pet`, `event: Shake`, ...).

## Checking a change before it reaches `main`

`./build.sh` (or `cargo build --release`) is the check. The first build on a machine
fetches and builds ESP-IDF and takes about 15 minutes; after that, a change to Rust code
builds in seconds. A change to `sdkconfig.defaults`, `Cargo.toml`'s components or
`components/bindings.h` rebuilds ESP-IDF's part, which takes minutes. There are no tests yet.

## Where things go

- A feature: `src/app.rs`, answering `Event`s through the `Badge` it is handed
  (`src/badge.rs` lists both). Most features need nothing else.
- Something new the badge can sense or do: its own file, an `Event` variant or a `Badge`
  method in `src/badge.rs`, and its place in the loop in `src/main.rs`.
- Work that takes longer than a frame (network, recording, anything that waits): a thread
  of its own, which sends its result back as an `Event` through the inbox channel in
  `main.rs`. `src/sound.rs` is the example. The main loop runs about 30 times a second and
  the eyes freeze whenever it is held up.

## What this board punishes

- **A crash at start.** The crash guard (`src/guard.rs`) counts crashes and stops in safe
  mode after three, but it only starts counting once `main` runs. A firmware that dies
  before `main` (ESP-IDF's own start-up checks do this) restarts for ever. On 2026-11-13 a
  tight restart loop froze the chip solid: no answer over USB until someone unplugged it,
  held PWR and replugged it with BOOT held. `sdkconfig.defaults` now makes every crash wait
  five seconds before restarting, which keeps USB flashing possible. Leave that setting in.
- **Two I2C drivers.** ESP-IDF has an older and a newer I2C driver and stops at start when
  it finds both in use. Everything here uses the newer one through `src/bus.rs`; the audio
  component needs that same bus handle. Use `bus::I2c` for any new chip on the bus, not
  `esp_idf_svc::hal::i2c::I2cDriver` (that is the older driver, and it was the crash above).
- **Odd screen rectangles.** The screen's chip takes only even x, y, width and height;
  `Display::paint` refuses anything else. The strip from y = 364 down belongs to the
  caption (`src/text.rs`); the eyes paint above it.
- **The screen's bus on two cores.** The SPI interrupt is pinned to core 0, where the
  drawing loop runs (`src/display.rs` says why). Keep drawing on the main thread.
- **5 GHz Wi-Fi.** The radio is 2.4 GHz only. A network the badge "can't find" is usually
  5 GHz; the log says which case it is.

## Smaller things that cost time

- `use esp_idf_svc::sys::*;` brings in a C symbol named `log`. In a file with that import,
  write `::log::info!` and friends.
- Internal memory is tight with Wi-Fi and Bluetooth up. Allocations over 4 KB come from the
  8 MB of PSRAM on their own, so big buffers are fine as ordinary `Vec`s; memory that SPI
  or I2S sends straight from must be internal (`heap_caps_malloc` with `MALLOC_CAP_DMA`).
- The Wi-Fi name and password live in `local.env`, which git ignores. Nothing secret goes
  in a commit; API keys follow the same pattern (an environment variable read at build
  time with `option_env!`, set in `local.env`).
- Text on the screen is Latin-1 only: no emoji, no other alphabets.

## Not built yet

The gyroscope, network helpers (HTTP), deep sleep, and anything that talks to a server.
Flashing a whole badge from scratch (`cargo run --release`) has not been tried on our badge.
