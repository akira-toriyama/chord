#!/usr/bin/env bash
# install-launchagent.sh — install Chord.app and register the
# LaunchAgent that boots chord at login (and restarts it if it
# crashes, courtesy of KeepAlive).
#
# Usage:
#   ./scripts/install-launchagent.sh             # install to /Applications
#   ./scripts/install-launchagent.sh --user      # install to ~/Applications
#   APP_DEST=/path/to/Chord.app ./scripts/install-launchagent.sh
#
# Idempotent: if the LaunchAgent is already loaded, the script
# unloads it cleanly first, swaps the app bundle, then re-loads.

set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.chord.chord"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PLIST_TEMPLATE="packaging/launchd/${LABEL}.plist.in"

# Pick destination.
if [[ "${1:-}" == "--user" ]]; then
  APP_DEST="${APP_DEST:-$HOME/Applications/Chord.app}"
else
  APP_DEST="${APP_DEST:-/Applications/Chord.app}"
fi
APP_PARENT="$(dirname "$APP_DEST")"

# 1) Ensure Chord.app exists in the repo. If not, build + package it.
if [[ ! -d Chord.app ]]; then
  echo "→ no Chord.app in repo — running ./package.sh"
  ./package.sh
fi

# 2) Stop the running chord (LaunchAgent or otherwise) before
#    swapping the bundle. macOS will hand the user permission
#    dialogs back to whoever launched the new binary, so a clean
#    teardown keeps the AX-grant story coherent.
UID_=$(id -u)
if launchctl list 2>/dev/null | awk '{print $3}' | grep -q "^${LABEL}\$"; then
  echo "→ unloading existing LaunchAgent"
  launchctl bootout "gui/$UID_/${LABEL}" 2>/dev/null || true
fi
pkill -f "Chord\.app/Contents/MacOS/chord"   2>/dev/null || true
pkill -f "\.build/(debug|release)/chord"    2>/dev/null || true
sleep 0.3

# 3) Install the .app bundle to its destination.
mkdir -p "$APP_PARENT"
if [[ -d "$APP_DEST" ]]; then
  echo "→ removing existing $APP_DEST"
  rm -rf "$APP_DEST"
fi
echo "→ copying Chord.app → $APP_DEST"
cp -R Chord.app "$APP_DEST"

# 4) Render the LaunchAgent plist.
echo "→ writing $PLIST_DEST"
mkdir -p "$(dirname "$PLIST_DEST")"
sed "s|@@APP@@|${APP_DEST}|g" "$PLIST_TEMPLATE" > "$PLIST_DEST"

# 5) Bootstrap it. `gui/$UID` is the per-user session domain — the
#    right place for an interactive LaunchAgent (system domain would
#    be wrong: no Accessibility grant, no frontmost-app events).
echo "→ launchctl bootstrap gui/$UID_"
launchctl bootstrap "gui/$UID_" "$PLIST_DEST"

# 6) Verify.
sleep 0.5
if launchctl list 2>/dev/null | awk '{print $3}' | grep -q "^${LABEL}\$"; then
  echo "✓ ${LABEL} loaded"
  pgrep -f "Chord\.app/Contents/MacOS/chord" >/dev/null \
    && echo "✓ chord process running" \
    || echo "! chord process not running yet (launchd may be starting it)"
else
  echo "! LaunchAgent failed to load; check /tmp/chord-launchd.log"
  exit 1
fi

cat <<EOF

next:
  • If the system shows an Accessibility prompt, grant Chord.app in
    System Settings → Privacy & Security → Accessibility (one time;
    the grant survives across rebuilds as long as the chord-dev
    signing identity stays in your login keychain).
  • Tail the log:  tail -f /tmp/chord.log
  • Status:        chord --status
  • Reload config: chord --reload
  • Stop / disable:./scripts/uninstall-launchagent.sh
EOF
