#!/usr/bin/env bash
# Smoke test: render three toasts and check they actually reach the screen.
# Exits non-zero on the first failed step, so it is usable in a pipeline.
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

# Verify against the window server when possible. Quartz needs no special permission
# for window geometry (only screen recording needs it), so this works unattended.
if python3 -c "import Quartz" 2>/dev/null; then
	sleep 0.6
	count=$(python3 - <<'PY'
import Quartz
print(len([w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
           if "toast" in (w.get("kCGWindowOwnerName", "") or "").lower()]))
PY
)
	# >= not ==: a second run within 12s still sees the previous toasts on screen.
	echo "smoke: on-screen toasts = $count (expected >= 3)"
	[ "$count" -ge 3 ] || { echo "smoke: FAIL, only $count window(s) appeared" >&2; exit 1; }
else
	echo "smoke: python3 + pyobjc not available, skipping window check"
fi

echo "smoke: OK (toasts stay 12s, then fade out on their own)"
