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
bundle="Chord.app"
if [[ "${1:-}" == "--dev" ]]; then
  variant="dev"
  bundle="Chord-dev.app"
fi

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $bundle"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"

cp .build/release/chord "$bundle/Contents/MacOS/chord"
cp Info.plist "$bundle/Contents/Info.plist"
# The dev bundle's Info.plist is DERIVED from the single source (Info.plist)
# at package time — no checked-in twin to drift. Distinct id/name so it
# co-exists with a brew Chord.app; -dev version; "(dev build)" TCC prompts.
if [[ "$variant" == "dev" ]]; then
  dest="$bundle/Contents/Info.plist"
  ver=$(plutil -extract CFBundleShortVersionString raw Info.plist)
  plutil -replace CFBundleDisplayName        -string "chord (dev)"         "$dest"
  plutil -replace CFBundleName               -string "chord-dev"           "$dest"
  plutil -replace CFBundleIdentifier         -string "com.chord.chord.dev" "$dest"
  plutil -replace CFBundleShortVersionString -string "${ver}-dev"          "$dest"
  for key in NSAccessibilityUsageDescription NSInputMonitoringUsageDescription; do
    d=$(plutil -extract "$key" raw "$dest")
    plutil -replace "$key" -string "${d/chord/chord (dev build)}" "$dest"
  done
fi
if [[ -f assets/icon/chord.icns ]]; then
  cp assets/icon/chord.icns "$bundle/Contents/Resources/AppIcon.icns"
fi

# Sign with the persistent self-signed identity if it exists. The
# identity is written to .signing-id by setup-signing-cert.sh.
# (`find-identity -p codesigning` lists *trusted* identities only;
# our self-signed cert is intentionally untrusted, so we can't use
# it as the detection probe — same trap facet documents.)
identity=""
if [[ -f .signing-id ]]; then
  identity="$(cat .signing-id)"
fi
if [[ -n "$identity" ]] && \
   security find-certificate -c "$identity" \
     "$HOME/Library/Keychains/login.keychain-db" \
     >/dev/null 2>&1; then
  echo "→ signing with '$identity' identity"
  codesign --force --options runtime --sign "$identity" "$bundle"
else
  echo "→ no persistent identity found; ad-hoc signing"
  echo "  (run ./setup-signing-cert.sh to make AX grant stable)"
  codesign --force --sign - "$bundle"
fi

echo "→ $bundle ready ($(du -sh "$bundle" | awk '{print $1}'))"
