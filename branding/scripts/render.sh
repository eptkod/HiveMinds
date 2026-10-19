#!/bin/bash
# Re-renders every brand asset and the app icon. Usage: branding/scripts/render.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# Same SDK choice as scripts/build-app.sh: the 27 SDK needs full Xcode.
if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

swift branding/scripts/render.swift branding
iconutil -c icns branding/icon/HiveMinds.iconset -o branding/icon/HiveMinds.icns
echo "Wrote branding/icon/HiveMinds.icns"
