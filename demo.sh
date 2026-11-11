#!/usr/bin/env bash
# Fire a few toasts to eyeball the rendering and stacking.
set -euo pipefail
cd "$(dirname "$0")"

if ! ./build/toast config | grep -q "server running"; then
	echo "starting server..."
	(./build/toast serve >/tmp/toast.log 2>&1 &)
	sleep 1
fi

./build/toast send --title "Pi · arui" --body "会话完成 · 42s" --duration 6
sleep 0.4
./build/toast send --title "Pi · mac-toast" --body "会话完成 · 8s" --duration 6
sleep 0.4
./build/toast send --title "第二条堆叠" --body "自动消失后上方的会重新贴合" --duration 6
