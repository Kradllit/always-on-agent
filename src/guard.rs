//! The crash guard: a firmware that crashes right after it starts must not restart for
//! ever (a badge in a crash loop flickers, drains its battery and can't be reasoned with).
//!
//! Every start that follows a crash is counted. After three in a row the badge starts in
//! safe mode: nothing but the log, a black screen, and USB ready for the next firmware.
//! Staying up for half a minute clears the count, and so does a new build.

use anyhow::Result;
use esp_idf_svc::nvs::{EspDefaultNvsPartition, EspNvs, NvsDefault};
use esp_idf_svc::sys::*;

const LIMIT: u8 = 3;
/// Up this long, a start counts as a good one.
pub const SETTLE_MS: u64 = 30_000;

pub struct Guard {
    store: EspNvs<NvsDefault>,
    crashes: u8,
    settled: bool,
}

impl Guard {
    /// Call first thing at start.
    pub fn start(nvs: EspDefaultNvsPartition) -> Result<Self> {
        let build = env!("BADGE_BUILD");
        let store = EspNvs::new(nvs, "guard", true)?;
        let mut name = [0u8; 48];
        let same_build = store.get_str("build", &mut name)?.map(|b| b == build).unwrap_or(false);
        let mut crashes = if same_build { store.get_u8("crashes")?.unwrap_or(0) } else { 0 };
        let reason = unsafe { esp_reset_reason() };
        let crashed = [
            esp_reset_reason_t_ESP_RST_PANIC,
            esp_reset_reason_t_ESP_RST_INT_WDT,
            esp_reset_reason_t_ESP_RST_TASK_WDT,
            esp_reset_reason_t_ESP_RST_WDT,
        ]
        .contains(&reason);
        if crashed {
            crashes = crashes.saturating_add(1);
        }
        if !same_build {
            store.set_str("build", build)?;
        }
        store.set_u8("crashes", crashes)?;
        if crashes == 0 {
            log::info!("crash guard: build {build}, normal start");
        } else {
            log::warn!("crash guard: build {build}, {crashes} crash(es) in a row at start");
        }
        Ok(Guard { store, crashes, settled: crashes == 0 })
    }

    pub fn safe_mode(&self) -> bool {
        self.crashes >= LIMIT
    }

    /// Call now and then with the time since start; once the badge has stayed up long
    /// enough, the count starts over.
    pub fn tick(&mut self, up_ms: u64) {
        if !self.settled && up_ms >= SETTLE_MS {
            self.settled = true;
            if self.store.set_u8("crashes", 0).is_ok() {
                log::info!("crash guard: up for half a minute, the count starts over");
            }
        }
    }
}
