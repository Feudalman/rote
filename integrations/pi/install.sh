#!/usr/bin/env bash
# Install the pi integration: drop the extension into pi's auto-discovery directory
# and make sure the `pi` section of the toast config exists.
#
#   ./install.sh            install / refresh the extension
#   ./install.sh --test     ...and fire a test toast
#   ./install.sh --remove   uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="$HOME/.pi/agent/extensions"
EXT_FILE="$EXT_DIR/toast-notify.ts"
CONFIG_DIR="$HOME/.config/pi-toast"
CONFIG_FILE="$CONFIG_DIR/config.json"

remove() {
	rm -f "$EXT_FILE"
	echo "removed $EXT_FILE"
	echo "run /reload inside pi to drop it from the running session"
	exit 0
}

[ "${1:-}" = "--remove" ] && remove

echo "==> extension -> $EXT_FILE"
mkdir -p "$EXT_DIR"
cp "$HERE/toast-notify.ts" "$EXT_FILE"

echo "==> config    -> $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
	cp "$HERE/../../config.example.json" "$CONFIG_FILE"
	echo "    created from config.example.json"
else
	python3 - "$CONFIG_FILE" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
defaults = {
    "enabled": True,
    "socket": "~/.pi-toast/toast.sock",
    "minRunSeconds": 3,
    "skipAborted": True,
    "modes": ["tui"],
    "duration": 10,
    "title": "Pi · {project}",
    "body": "{summary}",
    "warnOnFailure": False,
    "summaryMode": "lastMessage",
    "summaryMaxChars": 45,
    "summaryModel": "",
    "summaryTimeoutMs": 10000,
}
section = data.setdefault("pi", {})
added = [k for k, v in defaults.items() if k not in section]
for k, v in defaults.items():
    section.setdefault(k, v)
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(f"    merged pi section ({len(added)} new key(s))")
PY
fi

if [ "${1:-}" = "--test" ]; then
	SOCK=$(python3 -c "import json,pathlib,os;d=json.loads(pathlib.Path('$CONFIG_FILE').read_text());print(os.path.expanduser(d.get('pi',{}).get('socket','~/.pi-toast/toast.sock')))")
	echo "==> test toast -> $SOCK"
	python3 - "$SOCK" <<'PY'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(sys.argv[1])
sock.sendall((json.dumps({"source": "pi", "title": "Pi · 集成测试", "body": "扩展已安装，/reload 后即可生效", "duration": 8}) + "\n").encode())
sock.close()
print("    sent (if nothing appeared, the toast server is not running)")
PY
fi

cat <<EOF

installed. next:

  1. make sure the toast server is running
       cd "$HERE/../.." && ./install.sh
  2. run /reload inside pi
  3. the next session that lasts longer than pi.minRunSeconds will toast

  undo: $HERE/install.sh --remove
EOF
