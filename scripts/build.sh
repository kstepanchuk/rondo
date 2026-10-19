#!/bin/bash
# Builds a universal Rondo.app and Rondo-<version>.dmg into ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
VERSION="${VERSION:-0.1.0}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Rondo"

APP=dist/Rondo.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rondo"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --entitlements Resources/Rondo.entitlements --sign - "$APP"
# ZIP only for the transition: versions ≤ 0.1.3 update from Rondo-<ver>.zip.
if [ "${LEGACY_ZIP:-0}" = "1" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Rondo-$VERSION.zip"
fi

# DMG: Rondo.app next to an Applications shortcut for drag-and-drop install.
STAGE="$(mktemp -d)/Rondo"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Rondo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "dist/Rondo-$VERSION.dmg"

# Checksums: the in-app updater verifies the DMG against Rondo-<ver>.dmg.sha256.
(cd dist && for f in Rondo-"$VERSION".*; do case "$f" in *.sha256) ;; *) shasum -a 256 "$f" > "$f.sha256";; esac; done)
cat dist/*.sha256
