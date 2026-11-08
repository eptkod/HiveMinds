#!/bin/bash
# From the Mac: builds HiveMinds Host's x86_64 Linux tarball and updates the AUR files to match it.
# Apple silicon can't build x86_64 Linux directly, so this uses the Lima VM (`hiveminds-linux`, with Rosetta on) and
# an Ubuntu 24.04 x86_64 chroot inside it, kept at /srv/hm-x86. Ubuntu 24.04 means glibc 2.39, so the binary runs
# there and on anything newer. The first run sets the chroot up (a few minutes); later runs reuse it.
# Usage: scripts/build-host-x86_64.sh [release-tag, e.g. v1.8.0]   (the tag goes into the PKGBUILDs)
set -euo pipefail
cd "$(dirname "$0")/.."
VM=hiveminds-linux
SWIFT=6.4.2
TAG="${1:-}"
REPO=$(pwd)

status=$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null || true)
[ -n "$status" ] || { echo "No Lima VM named $VM. See HANDOFF.md, 'Building and testing'."; exit 1; }
started=""
if [ "$status" != Running ]; then limactl start "$VM" >/dev/null 2>&1; started=1; fi
trap '[ -z "$started" ] || limactl stop "$VM" >/dev/null 2>&1 || true' EXIT
vm() { limactl shell "$VM" -- "$@" </dev/null; }

limactl shell "$VM" -- sudo bash -s "$SWIFT" 2>&1 <<'SETUP' | sed 's/^/  /'
set -euo pipefail
SWIFT=$1
R=/srv/hm-x86
[ -e /proc/sys/fs/binfmt_misc/rosetta ] || { echo "Rosetta isn't on in this VM"; exit 1; }
if [ ! -e $R/.ready ]; then
  echo "Setting up the x86_64 build chroot (once)..."
  # Unmount first: a leftover bind mount must never be deleted through.
  for m in proc dev; do if mountpoint -q $R/$m; then umount -l $R/$m; fi; done
  rm -rf --one-file-system $R; mkdir -p $R
  # Ubuntu's ready-made base image: debootstrap unmounts /proc part-way through, and Rosetta can't run without it.
  curl -fsSL https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz | tar -xz -C $R
  mount --bind /proc $R/proc; mount --bind /dev $R/dev
  cp /etc/resolv.conf $R/etc/resolv.conf
  chroot $R apt-get update -qq
  DEBIAN_FRONTEND=noninteractive chroot $R apt-get install -y -qq --no-install-recommends binutils ca-certificates curl g++ git gnupg libc6-dev libcurl4 \
    libedit2 libgcc-13-dev libncurses6 libpython3.12 libsqlite3-0 libstdc++-13-dev libxml2 libz3-4 pkg-config tzdata unzip zlib1g-dev >/dev/null
  chroot $R bash -c "cd /tmp && curl -fsSL -o s.tgz https://download.swift.org/swift-$SWIFT-release/ubuntu2404/swift-$SWIFT-RELEASE/swift-$SWIFT-RELEASE-ubuntu24.04.tar.gz && mkdir -p /opt/swift && tar -xzf s.tgz -C /opt/swift --strip-components=1 && rm s.tgz"
  touch $R/.ready
fi
mountpoint -q $R/proc || mount --bind /proc $R/proc
mountpoint -q $R/dev || mount --bind /dev $R/dev
cp /etc/resolv.conf $R/etc/resolv.conf
SETUP

echo "Copying the source..."
vm sudo bash -c "mkdir -p /srv/hm-x86/src && rsync -a --delete --exclude .build --exclude build --exclude spikes --exclude .git '$REPO/' /srv/hm-x86/src/"
echo "Building (slow under emulation)..."
vm sudo chroot /srv/hm-x86 env PATH=/opt/swift/usr/bin:/usr/bin:/bin HOME=/root LANG=C.UTF-8 bash -c 'cd /src && scripts/build-host-linux.sh' 2>&1 | tail -30

VERSION=$(sed -n 's/^let hostVersion = "\(.*\)"$/\1/p' Sources/hiveminds-host/main.swift)
NAME="hiveminds-host-$VERSION-linux-x86_64.tar.gz"
mkdir -p build
vm sudo cat "/srv/hm-x86/src/build/$NAME" > "build/$NAME"
SUM=$(shasum -a 256 "build/$NAME" | cut -d' ' -f1)
echo "build/$NAME  sha256 $SUM"

# Keep the AUR files in step with the tarball.
for d in packaging/aur/hiveminds-host-bin packaging/aur/hiveminds-host; do
  sed -i '' "s/^pkgver=.*/pkgver=$VERSION/" "$d/PKGBUILD"
  [ -z "$TAG" ] || sed -i '' "s/^_tag=.*/_tag=$TAG/" "$d/PKGBUILD"
done
sed -i '' "s/^sha256sums=.*/sha256sums=('$SUM')/" packaging/aur/hiveminds-host-bin/PKGBUILD
scripts/aur-srcinfo.sh
