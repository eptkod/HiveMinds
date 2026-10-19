#!/bin/bash
# Packages build/HiveMinds.app into build/HiveMinds-<version>.dmg. Usage: scripts/build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
APP=build/HiveMinds.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/HiveMinds-$VERSION.dmg"

# The disk image holds the app and a shortcut to Applications, so installing is one drag.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "HiveMinds" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG"
