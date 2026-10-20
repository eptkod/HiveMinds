#!/bin/bash
# Builds HiveMinds.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

# The macOS 27 SDK makes SwiftUI's @State a macro whose plugin ships only with full Xcode.
# Command Line Tools still have the 26.5 SDK, which has Liquid Glass and the plain property wrapper.
if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/HiveMinds.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HiveMinds" "$APP/Contents/MacOS/HiveMinds"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# App icon. Regenerate it with branding/scripts/render.sh after changing the design.
cp branding/icon/HiveMinds.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional Whisper helper for dictation (Settings > Voice). Built once and cached; HIVEMINDS_NO_WHISPER=1 leaves it out.
if [ -z "${HIVEMINDS_NO_WHISPER:-}" ]; then
  if scripts/build-whisper-helper.sh; then
    cp build/whisper/hiveminds-whisper "$APP/Contents/MacOS/hiveminds-whisper"
    codesign --force --sign - "$APP/Contents/MacOS/hiveminds-whisper" >/dev/null
  else
    echo "warning: the Whisper helper didn't build, so dictation will only offer Apple's engine" >&2
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HiveMinds</string>
  <key>CFBundleDisplayName</key><string>HiveMinds</string>
  <key>CFBundleIdentifier</key><string>com.ethan.hiveminds</string>
  <key>CFBundleExecutable</key><string>HiveMinds</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.0</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Dictation listens only while you hold the dictation key. Audio stays on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Dictation turns what you say into text on this Mac.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
