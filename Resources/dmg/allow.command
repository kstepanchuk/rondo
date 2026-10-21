#!/bin/bash
# Rondo isn't notarized by Apple yet, so macOS may refuse to open it after a download.
# This removes the download "quarantine" flag from Rondo.app only, then opens it.
# Run it by dragging this file into a Terminal window and pressing Return.

for app in "/Applications/Rondo.app" "$HOME/Applications/Rondo.app"; do
  [ -d "$app" ] || continue
  id=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)
  if [ "$id" != "io.github.kstepanchuk.rondo" ]; then
    echo "Skipping $app: not Rondo ($id)."
    continue
  fi
  /usr/bin/xattr -dr com.apple.quarantine "$app" && echo "✓ Rondo can now be opened: $app"
  /usr/bin/open "$app"
  exit 0
done

echo "Rondo.app was not found in Applications."
echo "First drag Rondo to the Applications folder, then run this again."
exit 1
