#!/bin/bash
# Runs HiveMindsCore's tests (Swift Testing). Usage: scripts/test-core.sh [extra swift test arguments]
# On a Mac with Command Line Tools only, the tests build with the default SDK and without the app target,
# in their own build folder so they don't disturb the app's build.
set -euo pipefail
cd "$(dirname "$0")/.."
unset SDKROOT
export HIVEMINDS_CORE_ONLY=1
SCRATCH=${HIVEMINDS_TEST_SCRATCH:-.build/core-tests}
# With Command Line Tools, the compiler sometimes isn't told where Swift Testing's macro plugin is ("plugin for
# module 'TestingMacros' not found"). Say so explicitly when the toolchain has it there.
PLUGINS=()
TOOLCHAIN_PLUGINS="$(dirname "$(dirname "$(xcrun --find swift 2>/dev/null || command -v swift)")")/lib/swift/host/plugins/testing"
if [ -f "$TOOLCHAIN_PLUGINS/libTestingMacros.dylib" ]; then
  PLUGINS=(-Xswiftc -plugin-path -Xswiftc "$TOOLCHAIN_PLUGINS")
fi
for attempt in 1 2 3; do
  if out=$(swift build --build-tests --scratch-path "$SCRATCH" "${PLUGINS[@]+"${PLUGINS[@]}"}" 2>&1); then break; fi
  if [ $attempt = 3 ] || ! grep -q "TestingMacros" <<<"$out"; then echo "$out" >&2; exit 1; fi
done
swift test --skip-build --scratch-path "$SCRATCH" "${PLUGINS[@]+"${PLUGINS[@]}"}" "$@"
