# chord

Global keyboard + mouse hotkey daemon for macOS.

[日本語版 →](./README.ja.md)

```
[ cmd + shift - mouse.side1 ] → "screenshot the selection"
[ hyper - f24                ] → "open my secret terminal"
[ ctrl - scroll.up           ] → "zoom in (only inside Code)"
```

Capabilities:

- **F1 – F24** (F21–F24 via Karabiner-compatible HID slots)
- **Mouse buttons**: left / right / middle / side1 / side2
- **Scroll wheel**: up / down / left / right
- **Modifier chords** with `hyper` sugar (= cmd+opt+ctrl+shift)
- **Left/Right side modifiers**: `rctrl`, `lcmd`, etc. — strict
  per-side matching for ZMK ULTRA_LL-style layered keyboards
- **`[[fallbacks]]` + `*` wildcard** for catch-all rules
  (per-modifier-set "unmapped key" feedback sounds, etc.)
- **`[aliases]` + `@name`** to DRY repeated shell actions
- **`[input-aliases]`** for bare-reference modifier-set names in
  `input = "…"` (e.g. `ULTRA_LL = "rctrl + ralt + rshift"` →
  `input = "ULTRA_LL - c"`)
- **`chord --list --json` / `chord --validate --json`** for CI
  consumption, both conforming to a versioned
  [`chord.bindings.v1` JSON Schema](docs/schema/chord.bindings.v1.json)

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
chord --debug        run the daemon with verbose logging
chord --validate          parse config.toml; exit 0 on clean
chord --validate --strict warnings + drops fail with exit 1 (for CI)
chord --validate --json   chord.bindings.v1 document + validation block
chord --list              human-readable parsed config
chord --list --json       machine-readable (chord.bindings.v1)
chord --list --include-dropped   also list dropped bindings
chord --doctor            report Accessibility / config / daemon
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

Logs go to `/tmp/chord.log`. `--debug` also mirrors to stderr.

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
