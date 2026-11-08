#!/bin/bash
# Prints the licences of the libraries built into HiveMinds and HiveMinds Host. Run it after a build, which is what
# fetches them. Usage: scripts/third-party-notices.sh > THIRD-PARTY-NOTICES.txt
set -euo pipefail
cd "$(dirname "$0")/.."
ls .build/checkouts/swift-nio >/dev/null 2>&1 || { echo "Build first: .build/checkouts is empty." >&2; exit 1; }
echo "HiveMinds includes the following open-source software. Their licences follow."
echo "It is also built with the Swift standard library (Apache-2.0 with Runtime Library Exception, https://swift.org/LICENSE.txt)."
show() {  # name, folder
  local f
  for f in "$2"/LICENSE* "$2"/NOTICE*; do
    [ -f "$f" ] || continue
    printf '\n\n================================================================================\n%s (%s)\n================================================================================\n\n' "$1" "$(basename "$f")"
    cat "$f"
  done
}
show SwiftTerm Vendor/SwiftTerm
for d in .build/checkouts/*/; do
  name=$(basename "$d")
  # SwiftTerm comes from Vendor/, whatever an old checkout left behind.
  [ "$name" = SwiftTerm ] || show "$name" "${d%/}"
done
