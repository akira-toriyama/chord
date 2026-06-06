# chord

Global keyboard + mouse hotkey daemon for macOS.

[日本語版 →](./README.ja.md)

```
[ cmd + shift - mouse.side1 ] → "screenshot the selection"
[ hyper - f24                ] → "open my secret terminal"
[ ctrl - scroll.up           ] → "zoom in (only inside Code)"
```

Capabilities:

Triggers:

- **F1 – F24** (F21–F24 via Karabiner-compatible HID slots)
- **Mouse buttons**: left / right / middle / side1 / side2
- **Scroll wheel**: up / down / left / right
- **Modifier chords** with `hyper` sugar (= cmd+opt+ctrl+shift)
- **Left/Right side modifiers**: `rctrl`, `lcmd`, etc. — strict
  per-side matching for ZMK ULTRA_LL-style layered keyboards
- **Modifier-only triggers** — fire on bare modifier mask
  entry / exit, no primary key required (chord 0.9.0+)
- **`fn`-auto for arrow / nav keys** — macOS always tags those
  with `fn`; `input = "ctrl - right"` matches without spelling
  the bit out

Actions:

- **`action-shell`** — `/bin/zsh -l -c` exec, `$HOME` available
- **`action-keys`** — chord posts replacement keys
- **`action-keys` array** — multi-key sequence on one trigger
- **`action-shell` + `action-keys` on one binding** — fire-and-forget
  shell then post keys (Karabiner `to`-array shape)
- **`action-noop`** — eat the event
- **`action-native`** — `action-mission-control` (`show-all-windows`
  / `show-app-windows`) / `action-screenshot` (`selection` / `screen`)
  / `action-spotlight` (`true`) without shell-out
- **`action-set-var` / `action-toggle-var` / `action-hold-var`** —
  flat integer state machine (single-variable equality, no nested
  modes, deliberate narrow surface)
- **`action-*-on-up` halves** — fire on key release too
- **`passthrough = true`** — fire AND let the original key through
- **`repeat = fire-each | ignore | passthrough`** — per-binding
  autorepeat strategy

Gates:

- **`when-var` / `when-vars`** — single + multi-variable AND
  conditions (leader-key modes, etc.)
- **`hold-while`** / **`hold-while-timeout`** — variable's
  lifetime tied to a modifier mask or inactivity timer
- **`apps = [...]`** — per-binding glob allowlist + `!`-exclusion
- **`input-source = "..."`** — gate on macOS input source / IME
  / keyboard layout (chord 0.9.0+)

Sugars:

- **`[[fallbacks]]` + `*` wildcard** — catch-all rules for per-
  modifier-set "unmapped key" feedback sounds, etc.
- **`[[fallbacks]] inputs = [...]`** — collapse N modset fallbacks
  to one row
- **`[[remap]] map = { … }`** — bulk 1-to-1 modifier+key map
- **`[[sequence]]`** — leader-key syntactic sugar over the v2
  state-var machinery (recommended over hand-rolling Pattern 9)
- **`[[bindings.per-app]]`** — per-OS branching from one trigger
- **`[action-aliases]` + `@name(arg)`** — DRY repeated shell
  actions with `{{N}}` placeholder substitution
- **`[input-aliases]` + `$name`** — name a modifier set
  (`ULTRA_LL = "rctrl + ralt + rshift"` → `input = "$ULTRA_LL - c"`)

CI / introspection:

- **`chord --validate [--strict] [--json]`** — parse + lint
- **`chord --list [--json] [--include-dropped]`** — current parsed config
- **`chord --watch`** — live per-event trace
- **`chord --doctor`** — accessibility + config + daemon status

JSON output for `--validate` / `--list` conforms to the versioned
[`chord.bindings.v3` JSON Schema](docs/schema/chord.bindings.v3.json).

`chord` is hexagonal Swift 6 (Core / AdapterMacOS / AdapterTest /
App), the same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet). One TOML file
is the only thing you have to look at to know what it'll do — no
GUI, no settings panel, no persisted state. macOS Accessibility
grant is required once.

## Install

```sh
brew install akira-toriyama/tap/chord

# One-time setup so the Accessibility grant persists across upgrades
$(brew --prefix)/share/chord/setup-signing-cert.sh   # create chord-dev identity
chord --resign                                        # re-sign + restart

brew services start chord
```

After every subsequent `brew upgrade chord`, run `chord --resign`
once — Homebrew's build sandbox can't touch your login keychain
during install, so the bundle is ad-hoc signed and the TCC
Accessibility grant would otherwise be lost on every upgrade.
`chord --resign` swaps the ad-hoc signature for the persistent
`chord-dev` identity and restarts the daemon in one step.

Or build from source — requires macOS 13+ and Xcode CommandLineTools
(or full Xcode):

```sh
git clone https://github.com/akira-toriyama/chord
cd chord
swift build -c release
./scripts/install-cli.sh        # symlink .build/release/chord → ~/.local/bin/chord
```

For a Dock-less always-on daemon, run `./package.sh` to assemble
`Chord.app` and launch it via `open Chord.app`. The first launch
will prompt for Accessibility — grant it in **System Settings →
Privacy & Security → Accessibility**, then relaunch.

## Configure

chord reads `~/.config/chord/config.toml`. Grab the template:

```sh
curl --create-dirs -o ~/.config/chord/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/chord/main/config.toml
```

Edit, then either restart the daemon or `chord --reload`. chord
auto-reloads on file change too (vnode watcher; survives
atomic-save / rename).

Minimal example:

```toml
[options]
passthrough-unmatched = true
exclude-apps = []

[[bindings]]
name = "launch terminal"
input = "f13"
action-shell = "open -a Terminal"

[[bindings]]
name = "screenshot selection"
input = "mouse.side1"
action-keys = "cmd + shift - 4"
```

### Shell + keys on one press

Declare both `action-shell` and `action-keys` on a single binding to
run a command **and** post keys on the same key-down — Karabiner's
`to`-array shape. The shell fires first (fire-and-forget), then the
keys are posted, so the focused app still receives them:

```toml
[[bindings]]
name = "facet tree, then nav right"
input = "ctrl - right"
action-shell = "facet --view=tree --loading=2000"
action-keys  = "ctrl - right"
```

The original `ctrl - right` is consumed; the re-posted one is tagged
synthetic so it never re-triggers the binding. Only this pair
combines — `action-noop` / `action-set-var` stay single-action.

### Leader-key modes (v2)

Karabiner-style two-stroke bindings — press a "leader" chord to
arm a mode, then a follow-up key under the still-held modifiers
fires the action. The mode auto-clears when the modifiers are
released:

```toml
[[bindings]]
name = "wm: enter mode"
input = "cmd + opt - j"
action-set-var = "wm"
hold-while = "cmd + opt"

[[bindings]]
name = "wm: maximize"
input = "cmd + opt - k"
when-var = "wm"
action-shell = "yabai -m window --grid 1:1:0:0:1:1"

[[bindings]]
name = "wm: snap left/right (down/up)"
input = "cmd + opt - l"
when-var = "wm"
action-shell        = "yabai -m window --grid 1:2:0:0:1:1"
action-shell-on-up  = "yabai -m window --grid 1:2:1:0:1:1"
```

`action-set-var` writes a flat integer variable; `when-var` gates
on it; `hold-while` ties the variable's lifetime to a modifier
mask; `action-*-on-up` fires on the release half. The state
surface is deliberately narrow — single-variable equality, no
nested modes. See Pattern 9 in [`config.toml`](./config.toml) for
the full annotated example.

See [`config.toml`](./config.toml) for the full template with every
option commented inline.

## CLI

```
chord                run the daemon (default)
chord --validate          parse config.toml; exit 0 on clean
chord --validate --strict warnings + drops fail with exit 1 (for CI)
chord --validate --json   chord.bindings.v3 document + validation block
chord --list              human-readable parsed config
chord --list --json       machine-readable (chord.bindings.v3)
chord --list --include-dropped   also list dropped bindings
chord --doctor            report Accessibility / config / daemon
chord --resign            re-sign Chord.app with chord-dev + restart
                          (run once after `brew install` / upgrade)
chord --watch             live per-event trace (subscribes via
                          /tmp/chord-watch.log; Ctrl-C to exit)
chord --reload       tell the running daemon to reload config
chord --reload --dry-run   preview what `--reload` would change
chord --quit         tell the running daemon to exit
chord --pause        suspend all bindings (passthrough mode)
chord --resume       re-enable bindings
chord --toggle       flip paused ↔ resumed (handy as a hotkey)
chord --status       print the last status line
chord --help         this text
chord --version      print version
```

`--pause` is the sane "I'm about to record a screencast / play a
game / share my screen on Zoom and don't want chord eating my
keystrokes" lever. The daemon stays loaded and AX-granted; it just
lets every event through until you `--resume`. Bind `--toggle` to
a hotkey for one-button suspend / resume:

```toml
[[bindings]]
name = "chord pause toggle"
input = "hyper - p"
action-shell = "chord --toggle"
```

Logs go to `/tmp/chord.log`. Set `CHORD_DEBUG=1` (e.g. via `./run.sh`)
to also mirror to stderr. There is no `--debug` flag — passing one exits `2`.

## Architecture

```
ChordCore           pure logic — bindings, TOML, matcher, keycodes
ChordAdapterMacOS   CGEventTap, NSWorkspace, CGEvent post (the only
                    module that imports AppKit / CoreGraphics types)
ChordAdapterTest    synthetic EventSource for integration tests
ChordApp            executable — @main, CLI, Controller, IPC
```

The CGEventTap callback runs on its own run loop and *must* decide
consume / pass synchronously, so the consumer of `EventSource` is a
closure invoked inline from the tap callback — not an AsyncStream.
See [CLAUDE.md](./CLAUDE.md) for the full layering rules and
non-obvious constraints.

## License

MIT. See [LICENSE](./LICENSE).
