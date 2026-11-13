//! Wi-Fi: join the network built into this firmware and stay on it.
//!
//! The network's name and password come from BADGE_WIFI_SSID and BADGE_WIFI_PASSWORD when
//! the firmware is built (build.sh reads them from local.env, which is never in git).
//! The radio is 2.4 GHz only.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Result};
use esp_idf_svc::eventloop::EspSystemEventLoop;
use esp_idf_svc::hal::modem::Modem;
use esp_idf_svc::nvs::EspDefaultNvsPartition;
use esp_idf_svc::wifi::{AuthMethod, BlockingWifi, ClientConfiguration, Configuration, EspWifi};

use crate::Status;

const SSID: Option<&str> = option_env!("BADGE_WIFI_SSID");
const PASSWORD: Option<&str> = option_env!("BADGE_WIFI_PASSWORD");

/// Start Wi-Fi on a thread of its own. Returns at once; `status.ip` says when it is online.
pub fn start(
    modem: Modem,
    events: EspSystemEventLoop,
    nvs: EspDefaultNvsPartition,
    status: Arc<Mutex<Status>>,
) -> Result<()> {
    let ssid = SSID.unwrap_or("");
    if ssid.is_empty() {
        log::info!("Wi-Fi: no network built in (set BADGE_WIFI_SSID in local.env)");
        return Ok(());
    }
    std::thread::Builder::new().name("wifi".into()).stack_size(8192).spawn(move || {
        if let Err(error) = run(modem, events, nvs, ssid, &status) {
            log::error!("Wi-Fi stopped: {error:?}");
        }
    })?;
    Ok(())
}

fn run(
    modem: Modem,
    events: EspSystemEventLoop,
    nvs: EspDefaultNvsPartition,
    ssid: &str,
    status: &Mutex<Status>,
) -> Result<()> {
    let password = PASSWORD.unwrap_or("");
    let mut wifi = BlockingWifi::wrap(EspWifi::new(modem, events.clone(), Some(nvs))?, events)?;
    wifi.set_configuration(&Configuration::Client(ClientConfiguration {
        ssid: ssid.try_into().map_err(|_| anyhow!("the Wi-Fi name is too long"))?,
        password: password.try_into().map_err(|_| anyhow!("the Wi-Fi password is too long"))?,
        auth_method: if password.is_empty() { AuthMethod::None } else { AuthMethod::WPA2Personal },
        ..Default::default()
    }))?;
    wifi.start()?;
    loop {
        if !wifi.is_connected().unwrap_or(false) {
            status.lock().unwrap().ip = None;
            log::info!("Wi-Fi: joining {ssid}");
            match wifi.connect().and_then(|_| wifi.wait_netif_up()) {
                Ok(()) => {
                    let ip = wifi.wifi().sta_netif().get_ip_info()?.ip.to_string();
                    log::info!("Wi-Fi: on {ssid} as {ip}");
                    status.lock().unwrap().ip = Some(ip);
                }
                Err(error) => {
                    log::warn!("Wi-Fi: could not join {ssid}: {error}");
                    let _ = wifi.disconnect();
                }
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}
