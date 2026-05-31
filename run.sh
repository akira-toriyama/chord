#!/usr/bin/env bash
# run.sh — build chord release, kill any running instance, launch.
#
# Matches stroke / facet's developer-loop convention so the agent
# can iterate without asking the user to relaunch by hand.

set -euo pipefail

cd "$(dirname "$0")"

LOG=/tmp/chord-run.log

echo "→ swift build -c release"
swift build -c release

echo "→ killing existing chord instances"
pkill -f "chord(\.app)?/Contents/MacOS/chord" 2>/dev/null || true
pkill -x "chord" 2>/dev/null || true
sleep 0.2

if [[ "${1:-}" == "--app" ]]; then
  if [[ ! -d Chord.app ]]; then
    ./package.sh
  fi
  echo "→ open Chord.app (CHORD_DEBUG=1)"
  open Chord.app --env CHORD_DEBUG=1
else
  echo "→ launching CHORD_DEBUG=1 .build/release/chord (foreground, logging to $LOG)"
  CHORD_DEBUG=1 .build/release/chord 2>&1 | tee "$LOG"
fi
