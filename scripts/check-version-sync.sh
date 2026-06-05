#!/usr/bin/env bash
# check-version-sync.sh — assert ChordVersion.current matches the
# bundle plists. Run in CI (build.yml) and at release time.
#
# Why this exists: the v0.8.0 bump commit (81cd3bf) had to touch 3
# files in lock-step (Info.plist, Info.plist.dev, Main.swift). One
# of them silently drifting is a real failure mode — `chord
# --version` reporting an old number while the app bundle is on a
# newer release is exactly the kind of bug nobody notices.
#
# Source of truth: Sources/ChordCore/Version.swift `ChordVersion.current`.
# Info.plist must match exactly; Info.plist.dev must match with a
# `-dev` suffix.

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
plist_dev_version=$(plutil -extract CFBundleShortVersionString raw Info.plist.dev)

fail=0
if [[ "$swift_version" != "$plist_version" ]]; then
  echo "version mismatch: ChordVersion.current=$swift_version Info.plist=$plist_version" >&2
  fail=1
fi
if [[ "${swift_version}-dev" != "$plist_dev_version" ]]; then
  echo "version mismatch: expected Info.plist.dev=${swift_version}-dev got $plist_dev_version" >&2
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "to fix: bump all three to the same number (Info.plist gets bare X.Y.Z, Info.plist.dev gets X.Y.Z-dev)" >&2
  exit 1
fi

echo "version sync OK: $swift_version"
