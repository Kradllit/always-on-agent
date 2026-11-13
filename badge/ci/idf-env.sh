# Load ESP-IDF v6.0.2 for the badge firmware: `source idf-env.sh`.
# IDF_PATH wins if it's set; otherwise ~/esp/esp-idf-v6.0.2.
# Where ESP-IDF's Python env was built with uv's 3.11, that interpreter must come first on PATH.
_uvpy="$HOME/.local/share/uv/python/cpython-3.11-macos-aarch64-none/bin"
[ -d "$_uvpy" ] && export PATH="$_uvpy:$PATH"
unset _uvpy
source "${IDF_PATH:-$HOME/esp/esp-idf-v6.0.2}/export.sh" > /dev/null
