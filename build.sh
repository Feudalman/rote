#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Toast.app"

# The macOS 26 SDK is what unlocks Liquid Glass (NSGlassEffectView). It is not
# installed system-wide here, so we keep an extracted copy in the user library and
# fall back to whatever xcrun reports when it is absent.
SDK="${TOAST_SDK:-$HOME/Library/Developer/SDKs/MacOSX26.5.sdk}"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
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
