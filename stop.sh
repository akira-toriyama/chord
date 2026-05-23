#!/usr/bin/env bash
# stop.sh — kill all chord instances (release / dev / raw SwiftPM).

set -euo pipefail

echo "→ killing chord (release app bundle)"
pkill -f "Chord(-dev)?\.app/Contents/MacOS/chord" 2>/dev/null || true

echo "→ killing chord (SwiftPM .build/*/chord)"
pkill -f "\.build/(debug|release)/chord" 2>/dev/null || true

echo "→ killing chord (homebrew / installed)"
pkill -x "chord" 2>/dev/null || true

# Give launchd a beat to notice before reporting status.
sleep 0.3

if pgrep -lf chord >/dev/null; then
  echo "still running:"
  pgrep -lf chord
  exit 1
fi
echo "all stopped"
