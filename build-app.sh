#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
APP="MiniClockify.app"
BIN=".build/${CONFIG}/MiniClockify"

swift build -c "$CONFIG"

# Rebuild the app icon if source SVG is newer than the generated .icns.
if [ ! -f Resources/AppIcon.icns ] || [ miniclockify.svg -nt Resources/AppIcon.icns ]; then
  ./make-icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiniClockify"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Keychain + notifications work.
codesign --force --sign - --deep "$APP"

echo "Built $APP"
