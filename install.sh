#!/usr/bin/env bash
# Build the app, install the config (if absent) and print what to do next.
# The pi integration is deliberately separate: see integrations/pi/install.sh.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
CONFIG_DIR="$HOME/.config/pi-toast"

echo "==> building"
./build.sh

echo "==> config"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.json" ]; then
	echo "    $CONFIG_DIR/config.json already exists, left untouched"
else
	cp config.example.json "$CONFIG_DIR/config.json"
	echo "    wrote $CONFIG_DIR/config.json"
fi

echo "==> launchd template"
sed "s|__ROTE_BIN__|$ROOT/build/Toast.app/Contents/MacOS/toast|" \
	launchd/dev.rote.toast.plist > build/dev.rote.toast.plist
echo "    wrote build/dev.rote.toast.plist"

cat <<EOF

installed.

  start the server   : $ROOT/build/Toast.app/Contents/MacOS/toast serve &
  push a test toast  : $ROOT/build/toast send --title "hello" --body "world"
  inspect config     : $ROOT/build/toast config
  preview a card     : $ROOT/build/toast preview --title T --body B --out /tmp/x.png

  start on login     : cp build/dev.rote.toast.plist ~/Library/LaunchAgents/
                       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/dev.rote.toast.plist
                       launchctl bootout   gui/\$(id -u)/dev.rote.toast    # to remove

  pi integration     : ./integrations/pi/install.sh --test
EOF
