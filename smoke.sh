#!/usr/bin/env bash
# 冒烟测试：弹三条，确认真的上屏
# 任何一步失败立刻非 0 退出，可以在流水线里直接用
set -euo pipefail
cd "$(dirname "$0")"

TOAST=./build/toast
[ -x "$TOAST" ] || { echo "smoke: build first (./build.sh)" >&2; exit 1; }

if ! "$TOAST" config | grep -q "server running"; then
	echo "smoke: starting server"
	(./build/Toast.app/Contents/MacOS/toast serve >/tmp/toast.log 2>&1 &)
	sleep 1
	"$TOAST" config | grep -q "server running" || { echo "smoke: server did not start (see /tmp/toast.log)" >&2; exit 1; }
fi

send() {
	"$TOAST" send --json "$1" || { echo "smoke: send failed for $1" >&2; exit 1; }
}

echo "smoke: sending three toasts"
send '{"title":"冒烟测试 1","body":"单行正文，验证渲染与淡入","duration":12}'
sleep 0.3
send '{"title":"冒烟测试 2","body":"验证同屏堆叠：新的一条在最上面，旧的往下推","duration":12}'
sleep 0.3
send '{"title":"冒烟测试 3","body":"三条都出现后，等自动消失，上方两条应依次贴回顶部","duration":12}'

# 用窗口服务器核对。取窗口几何不需要任何授权（只有录屏需要），所以能无人值守地跑
if python3 -c "import Quartz" 2>/dev/null; then
	sleep 0.6
	count=$(python3 - <<'PY'
import Quartz
print(len([w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
           if "toast" in (w.get("kCGWindowOwnerName", "") or "").lower()]))
PY
)
	# 用 >= 不用 ==：12 秒内跑第二遍还会看到上一轮的卡片
	echo "smoke: on-screen toasts = $count (expected >= 3)"
	[ "$count" -ge 3 ] || { echo "smoke: FAIL, only $count window(s) appeared" >&2; exit 1; }
else
	echo "smoke: python3 + pyobjc not available, skipping window check"
fi

echo "smoke: OK (toasts stay 12s, then fade out on their own)"
