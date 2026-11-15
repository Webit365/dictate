#!/bin/bash
# Builds a signed Wisp.app and puts a ready-to-install zip + install guide in ./release.
# (this folder is in the Webit365 Dropbox, so the team gets it automatically).
# Add --release to also publish it on GitHub for the Claude Code installer.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="$HOME/Library/Caches/Dictate-build/Wisp.app"

mkdir -p release
rm -f release/Dictate-*.zip release/Wisp-*.zip release/How\ to\ install\ *.md
ditto -c -k --sequesterRsrc --keepParent "$APP" "release/Wisp-$VERSION.zip"
cp INSTALL.md release/How\ to\ install\ *.md

echo "Packaged release/Wisp-$VERSION.zip ($(du -h "release/Wisp-$VERSION.zip" | cut -f1))"

# ./package.sh --release  also publishes the zip as a GitHub release, which the Claude install
# instructions (CLAUDE-INSTALL.md) download from.
if [ "${1:-}" = "--release" ]; then
  # Also upload a copy named Wisp.zip, so .../releases/latest/download/Wisp.zip always gets the newest.
  STABLE="$(mktemp -d)/Wisp.zip"; cp "release/Wisp-$VERSION.zip" "$STABLE"
  gh release create "v$VERSION" "release/Wisp-$VERSION.zip" "$STABLE" --repo Webit365/dictate \
    --title "Wisp $VERSION" --notes "Download Wisp-$VERSION.zip, unzip, and drag Wisp into Applications. Or have Claude Code follow CLAUDE-INSTALL.md."
  echo "Published GitHub release v$VERSION"
fi
