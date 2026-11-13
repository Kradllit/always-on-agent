#!/bin/zsh
# Build the firmware.
#   ./build.sh
# Output: build/badge.bin, the app alone (it goes to 0x20000 on the badge).
# The first build fetches and builds ESP-IDF, which takes about 15 minutes; later ones a
# minute or two.
#
# Settings that must not be in git come from local.env beside this script (git-ignored),
# or from the environment:
#   BADGE_WIFI_SSID, BADGE_WIFI_PASSWORD   the Wi-Fi the badge joins (2.4 GHz)
set -e
here=${0:A:h}
env_file=${BADGE_LOCAL_ENV:-$here/local.env}
[ -f $env_file ] && { set -a; source $env_file; set +a }
export BADGE_WIFI_SSID=${BADGE_WIFI_SSID:-} BADGE_WIFI_PASSWORD=${BADGE_WIFI_PASSWORD:-}
echo "Wi-Fi built in: ${BADGE_WIFI_SSID:-none}"

# espup's file says where the Xtensa compiler and libclang are.
[ -f ~/export-esp.sh ] && source ~/export-esp.sh
for dir in /opt/homebrew/opt/rustup/bin $HOME/.cargo/bin; do [ -d $dir ] && PATH="$dir:$PATH"; done
# ESP-IDF's installer needs a Python it supports; uv's 3.11 goes first where it exists.
uvpy="$HOME/.local/share/uv/python/cpython-3.11-macos-aarch64-none/bin"
[ -d $uvpy ] && PATH="$uvpy:$PATH"
export PATH

cd $here
cargo build --release
mkdir -p build
espflash save-image --chip esp32s3 --flash-size 16mb \
    target/xtensa-esp32s3-espidf/release/basecamp-badge build/badge.bin
ls -l build/badge.bin
