#!/bin/bash
# Builds the release tarball of HiveMinds Host, on Linux: build/hiveminds-host-<version>-linux-<arch>.tar.gz
# The Swift runtime is built in, so it runs without Swift installed. Build on an old-enough distribution: the
# binary runs on that glibc and newer. From a Mac, scripts/build-host-x86_64.sh does all of this in the Lima VM.
# Usage: scripts/build-host-linux.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname)" = Linux ] || { echo "Run this on Linux. On a Mac, use scripts/build-host-x86_64.sh."; exit 1; }

VERSION=$(sed -n 's/^let hostVersion = "\(.*\)"$/\1/p' Sources/hiveminds-host/main.swift)
[ -n "$VERSION" ] || { echo "Couldn't read hostVersion from Sources/hiveminds-host/main.swift"; exit 1; }
ARCH=$(uname -m)
NAME="hiveminds-host-$VERSION-linux-$ARCH"

swift build -c release --static-swift-stdlib --product hiveminds-host
BIN="$(swift build -c release --show-bin-path)/hiveminds-host"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/$NAME"
cp "$BIN" "$STAGE/$NAME/hiveminds-host"
strip "$STAGE/$NAME/hiveminds-host"
cp packaging/hiveminds-host.service LICENSE "$STAGE/$NAME/"
scripts/third-party-notices.sh > "$STAGE/$NAME/THIRD-PARTY-NOTICES.txt"
cat > "$STAGE/$NAME/README.txt" <<TXT
HiveMinds Host $VERSION: runs HiveMinds projects and Claude Code agents on this machine.
https://github.com/eptkod/HiveMinds

On Arch or CachyOS, install the AUR package instead. Otherwise:
  sudo install -m755 hiveminds-host /usr/bin/
  install -Dm644 hiveminds-host.service ~/.config/systemd/user/hiveminds-host.service
It needs git, and Avahi (libdns_sd) so that devices can find it; without Avahi, pair by address.

  hiveminds-host projects add ~/code/my-project
  hiveminds-host serve                              # or: systemctl --user enable --now hiveminds-host
  hiveminds-host pair                               # for a host running as a service
TXT

# It must need nothing beyond what every Linux system has, and say the right version.
extra=$(ldd "$STAGE/$NAME/hiveminds-host" | grep -vE 'linux-vdso|ld-linux|lib(c|m|dl|rt|util|pthread|stdc\+\+|gcc_s)\.so' || true)
[ -z "$extra" ] || { echo "The binary needs libraries it shouldn't:"; echo "$extra"; exit 1; }
got=$("$STAGE/$NAME/hiveminds-host" --version)
[ "$got" = "hiveminds-host $VERSION" ] || { echo "Wrong version: $got"; exit 1; }

mkdir -p build
OUT="build/$NAME.tar.gz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name -czf "$OUT" "$NAME"
needs=$(objdump -T "$STAGE/$NAME/hiveminds-host" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
echo "Built $OUT ($(du -h "$OUT" | cut -f1), needs $needs or newer)"
sha256sum "$OUT"
