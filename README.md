# chord

Global keyboard + mouse hotkey daemon for macOS.

[日本語版 →](./README.ja.md)

```
[ cmd + shift - mouse.side1 ] → "screenshot the selection"
[ hyper - f24                ] → "open my secret terminal"
[ ctrl - scroll.up           ] → "zoom in (only inside Code)"
```

Where `skhd` and friends stop, chord starts:

| capability        | skhd / skhd.zig (Carbon)   | chord (CGEventTap) |
|-------------------|---------------------------|-----------------------|
| F1 – F20          | ✓                          | ✓                     |
| **F21 – F24**     | ✗ (no `kVK_*` constant)   | ✓                     |
| Mouse buttons     | ✗                          | ✓ left/right/middle/side1/side2 |
| Scroll wheel      | ✗                          | ✓ up/down/left/right  |
| Modifier chords   | ✓                          | ✓ + `hyper` sugar     |
| **Left/Right side modifiers** | ✗              | ✓ `rctrl` / `lcmd` / etc. (ZMK ULTRA_LL friendly) |
| **Wildcard fallbacks** | ✗                     | ✓ `[[fallbacks]]` + `*` for catch-all rules |
| **Shell-action aliases** | ✗                   | ✓ `[aliases]` + `@name` reuse |
| Accessibility     | not required               | required (one-time)   |

`chord` is hexagonal Swift 6 (Core / AdapterMacOS / AdapterTest /
App), the same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet). One TOML file
is the only thing you have to look at to know what it'll do — no
GUI, no settings panel, no persisted state.

## Status

⚠️ Pre-1.0. Not yet released on Homebrew; build from source.

## Install (from source)

Requires macOS 13+ and Xcode CommandLineTools (or full Xcode).

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

See [`config.toml`](./config.toml) for the full template with every
option commented inline.

## CLI

```
chord                run the daemon (default)
chord --debug        run the daemon with verbose logging
chord --validate          parse config.toml; exit 0 on clean
chord --validate --strict warnings + drops fail with exit 1 (for CI)
chord --doctor            report Accessibility / config / daemon
chord --reload       tell the running daemon to reload config
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
