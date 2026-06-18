#!/usr/bin/env bash
# check-version-sync.sh — assert ChordVersion.current matches Info.plist.
# Run in CI (build.yml) and at release time.
#
# Why this exists: `chord --version` reporting an old number while the app
# bundle is on a newer release is exactly the kind of bug nobody notices.
# The dev bundle's version is DERIVED from Info.plist at package time
# (package.sh --dev appends `-dev`), so only Info.plist needs guarding here.
#
# Source of truth: Sources/ChordCore/Version.swift `ChordVersion.current`.

set -euo pipefail

cd "$(dirname "$0")/.."

swift_version=$(
  grep -E 'public static let current = "' Sources/ChordCore/Version.swift \
    | sed -E 's/.*"([^"]+)".*/\1/'
)
if [[ -z "$swift_version" ]]; then
  echo "error: could not parse ChordVersion.current from Sources/ChordCore/Version.swift" >&2
  exit 1
fi

plist_version=$(plutil -extract CFBundleShortVersionString raw Info.plist)

if [[ "$swift_version" != "$plist_version" ]]; then
  echo "version mismatch: ChordVersion.current=$swift_version Info.plist=$plist_version" >&2
  echo "" >&2
  echo "to fix: bump both to the same X.Y.Z (Info.plist + ChordVersion.current)" >&2
  exit 1
fi

echo "version sync OK: $swift_version"
