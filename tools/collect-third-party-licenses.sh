#!/bin/sh
# Collects the license/notice texts of all SwiftPM dependencies pinned in Package.resolved.
# Usage: collect-third-party-licenses.sh <checkouts-dir> <Package.resolved> <out-dir>
# Only files that really exist in the checkouts are copied (LICENSE*, NOTICE*, COPYING*, UNLICENSE at the top
# level of each package, plus the license of the vendored llhttp in swift-nio). Nothing is generated or edited.
# Used by the Dockerfile (build stage, texts of the exact resolved versions) and to refresh third-party-licenses/.
set -eu

checkouts=$1
resolved=$2
out=$3

[ -d "$checkouts" ] && [ -f "$resolved" ] || { echo "usage: $0 <checkouts-dir> <Package.resolved> <out-dir>" >&2; exit 2; }

rm -rf "$out"
mkdir -p "$out"

# INDEX.txt: identity, version, revision and source URL per pin, taken from Package.resolved.
awk '
  /"identity"/ { gsub(/[",]/, ""); id = $3 }
  /"location"/ { gsub(/[",]/, ""); loc = $3 }
  /"revision"/ { gsub(/[",]/, ""); rev = $3 }
  /"version" : "/ { gsub(/[",]/, ""); printf "%s %s %s %s\n", id, $3, rev, loc }
' "$resolved" | sort > "$out/INDEX.txt"

missing=0
while read -r id version _; do
  # Checkout directory names follow the repository name, which can differ in case from the identity.
  dir=$(find "$checkouts" -maxdepth 1 -mindepth 1 -type d -iname "$id" | head -n 1)
  if [ -z "$dir" ]; then
    echo "no checkout for $id" >&2
    missing=1
    continue
  fi
  mkdir -p "$out/$id"
  found=0
  for f in "$dir"/LICENSE* "$dir"/NOTICE* "$dir"/COPYING* "$dir"/UNLICENSE*; do
    [ -f "$f" ] || continue
    [ -e "$out/$id/$(basename "$f")" ] && continue
    cp "$f" "$out/$id/"
    found=1
  done
  if [ "$id" = swift-nio ] && [ -f "$dir/Sources/CNIOLLHTTP/LICENSE" ]; then
    cp "$dir/Sources/CNIOLLHTTP/LICENSE" "$out/$id/LICENSE.CNIOLLHTTP"
    found=1
  fi
  [ "$found" = 1 ] || { echo "no license file in $id $version" >&2; missing=1; }
done < "$out/INDEX.txt"

chmod -R u+w,a+r "$out"
exit "$missing"
