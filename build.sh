#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Toast.app"

# The macOS 26 SDK is what unlocks Liquid Glass (NSGlassEffectView). Lookup order:
# TOAST_SDK, then the newest user-local ~/Library/Developer/SDKs/MacOSX2x.sdk,
# then whatever xcrun reports.
pick_sdk() {
	[ -n "${TOAST_SDK:-}" ] && { echo "$TOAST_SDK"; return; }
	# newest user-local 26+ SDK, so this is not pinned to one patch release
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
	-o "$APP/Contents/MacOS/toast" Sources/main.m

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

ln -sfn "Toast.app/Contents/MacOS/toast" build/toast

echo "built $APP"
otool -l "$APP/Contents/MacOS/toast" | grep -A3 LC_BUILD_VERSION | head -4
