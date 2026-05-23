#!/usr/bin/env bash
# package.sh — assemble Chord.app from the release binary.
#
#   ./package.sh           → Chord.app     (id: com.chord.chord)
#   ./package.sh --dev     → Chord-dev.app (id: com.chord.chord.dev)
#
# The --dev variant has a distinct bundle id so it can co-exist
# with a brew-installed Chord.app without TCC accessibility-grant
# collisions. Same pattern as stroke / facet.

set -euo pipefail

cd "$(dirname "$0")"

variant="release"
plist="Info.plist"
bundle="Chord.app"
if [[ "${1:-}" == "--dev" ]]; then
  variant="dev"
  plist="Info.plist.dev"
  bundle="Chord-dev.app"
fi

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $bundle"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"

cp .build/release/chord "$bundle/Contents/MacOS/chord"
cp "$plist" "$bundle/Contents/Info.plist"
if [[ -f assets/icon/chord.icns ]]; then
  cp assets/icon/chord.icns "$bundle/Contents/Resources/AppIcon.icns"
fi

# Sign with the persistent self-signed identity if it exists.
if security find-identity -p codesigning login.keychain-db \
    2>/dev/null | grep -q '"chord-dev"'; then
  echo "→ signing with chord-dev identity"
  codesign --force --options runtime --sign chord-dev "$bundle"
else
  echo "→ no chord-dev identity found; ad-hoc signing"
  echo "  (run ./setup-signing-cert.sh to make AX grant stable)"
  codesign --force --sign - "$bundle"
fi

echo "→ $bundle ready ($(du -sh "$bundle" | awk '{print $1}'))"
