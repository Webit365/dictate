#!/bin/bash
# Builds a signed Dictate.app and puts a ready-to-install zip + install guide in ./release
# (this folder is in the Webit365 Dropbox, so the team gets it automatically).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="$HOME/Library/Caches/Dictate-build/Dictate.app"

mkdir -p release
rm -f release/Dictate-*.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "release/Dictate-$VERSION.zip"
cp INSTALL.md "release/How to install Dictate.md"

echo "Packaged release/Dictate-$VERSION.zip ($(du -h "release/Dictate-$VERSION.zip" | cut -f1))"
