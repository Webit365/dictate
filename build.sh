#!/bin/bash
# Builds Wisp.app and installs it to ~/Applications.
# Source lives in Dropbox; the build output, Whisper framework, and speech model stay local.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Dictate"
FW_DIR="$SUPPORT/vendor/whisper.xcframework/macos-arm64_x86_64"
BUILD="$HOME/Library/Caches/Dictate-build"
APP="$BUILD/Wisp.app"
INSTALL="$HOME/Applications/Wisp.app"

# Only the whisper framework is needed to build; the app downloads its speech models on first launch.
if [ ! -d "$FW_DIR/whisper.framework" ]; then
  echo "Whisper framework missing. Run ./setup.sh first."; exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

# Command Line Tools ship macOS 27+ SDKs where SwiftUI's @State is a macro, but its plugin
# (libSwiftUIMacros) only comes with full Xcode. If @State won't compile with the default SDK,
# fall back to the newest installed macOS 26-or-older SDK. Set SDKROOT yourself to override.
TARGET=arm64-apple-macos14.0
STATE_TEST='import SwiftUI
struct V: View { @State var x = 0; var body: some View { Text("") } }'
if [ -z "${SDKROOT:-}" ] && ! echo "$STATE_TEST" | swiftc -typecheck -target "$TARGET" - >/dev/null 2>&1; then
  SDK_DIR=$(dirname "$(xcrun --show-sdk-path)")
  for sdk in $(cd "$SDK_DIR" && ls -d MacOSX[0-9]*.sdk 2>/dev/null | sort -V -r); do
    major=$(echo "$sdk" | sed 's/MacOSX//; s/\..*//')
    if [ "$major" -le 26 ]; then export SDKROOT="$SDK_DIR/$sdk"; break; fi
  done
  [ -n "${SDKROOT:-}" ] && echo "Using $(basename "$SDKROOT") (default SDK needs Xcode for SwiftUI macros)." \
    || echo "Note: no macOS 26 SDK found; the build may fail. Install Xcode or set SDKROOT."
fi

echo "Compiling…"
swiftc -O -swift-version 5 -target "$TARGET" \
  -F "$FW_DIR" -framework whisper \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift -o "$APP/Contents/MacOS/Wisp"

ditto "$FW_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the private "Dictate Local Signing" certificate when it exists, so macOS sees every
# rebuild as the same app and keeps its Accessibility / Microphone / Screen Recording permissions.
# Falls back to ad-hoc signing (permissions then reset on each rebuild).
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"Dictate Local Signing"/ {print $2; exit}')
SIGN_ID=${SIGN_ID:--}
[ "$SIGN_ID" = "-" ] && echo "Note: signing certificate not found; using ad-hoc signing."
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_ID" "$APP"

if [ "${1:-}" = "--no-install" ]; then echo "Built: $APP"; exit 0; fi

pkill -x Dictate 2>/dev/null || true
pkill -x Wisp 2>/dev/null || true
rm -rf "$HOME/Applications/Dictate.app" "$BUILD/Dictate.app"   # old name, before it became Wisp
mkdir -p "$HOME/Applications"
# Update the app in place instead of deleting it first: the Dock drops a pinned app whose
# file disappears, so rm -rf + copy kept knocking Wisp out of the Dock.
mkdir -p "$INSTALL"
rsync -a --delete "$APP/" "$INSTALL/"
open "$INSTALL"
echo "Installed and launched: $INSTALL"
