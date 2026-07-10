#!/bin/bash
# Builds EnsoLab.app and syncs it to /Applications so it launches from
# Finder/Spotlight. Re-run after any change to update the installed app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
swift scripts/make-icon.swift .build/AppIcon.icns

APP=".build/EnsoLab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EnsoLab "$APP/Contents/MacOS/EnsoLab"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null

rm -rf /Applications/EnsoLab.app
cp -R "$APP" /Applications/EnsoLab.app
touch /Applications/EnsoLab.app # nudge Finder/LaunchServices to refresh the icon
echo "Installed /Applications/EnsoLab.app"
