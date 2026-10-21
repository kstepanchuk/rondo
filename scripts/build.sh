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

# Shortcuts/Spotlight actions: SwiftPM doesn't run Xcode's App Intents step, so do it here.
# 1) a compile pass that only gathers constant values, 2) the metadata processor.
AI="$(mktemp -d)"
printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutsProvider","AppShortcutProviding","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable"]' > "$AI/protocols.json"
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos13.0 -swift-version 5 -parse-as-library \
  -module-name Rondo -wmo -c Sources/Rondo/*.swift -o "$AI/Rondo.o" \
  -emit-const-values-path "$AI/Rondo.swiftconstvalues" -Xfrontend -const-gather-protocols-file -Xfrontend "$AI/protocols.json"
ls "$PWD"/Sources/Rondo/*.swift > "$AI/sources.txt"
echo "$AI/Rondo.swiftconstvalues" > "$AI/constvals.txt"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(xcrun --find swiftc)")")" --module-name Rondo \
  --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 13.0 --target-triple arm64-apple-macos13.0 \
  --source-file-list "$AI/sources.txt" --swift-const-vals-list "$AI/constvals.txt" --binary-file "$AI/Rondo.o" \
  2>&1 | grep -v "appintentsmetadataprocessor\[" || true
test -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"

codesign --force --options runtime --entitlements Resources/Rondo.entitlements --sign - "$APP"
# ZIP only for the transition: versions ≤ 0.1.3 update from Rondo-<ver>.zip.
if [ "${LEGACY_ZIP:-0}" = "1" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Rondo-$VERSION.zip"
fi

# DMG: Rondo.app next to an Applications shortcut for drag-and-drop install.
# Regenerate the background with scripts/make-dmg-background.swift.
STAGE="$(mktemp -d)/Rondo"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Window layout (background, icon positions, size) made once in Finder; the
# .DS_Store points at the background on a volume named "Rondo", so keep that name.
mkdir -p "$STAGE/.background"
cp Resources/dmg/background.tiff "$STAGE/.background/background.tiff"
cp Resources/dmg/DS_Store "$STAGE/.DS_Store"
# Helper for un-notarized builds: removes the download quarantine from Rondo.app only.
cp Resources/dmg/allow.command "$STAGE/Разрешить запуск.command"
chmod +x "$STAGE/Разрешить запуск.command"
hdiutil create -quiet -volname "Rondo" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "dist/Rondo-$VERSION.dmg"

# Checksums: the in-app updater verifies the DMG against Rondo-<ver>.dmg.sha256.
(cd dist && for f in Rondo-"$VERSION".*; do case "$f" in *.sha256) ;; *) shasum -a 256 "$f" > "$f.sha256";; esac; done)
cat dist/*.sha256
