# CLAUDE.md

Guidance for working in this repository.

## What this is

`chord` — global keyboard + mouse hotkey daemon for macOS. Built
around one idea: **every binding is a chord of inputs**, where the
"notes" can be modifier keys, ordinary keys (incl. F13–F24), mouse
buttons (incl. side1/side2), or scroll-wheel deltas. Each chord
maps to one of three actions: post replacement keys, run a shell
command, or absorb the input.

Architectural sibling of
[stroke](https://github.com/akira-toriyama/stroke): Swift 6,
macOS 13+, three-layer hexagonal split. Difference from stroke is
the trigger: chord is *discrete events* (one key-down / button-down
fires immediately), stroke is *gesture sequences*.

Implementation: chord uses **CGEventTap** rather than the older
Carbon `RegisterEventHotKey` API. That's what makes F21–F24 (no
Carbon virtual keycodes exist for those), mouse buttons, and
scroll-wheel events all bindable at the OS level. The cost is a
one-time Accessibility grant.

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (XCTest); fails on CLT
.build/debug/chord --help    # smoke test
.build/debug/chord --validate
```

Same XCTest constraint as stroke / facet — CommandLineTools alone
can't run tests; let CI cover them. `swift build` is the bar
locally.

`@main enum ChordApp` lives in
[Sources/ChordApp/Main.swift](Sources/ChordApp/Main.swift) (NOT
top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once test coverage of the CLI
lands. **Don't reintroduce a `main.swift` file** — same trap as
stroke / facet / ws-tabs.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `ChordCore` is pure logic (no
  AppKit / no CGEvent / no AX). `ChordAdapterMacOS` wraps the OS
  (CGEventTap, AX permission prompt, NSWorkspace frontmost
  tracking, CGEvent post) and is the *only* place those types
  appear. `ChordAdapterTest` is the synthetic counterpart for
  end-to-end matcher tests. Crossing layers always means there's a
  missing protocol.
- **`EventSource` is the seam**:
  [Sources/ChordCore/EventSource.swift](Sources/ChordCore/EventSource.swift)
  declares the protocol; the Controller only ever sees
  `EventSource`. Real vs synthetic is picked at app startup.
  Adding a new event-input strategy means a new `EventSource`
  conformer in an Adapter module — never a `#if` in Core.
- **EventSource is callback-based, NOT AsyncStream**. CGEventTap's
  callback fires on the tap's run loop and *must* return
  synchronously with the consume / pass decision. AsyncStream is
  the wrong shape for that path — by the time the consumer pulled
  an event, the OS would have already delivered it elsewhere.
  Don't "modernise" this seam.

### The consume / pass spine — DO NOT regress this

Every binding's reason to exist is that it *swallows* the original
event. Everything below depends on this contract:

- The decision is made **inside the tap callback**, synchronously,
  on the tap's run loop thread. The handler closure
  [Controller.handle(_:)](Sources/ChordApp/Controller.swift) is
  called inline from there.
- `ActionDispatcher.postKeys` posts synthetic events via
  `.cghidEventTap`, which means our own tap sees them on the way
  back in. To avoid an infinite loop the dispatcher tags every
  synthetic event with `EventTap.syntheticUserData` in
  `.eventSourceUserData`; the callback short-circuits these before
  they re-enter the matcher.
  ([Sources/ChordAdapterMacOS/EventTap.swift](Sources/ChordAdapterMacOS/EventTap.swift),
  [Sources/ChordAdapterMacOS/ActionDispatcher.swift](Sources/ChordAdapterMacOS/ActionDispatcher.swift))
- **`Matcher` is a value type** in
  [Sources/ChordCore/Matcher.swift](Sources/ChordCore/Matcher.swift).
  Don't bury mutable state in it — the tap-thread handler reads
  `Self.sharedMatcher` (a `nonisolated(unsafe)` slot guarded by
  `matcherLock`) and the main-actor Controller writes via
  `publishMatcher()`. The lock window is tiny on both sides; do
  NOT replace it with a queue or actor — the tap thread cannot
  await.
- **First-match wins**. Bindings are evaluated in `config.toml`
  document order. The matcher is intentionally not "best-match" —
  the user already ordered them.

### `chord --list` and the chord.bindings.v1 schema

- **JSON output is the contract**, plain-text output is just for
  humans. The schema lives at
  [docs/schema/chord.bindings.v1.json](docs/schema/chord.bindings.v1.json)
  and is the authority — any wire-format change must update both
  [Sources/ChordCore/Schema.swift](Sources/ChordCore/Schema.swift)
  AND the schema file in the same commit, OR the consumer-facing
  contract drifts silently.
- **Consumer pinning guidance**: external repos integrating this
  schema should pin to a **tagged URL** (`…/v0.3.1/…`), not
  `…/main/…` — `main` moves under their feet, a tag does not.
  Stronger still: vendor the file into the consumer repo
  (`docs/external/chord.bindings.v1.json`). Mirror this advice in
  the schema's `description` field too (single source of truth
  for future consumers reading the schema cold).
- **Renaming any `ConfigWarning.Kind` raw value or any enum
  value in the schema (trigger.kind, action.kind, dropped.kind,
  side_requirement, modifier_token) is a v2 bump**. Adding new
  values to those enums is forward-compatible if existing
  consumers treat unknown values gracefully — schema docs say so;
  honour it.
- **stdout vs stderr separation is strict**: `--list --json` puts
  JSON on stdout, every warning / log line on stderr.
  `chord --list --json | jq …` must never break because chord
  printed a warning to the same stream.
- **`modifier_sides` is per-logical-modifier, not flat**. Reason:
  capsule-corp Q1-2 — keeps consumer code clean (checking "ctrl
  is held" is one field lookup, not an OR over `ctrl|lctrl|rctrl`).
  Don't flatten.
- **`apps: null` vs `apps: []` is meaningful**. `null` = user did
  not write `apps` (matches every app). `[]` is reserved / future.
  Today the parser folds `["*"]` to `null`.
- **`dropped[]` is populated regardless of `--include-dropped`**;
  the flag only controls text rendering. Machine consumers always
  see drops.
- **`chord --validate --json` reuses the same Document** and adds
  an optional `validation` block (`ok` / `strict` /
  `parsed_counts` / `dropped_count` / `warning_count` /
  `undefined_aliases`). `--list --json` does NOT include this
  block — the field is documented as optional in the schema, so
  both emitters produce valid v1 documents. The `ok` flag already
  accounts for `--strict`, so a consumer just branches on
  `validation.ok` instead of re-computing from counts. Exit code
  matches `validation.ok` (0 vs 1).
- **Stable sort**: JSONEncoder uses `.sortedKeys`, so the output
  diff-friendly. Don't switch to insertion order.

### Aliases (the `[aliases]` table)

- **Flat name → command lookup**. The TOML table accepts only
  `string` values; anything else is dropped with a warning.
- **Applies to `action-shell` only**. `action-keys` is parsed
  through `InputParser` and treats `@name` as an unknown token
  (drops the binding via the existing parse-error path) — by
  design, capsule-corp confirmed `action-keys` reuse is not a
  needed case.
- **Single-token `@name` only**. `@name arg` syntax is reserved
  for a future expansion; in v1 a value containing whitespace
  after `@name` falls through as a literal command (so the user
  who really meant to pass an argument doesn't get a silent
  malfunction). Document this clearly in any user-facing changes.
- **Undefined `@name` drops the binding with a warning** in the
  exact format capsule-corp asked for:
  ```
  warning: binding 'NAME' (config.toml:LINE) references undefined alias '@xyz'; binding dropped
  ```
  The `(config.toml:LINE)` suffix comes from the synthetic
  `__line__` value the TOML parser injects into each `[[X]]` row
  via `appendArrayOfTablesRow(_:path:lineNo:)`. Treat
  `TOML.lineKey` as reserved — users naming a real TOML key
  `__line__` would shadow the metadata (acceptable trade; the
  alternative is changing the parser's return type).
- The Controller startup / reload log line surfaces alias counts
  and `undefined-aliases=N` alongside the bindings / fallbacks /
  dropped totals — so a single `tail -f /tmp/chord.log` shows the
  full state of the config without re-running `--validate`.

### Fallbacks (the `[[fallbacks]]` section)

- **Two-stage matching**: `Matcher.find` first walks `[[bindings]]`
  document-order first-match-wins, then on a miss walks
  `[[fallbacks]]` the same way. Stage 2 only fires when stage 1
  produces nothing.
- **`*` wildcard primary key is legal only in `[[fallbacks]]`**.
  The parser (`InputParser.parse(_:allowWildcard:)`) refuses `*`
  in regular `[[bindings]]` rows, so a single binding can never
  accidentally swallow every key. `Config.parse` flips the flag
  per-section.
- **`.anyKey` matches keyboard events only** — mouse and scroll
  events never satisfy a wildcard. Mouse fallbacks were
  considered for v1 and explicitly deferred (capsule-corp's
  v1 use case is keyboard-only).
- **Use case**: "play a sound when ULTRA_LL fires on an
  undefined key" — capsule-corp's effect-feedback that was
  previously hand-enumerated as 4 modsets × ~30 keys against an
  upstream daemon's hard-error dedup; one `[[fallbacks]]` row
  per modset now suffices.

### Configuration

- **`config.toml` at the repo root is the source-of-truth
  template**. Users `curl` it into `~/.config/chord/config.toml`
  (see [README.md](README.md) Configuration section).
  **The app only reads it** — never writes, never auto-generates
  an example, never persists runtime overrides. Same policy as
  stroke / facet: the file is the only thing the user has to look
  at to know what chord will do.
- **There is no settings GUI** — by design. Don't propose adding
  NSPanel-based preferences. Every option lives in one TOML file.
- **Per-binding failures are non-fatal**. A binding whose `input`
  fails to parse, or whose `action-*` is malformed, is **dropped
  with a warning** rather than rejecting the whole config. A typo
  can never silence a working binding elsewhere in the file.
  `chord --validate` is the explicit verification path (exit 2 if
  anything dropped).

### TOML parser

- **`TOML.parse` is hand-rolled** in
  [Sources/ChordCore/TOML.swift](Sources/ChordCore/TOML.swift) —
  ported from stroke's `parseTOMLSubset`. Inline tables (`{a=1,
  b=2}`) are **not** supported and `[[bindings]]` rows use the
  dotted-key style (`action-shell` / `action-keys` / `action-noop`)
  instead. Don't add an inline-table parser without a real need;
  the dotted-key form keeps the parser inside its budget.

### Modifiers (the L/R question)

- **`Modifiers` is a UInt16 OptionSet with two layers**: the
  any-side bits (`.cmd` / `.opt` / `.ctrl` / `.shift` / `.fn`)
  match either physical side; the side-specific bits (`.lcmd` /
  `.rcmd` / `.lopt` / `.ropt` / `.lctrl` / `.rctrl` / `.lshift` /
  `.rshift`) require the explicit side.
- **Events carry ONLY side-specific bits**, never the any-side
  ones — that's the contract `EventTap.readModifiers` upholds by
  reading the device-dependent NX_DEVICE\* bits out of the
  CGEventFlags raw value (`0x00000008` for lcmd, etc., per
  `IOKit/hidsystem/IOLLEvent.h`). When the OS sets only the
  abstract mask (rare; some software keyboards), the adapter
  picks left as the default so any-side bindings still fire
  without spuriously matching strict-left bindings.
- **Matching is predicate-based** (`Modifiers.matches(event:)`),
  NOT `==`. Per category:
  - both `.lX` and `.rX` on the binding → both sides held
  - only `.lX` → L held, R absent
  - only `.rX` → R held, L absent
  - only `.X` (any) → at least one side held
  - neither → both must be absent

  Tests pin the contract in
  [Tests/ChordCoreTests/MatcherTests.swift](Tests/ChordCoreTests/MatcherTests.swift)
  — especially `testUltraLLPattern`, which encodes the ZMK
  ULTRA_LL parity the capsule-corp migration is built on.
- **When posting synthetic keys**, the dispatcher sets the
  abstract mask (`.maskCommand` etc.) AND the device-dependent
  bit only when the binding requested a specific side. A plain
  `action-keys = "cmd - c"` posts with the device-dependent bits
  clear so receiving apps see "either-side cmd" — the way the
  user wrote.

### Keycodes (the F13–F24 question)

- F1–F20 use Apple's documented `kVK_F1…kVK_F20` constants.
- F21–F24 have **no** kVK constants — Apple has never assigned
  them. The values in
  [Sources/ChordCore/KeyCodes.swift](Sources/ChordCore/KeyCodes.swift)
  are the unassigned slots that Karabiner-Elements / firmware
  remappers conventionally emit for HID usages 0x70–0x73, which is
  the de-facto convention macOS keyboards use today (ZSA
  Moonlander, custom QMK builds, etc.).
- A keyboard that physically lacks F21–F24 won't reach those
  bindings — that's correct, not a bug. The escape hatch is the
  `keycode-NN` form (raw `CGKeyCode`), so any vendor-specific
  media key still binds.

### Logging

- **`Log` lives in `ChordCore`** so both the Adapter and App
  modules can call it without crossing layer rules. Two
  functions: `Log.line` (always on) and `Log.debug` (gated by
  `debugMode`, set from `chord --debug` at startup).
- **Both write to `/tmp/chord.log`**; `--debug` also mirrors to
  stderr so foreground users see events live.
- **Use `Log.debug` liberally** in EventTap / dispatch hot paths.
  It costs one bool check when disabled. Skip per-mouseMoved
  logging if such a tap ever gets added — that fires too often
  even with the gate.

### Debugging — how Claude Code observes a running daemon

chord is **headless** (`LSUIElement`, no Dock icon, no window).
The agent cannot "look at the screen" to see what it's doing — so
the daemon is built to be debuggable entirely from the terminal.

1. **Run in the foreground with `--debug`** so events stream live:
   `.build/debug/chord --debug`. This sets `debugMode = true` and
   mirrors every log line to stderr in addition to `/tmp/chord.log`.
2. **Tail the log** from a second shell: `tail -f /tmp/chord.log`.
   This is the single source of observability — there is nothing
   else to inspect.
3. **Interpret the trace.** A successful binding logs, in order:
   ```
   event-tap: installed (mask=0x…)
   config startup: N bindings loaded, 0 dropped
   dispatch.keys: "screenshot" → mods=12 code=21
   ```
   The `dispatch.*` line missing means the matcher found nothing
   — re-check the `input` field's modifier mask vs. what the OS
   sees (use `--debug` and trigger the chord).
4. **Check config** with `chord --validate` (exit 0 + binding
   count, or exit 2). The `chord --doctor` form additionally
   reports Accessibility status and whether the daemon is
   currently running.

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`event-tap: tapCreate failed` in the log and no bindings fire.
Re-grant in System Settings, or use the persistent cert
(`setup-signing-cert.sh`) so the grant survives. Use
`pgrep -lf chord` to see what's running and `./stop.sh` to clear
stray instances before relaunching.

### Bundle / signing

- **Bundle id is `com.chord.chord`** (set in
  [Info.plist](Info.plist)). TCC keys the Accessibility grant to
  the code-signing identity, so ad-hoc signing loses the grant on
  every rebuild. [setup-signing-cert.sh](setup-signing-cert.sh)
  creates a persistent self-signed cert so the grant survives
  rebuilds; [package.sh](package.sh) assembles `Chord.app` and
  signs it with that identity (`--dev` →
  `Chord-dev.app` / `com.chord.chord.dev` to co-exist with a
  Homebrew install without TCC collision). Same pattern as stroke
  / facet.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible.

### CLI surface

- **Flags**: `--debug` (server, verbose), `--validate` /
  `--doctor` / `--help` / `--version` (standalone),
  `--reload` / `--quit` / `--pause` / `--resume` / `--status`
  (client). Any unrecognised flag exits `2` with a stderr message
  (no silent fallback — *Rule of Repair*).
- **`--pause` / `--resume`** flip a single `pausedFlag` guarded by
  `pauseLock`, read from the tap callback's hot path before the
  matcher snapshot is even consulted. `--pause` returns
  `.passthrough` for every event without touching the matcher, so
  the daemon stays AX-granted and the keystroke cost is one bool
  check + one mutex acquire. Intended for screencasts / games /
  Zoom screen-sharing where chord shouldn't be eating input.
- **`--toggle`** is sugar: reads the daemon's status file, looks
  for "paused" / "resumed", and posts the opposite DNC
  notification. Implemented entirely on the client side — no new
  IPC channel. The status file is updated by the server on every
  transition, so a fast `chord --toggle` ↔ `chord --toggle`
  loop stays consistent.
- **`--validate` is lenient by default; `--strict` is for CI**.
  Without `--strict`, drops are non-fatal (a typo in one binding
  doesn't fail the pipeline). With `--strict`, any warning or
  drop exits `1`. The summary line always prints
  `parsed: N bindings, M fallbacks; dropped: K, warnings: W` —
  machine-readable enough for awk / grep until `--list --json`
  lands.
- **`--doctor`** reports Accessibility
  (`Permissions.isAccessibilityTrusted()`), config, daemon
  liveness. Exit 1 if any check fails.
- **`--reload` / `--quit` talk to the running daemon over
  Distributed Notification Center** (`com.chord.app.control`, see
  [Sources/ChordApp/Control.swift](Sources/ChordApp/Control.swift))
  — same pattern as facet / stroke. Don't invent a different IPC.
  They exit `3` if no daemon is running.
- **`--status` is one-way the other direction**: DNC can't reply,
  so the daemon rewrites a small status file
  (`/tmp/chord.status`) on start / reload / each fired binding,
  and `--status` just reads it. Don't reach for a request/response
  IPC — the file is enough.
- **Config auto-reload**: a `DispatchSource` vnode source on
  [ChordConfig.path](Sources/ChordCore/Models.swift) re-arms on
  the atomic-save rename / delete and calls `controller.reload()`
  on edit. `--reload` is now just the manual trigger for the same
  path.

## Conventions

- **Commit messages**: gitmoji + Conventional Commits (matches
  stroke / facet). `<:gitmoji:> <type>(<scope>)<!>: <subject>`.
  Enable the local hook when one is added: `git config
  core.hooksPath scripts/hooks`.
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync when
  user-visible behavior changes — same rule as stroke / facet.
- After source edits, **`swift build` must pass** before finishing
  a turn.
- **Don't push without explicit OK**. Quality-first phased
  workflow inherited from facet / stroke. Commit locally freely;
  pushing / merging waits for the maintainer's go.

## References

External material that informed chord's API / architecture
decisions. Subsections ordered **broad → narrow / language-neutral
→ language-specific**, matching facet's
*external-reference-selection* convention. Each entry carries
`(reviewed YYYY-MM-DD)` so the freshness lifecycle is visible at a
glance; re-check on any 6+ month gap, refresh the date on
re-confirmation.

### Architecture

- See [facet's CLAUDE.md → References → Architecture](https://github.com/akira-toriyama/facet/blob/main/CLAUDE.md)
  *(reviewed 2026-05-24)* — same hexagonal / Clean Architecture /
  DDD literature applies here. Don't re-list it.
- See [stroke's CLAUDE.md → References → Architecture](https://github.com/akira-toriyama/stroke/blob/main/CLAUDE.md)
  *(reviewed 2026-05-24)* — chord borrows stroke's 3-layer
  Core/AdapterMacOS/AdapterTest split verbatim. The deltas are
  documented here, not there.

### macOS / Apple

- [Quartz Event Services (CGEventTap)](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
  *(reviewed 2026-05-24)* — the API every binding flows through.
  `.cgSessionEventTap` location + `.defaultTap` option +
  `eventMask` of `keyDown | flagsChanged | leftMouseDown |
  rightMouseDown | otherMouseDown | scrollWheel`. Reach here when
  changing the mask, the tap location, or the user-data sentinel
  scheme.
- [Carbon Events.h — Virtual Keycodes](https://developer.apple.com/documentation/coreservices/carbon_core/1564550-virtual_keycodes)
  *(reviewed 2026-05-24)* — the authoritative source for
  `kVK_F1…kVK_F20`. Apple does NOT define `kVK_F21…kVK_F24`; chord
  uses the conventional Karabiner-emitted slots for those (see
  [KeyCodes.swift](Sources/ChordCore/KeyCodes.swift)). Don't
  "correct" those numbers without testing on a keyboard that
  actually sends F21–F24.
- [HID Usage Tables 1.4 — Keyboard page](https://usb.org/sites/default/files/hut1_4.pdf)
  *(reviewed 2026-05-24)* — the upstream definition of HID usages
  0x70–0x73 (F21–F24). What firmware-level remappers (QMK / VIA /
  Karabiner) send when emitting these keys; chord's keycode
  mapping is the macOS-side translation.
- [Hardened Runtime / Code Signing](https://developer.apple.com/documentation/security/hardened_runtime)
  *(reviewed 2026-05-24)* — same TCC-Accessibility grant concern
  stroke / facet documents. Self-signed persistent identity keeps
  the grant stable across rebuilds.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
  *(reviewed 2026-05-24)* — the permission check + prompt
  Permissions.swift wraps. `kAXTrustedCheckOptionPrompt` is
  exposed as a Swift `var` (so Swift 6 strict concurrency rejects
  capturing it); chord uses the literal `"AXTrustedCheckOptionPrompt"`
  string — same workaround facet uses.
- [Distributed Notification Center](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
  *(reviewed 2026-05-24)* — the IPC chord uses for
  `--reload` / `--quit`. Fire-and-forget; the status file at
  `/tmp/chord.status` is the reverse channel. Same pattern as
  facet / stroke; don't invent a separate request/response IPC.

### Prior art

- [Hammerspoon](https://www.hammerspoon.org/)
  *(reviewed 2026-05-24)* — the Lua-scripted CGEventTap workhorse
  on macOS. chord's `.cghidEventTap` post + sentinel-tagging via
  `.eventSourceUserData` mirrors `hs.eventtap` (the
  prior-art-with-real-mileage on the synthetic-event re-entrancy
  problem). Reach here when a hot-path event ordering question
  comes up that the Apple docs don't answer.
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
  *(reviewed 2026-05-24)* — the de-facto HID remapper on macOS.
  chord's F21–F24 keycode numbers are the slots Karabiner emits
  for HID usages 0x70–0x73; the `hyper` modifier sugar is named
  after Karabiner's popular `Hyper` rule. Don't try to ship
  HID-level remapping inside chord — that's Karabiner's job.

### Formats / conventions

- [TOML 1.0.0 spec](https://toml.io/en/v1.0.0)
  *(reviewed 2026-05-24)* — what the hand-rolled `TOML.parse`
  approximates. chord intentionally supports a strict subset (no
  inline tables, no nested arrays-of-arrays, dotted-key style for
  `[[bindings]]` rows). New `.toml` features must justify the
  added parser surface.
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
  *(reviewed 2026-05-24)* — type / scope grammar
  `<type>(<scope>)<!>: <subject>`. `docs/commit-convention.md` is
  the project-local rules; CI enforces this via `commit-lint.yml`.
- [Gitmoji](https://gitmoji.dev/)
  *(reviewed 2026-05-24)* — the leading emoji on each commit
  (`:sparkles:` feat, `:bug:` fix, `:lock:` security, `:memo:`
  docs, `:test_tube:` test, …). Same convention as stroke /
  facet — mirror that list when in doubt.

### CLI design

- [Command Line Interface Guidelines (clig.dev)](https://clig.dev/)
  *(reviewed 2026-05-24)* — modern restatement of the Unix
  philosophy plus current conventions. chord's exit-code split
  (0 / 1 / 2 / 3), stderr-on-failure / stdout-on-data, and the
  "unknown flag is loud, never silent fallback" stance trace
  directly here.
- [POSIX Utility Conventions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html)
  *(reviewed 2026-05-24)* — source-of-truth specification for
  `--long-option=VALUE` syntax and the exit-status semantics chord
  inherits.

### GitHub

- [GitHub Docs (日本語)](https://docs.github.com/ja)
  *(reviewed 2026-05-24)* — primary reference for the bits this
  repo actually touches: `gh` CLI, Actions workflow syntax,
  release drafts, branch protection, fine-grained PAT scoping (the
  recurring foot-gun behind `HOMEBREW_TAP_TOKEN`).

### Development environment (Claude Code)

- [Claude Code docs (ja)](https://code.claude.com/docs/ja/overview)
  *(reviewed 2026-05-24)* — entry point for the agent / toolchain
  chord is being built with. Sub-pages of immediate interest:
  `/docs/ja/memory` (CLAUDE.md + auto-memory semantics, governs
  how rules in this file are loaded),
  `/docs/ja/skills` (custom skills like `grill-me`, installed
  under `~/.claude/skills/`),
  `/docs/ja/settings` (per-project / per-user `settings.json`),
  `/docs/ja/hooks` (workflow automation triggers — chord's
  `scripts/hooks/commit-msg` is the local-git form, not the
  Claude Code form).

### Packaging / Release

- [Homebrew](https://brew.sh/ja/)
  *(reviewed 2026-05-24)* — chord's intended distribution channel
  once a stable release lands. The pattern mirrors stroke / facet:
  `brew install akira-toriyama/tap/chord`, with
  `.github/workflows/update-tap.yml` automating the formula bump
  on every published release.
