# chord

Global keyboard + mouse hotkey daemon for macOS.

[日本語版 →](./README.ja.md)

```
[ cmd + shift - mouse.side1 ] → "screenshot the selection"
[ hyper - f24                ] → "open my secret terminal"
[ ctrl - scroll.up           ] → "zoom in (only inside VS Code)"
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
- **Vendor-HID "v-keys"** — fire on the raw vendor selector a
  ZMK keymap emits via `&vkey <id>` (its own HID usage page, so
  it can't clash with real keys); name ids in `[v-key-aliases]`
  and bind with a bare `input = "NAME"`. Needs Input Monitoring
  (see Install). (chord 0.10.0+)

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

- **`chord config --validate [--strict] [--json]`** — parse + lint
- **`chord config --show [--json] [--include-dropped]`** — current parsed config
- **`chord daemon --watch`** — live per-event trace
- **`chord config --doctor`** — accessibility + config + daemon status
- **`chord query --status` / `--vars` / `--loaded-bindings` / `--recent-fires`** —
  read live daemon state as JSON (for tmux status bars, shell prompts, scripts)

JSON output for `config --validate` / `config --show` conforms to the versioned
[`chord.bindings.v3` JSON Schema](docs/schema/chord.bindings.v3.json); `chord query`
emits the separate `chord.query.v1` wire format (live runtime state, not parsed config).

`chord` is hexagonal Swift 6 (Core / AdapterMacOS / AdapterTest /
App), the same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet). One TOML file
is the only thing you have to look at to know what it'll do — no
GUI, no settings panel, no persisted state. macOS Accessibility
grant is required once. (Only [v-key](#v-keys-vendor-hid-from-zmk)
bindings need a second grant — Input Monitoring — and only when one
is configured.)

## Install

```sh
brew install akira-toriyama/tap/chord

# One-time setup so the Accessibility grant persists across upgrades
$(brew --prefix)/share/chord/setup-signing-cert.sh   # create chord-dev identity
chord daemon --resign                                 # re-sign + restart

brew services start chord
```

After every subsequent `brew upgrade chord`, run `chord daemon --resign`
once — Homebrew's build sandbox can't touch your login keychain
during install, so the bundle is ad-hoc signed and the TCC
Accessibility grant would otherwise be lost on every upgrade.
`chord daemon --resign` swaps the ad-hoc signature for the persistent
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

**Input Monitoring (v-keys only).** If your config uses
[v-key](#v-keys-vendor-hid-from-zmk) bindings — vendor-HID keys a ZMK
keymap emits — chord additionally needs the **Input Monitoring**
grant, a *separate* TCC permission from Accessibility, in **System
Settings → Privacy & Security → Input Monitoring**. `Chord.app`
carries its own signing identity (distinct from your terminal), so
the GUI daemon needs its own grant even when the CLI already has
Accessibility. chord asks for it only when a v-key binding is
configured — non-v-key users are never prompted. `chord config
--doctor` reports it on the `input monitoring:` line.

## Configure

chord reads `~/.config/chord/config.toml`. Grab the template:

```sh
curl --create-dirs -o ~/.config/chord/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/chord/main/config.toml
```

Edit, then either restart the daemon or `chord daemon --reload`. chord
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

### v-keys (vendor HID from ZMK)

A **v-key** is a raw vendor-defined HID code a ZMK keyboard emits
through a `&vkey <id>` behavior — on its own usage page, so it never
collides with a real keystroke. chord reads it straight from the
keyboard (see **Input Monitoring** under [Install](#install)) and
routes it like any other trigger.

Name each id in a `[v-key-aliases]` table, then bind it with a
**bare** `input = "NAME"` — no `$`, because a v-key alias is a
complete trigger on its own (like `f13`):

```toml
[v-key-aliases]
KP_X1   = 0x01
TU_LL_Q = 0x10
TU_LL_C = 0x26

[[bindings]]
name = "v-key: app switcher"
input = "TU_LL_C"        # bare alias name — no $ prefix
action-shell = "open -a Safari"

[[fallbacks]]
name = "any unassigned v-key beeps"
input = "v-key"          # wildcard: every v-key with no binding
action-shell = "afplay /System/Library/Sounds/Tink.aiff"
```

v-keys flow through the normal matcher, so `apps`, `when-var`, and
`*-on-up` all work on a v-key binding. ids are `1`–`255` and alias
names are case-insensitive. v-keys carry no modifiers, so they are
**not** valid in `[[sequence]]` or `[[remap]]` (both compose a
modifier set onto the trigger).

If you drive chord from a
[canon](https://github.com/akira-toriyama/canon) keyboard, the
`[v-key-aliases]` block is generated from the ZMK keymap — copy it
from canon's
[`config/vkey-aliases.toml`](https://github.com/akira-toriyama/canon/blob/main/config/vkey-aliases.toml)
(produced by `scripts/gen-vkey-aliases.py`, the single source of
truth) into your `config.toml`.

See [`config.toml`](./config.toml) for the full template with every
option commented inline.

## CLI

```
chord                run the daemon (default)
chord config --validate          parse config.toml; exit 0 on clean
chord config --validate --strict warnings + drops fail with exit 1 (for CI)
chord config --validate --json   chord.bindings.v3 document + validation block
chord config --show              human-readable parsed config
chord config --show --json       machine-readable (chord.bindings.v3)
chord config --show --include-dropped   also list dropped bindings
chord config --doctor     report Accessibility / config / daemon
chord config --emit-schema   config.toml INPUT JSON Schema (Draft-07) for editor completion
chord config --observe    stream pressed keycodes / mouse buttons / modifier sides
                          live for discovery (nothing consumed; Ctrl-C to stop)
chord daemon --resign     re-sign Chord.app with chord-dev + restart
                          (run once after `brew install` / upgrade)
chord daemon --watch      live per-event trace (subscribes via
                          /tmp/chord-watch.log; Ctrl-C to exit)
chord daemon --reload      tell the running daemon to reload config
chord daemon --reload --dry-run   preview what `--reload` would change
chord daemon --quit        tell the running daemon to exit
chord daemon --pause       suspend all bindings (passthrough mode)
chord daemon --resume      re-enable bindings
chord daemon --toggle      flip paused ↔ resumed (handy as a hotkey)
chord daemon --show        print the last status line
chord query --status       live state as JSON: paused / ax-granted / uptime / config-loaded-at
chord query --vars         current state-variable values, as JSON
chord query --loaded-bindings   binding / fallback / alias counts, as JSON
chord query --recent-fires [--limit N]   recently fired bindings (newest first), as JSON
chord --help         this text
chord --version      print version
```

`daemon --pause` is the sane "I'm about to record a screencast / play a
game / share my screen on Zoom and don't want chord eating my
keystrokes" lever. The daemon stays loaded and AX-granted; it just
lets every event through until you `daemon --resume`. Bind `daemon --toggle` to
a hotkey for one-button suspend / resume:

```toml
[[bindings]]
name = "chord pause toggle"
input = "hyper - p"
action-shell = "chord daemon --toggle"
```

Logs go to `/tmp/chord.log`. Set `CHORD_DEBUG=1` (e.g. via `./run.sh`)
to also mirror to stderr. There is no `--debug` flag — passing one exits `2`.

The grammar is yabai-style `chord <domain> --<verb> [--mod]`, powered by
the shared sill CLIKit tokenizer (chord keeps its own verb vocabulary).
Each domain takes exactly one verb; combining verbs, or passing a flag
outside its domain, exits `2` (an unknown flag prints a "did you mean …?"
hint). The three domains are `config` (settings; standalone, no daemon),
`daemon` (lifecycle; needs a running daemon, exits `3` if none) and `query`
(read-only live state as JSON; needs a running daemon, exits `3` if none).
Exit codes: `0` ok / `1` (`config --validate --strict` tripped) / `2` usage /
`3` daemon-not-running. Note `--show` exists in **both** the config and daemon
domains and they differ: `config --show` lists the parsed config / bindings,
while `daemon --show` prints the daemon's runtime status line. To read live
runtime state structurally — current state-var values, recent fires — use
`chord query` (its own `chord.query.v1` socket, distinct from both).

## Migration (flat flags → yabai-style domains)

There is **no deprecation shim** — the old flat flags exit 2. Map:

| old | new |
| --- | --- |
| `chord --validate` | `chord config --validate` |
| `chord --doctor` | `chord config --doctor` |
| `chord --list` | `chord config --show` |
| `chord --reload` | `chord daemon --reload` |
| `chord --quit` | `chord daemon --quit` |
| `chord --pause` | `chord daemon --pause` |
| `chord --resume` | `chord daemon --resume` |
| `chord --toggle` | `chord daemon --toggle` |
| `chord --status` | `chord daemon --show` |
| `chord --watch` | `chord daemon --watch` |
| `chord --resign` | `chord daemon --resign` |

Two of these are **renames**, not just re-homings: `--list` becomes
`config --show` (not `config --list`), and `--status` becomes
`daemon --show`. The `--validate` modifiers (`--strict` / `--json`), the
`config --show` modifiers (`--json` / `--include-dropped`), and the
`daemon --reload` modifier (`--dry-run`) all carry over unchanged. Bare
`chord`, `chord --help` / `-h`, `chord --version` / `-V`, and the
`CHORD_DEBUG=1` env var are unaffected.

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
