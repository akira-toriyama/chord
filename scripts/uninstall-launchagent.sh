#!/usr/bin/env bash
# uninstall-launchagent.sh — stop chord, unregister its LaunchAgent,
# and (optionally) remove the installed Chord.app.
#
# Usage:
#   ./scripts/uninstall-launchagent.sh
#   ./scripts/uninstall-launchagent.sh --purge      # also delete Chord.app
#   ./scripts/uninstall-launchagent.sh --purge-all  # also delete config

set -euo pipefail

LABEL="com.chord.chord"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_=$(id -u)

if launchctl list 2>/dev/null | awk '{print $3}' | grep -q "^${LABEL}\$"; then
  echo "→ launchctl bootout gui/$UID_/$LABEL"
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
fi

if [[ -f "$PLIST" ]]; then
  echo "→ removing $PLIST"
  rm -f "$PLIST"
fi

# Kill any stragglers (release binary, dev bundle, app bundle).
pkill -f "Chord(-dev)?\.app/Contents/MacOS/chord" 2>/dev/null || true
pkill -f "\.build/(debug|release)/chord"          2>/dev/null || true
pkill -x "chord"                                  2>/dev/null || true

case "${1:-}" in
  --purge|--purge-all)
    for p in /Applications/Chord.app "$HOME/Applications/Chord.app"; do
      if [[ -d "$p" ]]; then
        echo "→ removing $p"
        rm -rf "$p"
      fi
    done
    ;;
esac
if [[ "${1:-}" == "--purge-all" ]]; then
  cfg="$HOME/.config/chord"
  if [[ -d "$cfg" ]]; then
    echo "→ removing $cfg"
    rm -rf "$cfg"
  fi
fi

echo "✓ chord LaunchAgent uninstalled"
