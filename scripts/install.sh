#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Quitting ends a meeting that is being recorded, so an install waits for it; FORCE=1 installs anyway.
recording() {
  pgrep -xq Narrari && [ -x "$HOME/.local/bin/narrari" ] &&
    "$HOME/.local/bin/narrari" meetings list --json 2>/dev/null | grep -Eq '"state" *: *"(recording|importing)"'
}
refuse() {
  echo "A meeting is being recorded. Install when it ends, or run with FORCE=1." >&2
  exit 3
}
[ -n "${FORCE:-}" ] || ! recording || refuse

bash scripts/ci.sh
[ -n "${FORCE:-}" ] || ! recording || refuse
osascript -e 'quit app "Narrari"' 2>/dev/null || true
# A copy still quitting would make the new one hand over to it and exit. A frozen one never quits, so it is killed after 5 seconds.
for _ in $(seq 25); do pgrep -xq Narrari || break; sleep 0.2; done
pkill -9 -x Narrari || true
while pgrep -xq Narrari; do sleep 0.2; done
rm -rf /Applications/Narrari.app
cp -R build/Build/Products/Release/Narrari.app /Applications/Narrari.app
# The app's own executable is the narrari command, so the command always matches the installed app.
mkdir -p "$HOME/.local/bin"
ln -sf /Applications/Narrari.app/Contents/MacOS/Narrari "$HOME/.local/bin/narrari"
open /Applications/Narrari.app
