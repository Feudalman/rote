#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Toast.app"

# Liquid Glass（NSGlassEffectView）靠链接 macOS 26 SDK 打开，查找顺序：
# TOAST_SDK → 用户目录下最新的 MacOSX2x.sdk → xcrun 报告的路径
pick_sdk() {
	[ -n "${TOAST_SDK:-}" ] && { echo "$TOAST_SDK"; return; }
	# 取最新的 26+，不钉死某个补丁版本
	local best
	best=$(ls -d "$HOME/Library/Developer/SDKs/MacOSX"2[6-9]*.sdk 2>/dev/null | sort -V | tail -1)
	[ -n "$best" ] && { echo "$best"; return; }
	xcrun --show-sdk-path
}
SDK="$(pick_sdk)"
echo "sdk: $SDK"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -O2 -Wall -Wno-unused-parameter \
	-isysroot "$SDK" \
	-target "$(uname -m)-apple-macos14.0" \
	-framework Cocoa -framework QuartzCore \
	-o "$APP/Contents/MacOS/toast" Sources/*.m

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

ln -sfn "Toast.app/Contents/MacOS/toast" build/toast

echo "built $APP"
otool -l "$APP/Contents/MacOS/toast" | grep -A3 LC_BUILD_VERSION | head -4
