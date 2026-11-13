use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    embuild::espidf::sysenv::output();

    // A name for this build, for the log and the crash guard: the commit and when it was
    // built. Any change to the sources gives a new one.
    let commit = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "nogit".into());
    let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    println!("cargo:rustc-env=BADGE_BUILD={commit}-{at}");
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-env-changed=BADGE_WIFI_SSID");
    println!("cargo:rerun-if-env-changed=BADGE_WIFI_PASSWORD");
}
