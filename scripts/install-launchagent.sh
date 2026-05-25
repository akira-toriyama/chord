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

# 0) Coexistence guard. If `brew install akira-toriyama/tap/chord`
#    is also installed, both LaunchAgents would race for the event
#    tap and the user gets two chord daemons fighting over input.
#    Refuse and explain — the user can `brew uninstall chord` or
#    pick one path explicitly via CHORD_ALLOW_BREW_COEXIST=1.
if command -v brew >/dev/null 2>&1 \
    && brew list --formula chord >/dev/null 2>&1 \
    && [[ "${CHORD_ALLOW_BREW_COEXIST:-0}" != "1" ]]; then
  cat >&2 <<EOF
chord: refusing to install — a brew-managed chord is also present.
       Two LaunchAgents (com.chord.chord + homebrew.mxcl.chord) would
       compete for the event tap.

       Pick ONE path:
         A) Stay with brew (recommended for general use):
              brew services stop chord       # if started
              # then nothing else to do — brew already manages it.
         B) Switch to the in-repo install:
              brew services stop chord && brew uninstall chord
              ./scripts/install-launchagent.sh

       Bypass this guard at your own risk:
         CHORD_ALLOW_BREW_COEXIST=1 ./scripts/install-launchagent.sh
EOF
  exit 2
fi

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
# Scoped kill — see uninstall-launchagent.sh for the brew-coexist
# rationale. We only target THIS install's process family.
pkill -f "(/Applications|$HOME/Applications)/Chord(-dev)?\.app/Contents/MacOS/chord" \
  2>/dev/null || true
pkill -f "/Users/.*/dev/chord/\.build/(debug|release)/chord" \
  2>/dev/null || true
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
