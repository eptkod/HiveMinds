#!/bin/bash
# Copies this repo's source (no build folders) to a Linux machine over SSH, for building and testing
# HiveMinds Host there. See docs/HOST-TESTING.md.
# Usage: scripts/copy-to-linux.sh user@address [folder]     (folder defaults to ~/HiveMinds)
# Run it again after changes: only what changed is sent.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?Usage: scripts/copy-to-linux.sh user@address [folder]}"
FOLDER="${2:-HiveMinds}"
rsync -az --delete \
  --exclude '.build/' --exclude '/build/' --exclude '.git/' --exclude '.swiftpm/' --exclude '.DS_Store' \
  --exclude 'spikes/*/.build/' \
  ./ "$TARGET:$FOLDER/"
echo "Copied to $TARGET:$FOLDER"
