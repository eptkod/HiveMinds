#!/bin/bash
# Writes .SRCINFO for the AUR packages from their PKGBUILDs (what `makepkg --printsrcinfo` makes, without needing Arch).
# Usage: scripts/aur-srcinfo.sh
set -euo pipefail
cd "$(dirname "$0")/../packaging/aur"
for d in hiveminds-host-bin hiveminds-host; do
  ( cd "$d"; unset pkgbase
    # shellcheck disable=SC1091
    source ./PKGBUILD
    {
      echo "pkgbase = $pkgname"
      printf '\tpkgdesc = %s\n\tpkgver = %s\n\tpkgrel = %s\n\turl = %s\n\tinstall = %s\n' "$pkgdesc" "$pkgver" "$pkgrel" "$url" "$install"
      for a in "${arch[@]}"; do printf '\tarch = %s\n' "$a"; done
      for a in "${license[@]}"; do printf '\tlicense = %s\n' "$a"; done
      for a in ${makedepends[@]+"${makedepends[@]}"}; do printf '\tmakedepends = %s\n' "$a"; done
      for a in "${depends[@]}"; do printf '\tdepends = %s\n' "$a"; done
      for a in "${optdepends[@]}"; do printf '\toptdepends = %s\n' "$a"; done
      for a in ${provides[@]+"${provides[@]}"}; do printf '\tprovides = %s\n' "$a"; done
      for a in "${conflicts[@]}"; do printf '\tconflicts = %s\n' "$a"; done
      for a in "${options[@]}"; do printf '\toptions = %s\n' "$a"; done
      for a in "${source[@]}"; do printf '\tsource = %s\n' "$a"; done
      for a in "${sha256sums[@]}"; do printf '\tsha256sums = %s\n' "$a"; done
      printf '\npkgname = %s\n' "$pkgname"
    } > .SRCINFO )
done
