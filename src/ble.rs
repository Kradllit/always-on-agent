//! Bluetooth LE: the badge shows up as "Basecamp Badge" with one service.
//!
//!   status   read, notify: JSON, e.g.
//!            {"battery":87,"charging":true,"usb":true,"ip":"10.0.0.7","mood":"happy","pets":3}
//!   command  write: a line of text, one of
//!            pet            be happy for a while, as if petted
//!            blink          blink once
//!            bright 60      screen brightness, 5 to 100
//!
//! Any phone or laptop nearby can connect: there is no pairing. Try it with the nRF Connect
//! or LightBlue app.

use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Result};
use esp32_nimble::utilities::BleUuid;
use esp32_nimble::{uuid128, BLEAdvertisementData, BLEDevice, NimbleProperties};

use crate::{Command, Status};

const SERVICE: BleUuid = uuid128!("ba5eca3b-0001-4b1d-9e5a-0d1e2f3a4b5c");
const STATUS: BleUuid = uuid128!("ba5eca3b-0002-4b1d-9e5a-0d1e2f3a4b5c");
const COMMAND: BleUuid = uuid128!("ba5eca3b-0003-4b1d-9e5a-0d1e2f3a4b5c");

fn parse(line: &str) -> Option<Command> {
    let mut words = line.split_whitespace();
    match (words.next()?, words.next()) {
        ("pet", None) => Some(Command::Pet),
        ("blink", None) => Some(Command::Blink),
        ("bright", Some(value)) => Some(Command::Brightness(value.parse::<u8>().ok()?.clamp(5, 100))),
        _ => None,
    }
}

/// Start Bluetooth. Returns at once; commands written by a phone arrive on `commands`.
pub fn start(status: Arc<Mutex<Status>>, commands: Sender<Command>) -> Result<()> {
    let device = BLEDevice::take();
    BLEDevice::set_device_name("Basecamp Badge").map_err(|e| anyhow!("Bluetooth name: {e:?}"))?;
    let advertising = device.get_advertising();
    let server = device.get_server();
    // A phone that leaves makes room for the next one.
    server.advertise_on_disconnect(true);

    let service = server.create_service(SERVICE);
    let status_value = service.lock().create_characteristic(STATUS, NimbleProperties::READ | NimbleProperties::NOTIFY);
    let command_value = service.lock().create_characteristic(COMMAND, NimbleProperties::WRITE);
    let commands = Mutex::new(commands);
    command_value.lock().on_write(move |args| {
        let line = String::from_utf8_lossy(args.recv_data()).trim().to_lowercase();
        match parse(&line) {
            Some(command) => {
                log::info!("Bluetooth: {line}");
                let _ = commands.lock().unwrap().send(command);
            }
            None => log::warn!("Bluetooth: not a command: {line:?}"),
        }
    });

    advertising
        .lock()
        .set_data(BLEAdvertisementData::new().name("Basecamp Badge").add_service_uuid(SERVICE))
        .map_err(|e| anyhow!("Bluetooth advertising data: {e:?}"))?;
    advertising.lock().start().map_err(|e| anyhow!("Bluetooth advertising: {e:?}"))?;
    log::info!("Bluetooth: on, as \"Basecamp Badge\"");

    // Keep the status value fresh; tell a connected phone when it changes.
    std::thread::Builder::new().name("ble-status".into()).stack_size(6144).spawn(move || {
        let mut sent = String::new();
        loop {
            let json = status.lock().unwrap().json();
            if json != sent {
                status_value.lock().set_value(json.as_bytes()).notify();
                sent = json;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    })?;
    Ok(())
}
