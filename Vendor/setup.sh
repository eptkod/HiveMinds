#!/bin/bash
# Rebuilds Vendor/SwiftTerm from upstream SwiftTerm 1.11.2 plus swiftterm-1.11.2-hiveminds.patch, keeping only
# what the build needs. The result is checked in; run this only to check or redo it:
#   mv Vendor/SwiftTerm /tmp/old && Vendor/setup.sh && diff -r /tmp/old Vendor/SwiftTerm
set -euo pipefail
cd "$(dirname "$0")"
[ -d SwiftTerm ] && { echo "Vendor/SwiftTerm already exists; move it away first"; exit 1; }
git -c advice.detachedHead=false clone --quiet --depth 1 --branch v1.11.2 https://github.com/migueldeicaza/SwiftTerm.git SwiftTerm
(cd SwiftTerm && git apply -p2 ../swiftterm-1.11.2-hiveminds.patch)
cd SwiftTerm
rm -rf .git .github .swiftpm Benchmarks TerminalApp Tests Makefile scripts TestPlan.xctestplan TODO.md CODE_OF_CONDUCT.md \
  SECURITY.md Sources/SwiftTermFuzz Sources/Termcast Sources/CaptureOutput Sources/SwiftTerm/Documentation.docc
echo "Vendor/SwiftTerm is ready"
