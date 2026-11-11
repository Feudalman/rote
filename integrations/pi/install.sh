#!/usr/bin/env bash
# 装 pi 接入：把扩展丢进 pi 的自动发现目录，再确保 toast 配置里有 `pi` 段
#
#   ./install.sh            install / refresh the extension
#   ./install.sh --test     ...and fire a test toast
#   ./install.sh --remove   uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="$HOME/.pi/agent/extensions"
EXT_FILE="$EXT_DIR/toast-notify.ts"
CONFIG_DIR="$HOME/Library/Application Support/Toast"
LEGACY_CONFIG="$HOME/.config/pi-toast/config.json"

# 与 toast 的搜索顺序保持一致：已有旧位置的就沿用它，都没有才在首选位置新建
if [ ! -f "$CONFIG_DIR/config.json" ] && [ -f "$LEGACY_CONFIG" ]; then
	CONFIG_FILE="$LEGACY_CONFIG"
else
	CONFIG_FILE="$CONFIG_DIR/config.json"
fi

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
elif command -v python3 >/dev/null 2>&1; then
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
else
	echo "    python3 not found, config left alone. Add this section manually if missing:"
	echo '    "pi": { "enabled": true, "body": "{summary}", "summaryMode": "lastMessage" }'
fi

if [ "${1:-}" = "--test" ]; then
	echo "==> test toast"
	"$HERE/../../build/toast" send --json \
		'{"source":"pi","title":"Pi · 集成测试","body":"扩展已安装，/reload 后即可生效","duration":8}' \
		|| echo "    (server not running? start it with ../../install.sh)"
fi

cat <<EOF

installed. next:

  1. make sure the toast server is running
       cd "$HERE/../.." && ./install.sh
  2. run /reload inside pi
  3. the next session that lasts longer than pi.minRunSeconds will toast

  undo: $HERE/install.sh --remove
EOF
