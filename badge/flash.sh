#!/bin/zsh
# Flash build/badge.bin onto the badge on USB and show its log (Ctrl-C to stop).
#   ./flash.sh
# Only the app is written (at 0x20000): the settings saved on the badge stay.
# The screen stands still for about half a minute while it writes.
# A badge that has never run this firmware layout needs everything once: `cargo run --release`.
set -e
here=${0:A:h}
[ -f $here/build/badge.bin ] || { echo "no build/badge.bin: run ./build.sh first"; exit 1; }
ports=(/dev/cu.usbmodem*(N))
[ ${#ports} -gt 0 ] || { echo "no badge on USB"; exit 1; }
for dir in /opt/homebrew/bin $HOME/.cargo/bin; do [ -d $dir ] && PATH="$dir:$PATH"; done
exec espflash write-bin --chip esp32s3 -p ${ports[1]} --monitor 0x20000 $here/build/badge.bin
