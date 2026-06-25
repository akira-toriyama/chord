# CLAUDE.md

Guidance for working in this repository.

## What this is

`chord` — global keyboard + mouse hotkey daemon for macOS. Built
around one idea: **every binding is a chord of inputs**, where the
"notes" can be modifier keys, ordinary keys (incl. F13–F24), mouse
buttons (incl. side1/side2), or scroll-wheel deltas. Each chord
maps to one of four actions: post replacement keys, run a shell
command, absorb the input, or mutate a named state variable
(v2 — enables Karabiner-style leader-key modes).

Architectural sibling of
[stroke](https://github.com/akira-toriyama/stroke): Swift 6,
macOS 13+, three-layer hexagonal split. Difference from stroke is
the trigger: chord is **discrete events + 1-tier state** — one
key-down / button-down fires immediately, but a binding may
optionally gate on a single named variable and another binding may
have set that variable on an earlier discrete event. stroke is
*gesture sequences*. The state surface is intentionally narrow:
flat `[String: Int]` store, single-variable equality predicates,
no nested modes. Anything that needs a real state machine belongs
in stroke (or Karabiner-Elements at the HID layer).

Implementation: chord uses **CGEventTap** rather than the older
Carbon `RegisterEventHotKey` API. That's what makes F21–F24 (no
Carbon virtual keycodes exist for those), mouse buttons, and
scroll-wheel events all bindable at the OS level. The cost is a
one-time Accessibility grant (plus a conditional Input Monitoring
grant for the opt-in v-key vendor-HID path — requested only when a
v-key binding is configured; see `VKeyHIDSource` /
`Controller.configDeclaresVKeys`).

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (Swift Testing); fails on CLT
.build/debug/chord --help    # smoke test
.build/debug/chord config --validate
```

Same test-toolchain constraint as stroke / facet — CommandLineTools
alone can't run tests (it ships neither XCTest nor Swift Testing);
full Xcode or CI covers them. `swift build` is the bar locally.

`@main enum ChordApp` lives in
[Sources/ChordApp/Main.swift](Sources/ChordApp/Main.swift) (NOT
top-level code in a `main.swift`) so the test target's
`@testable import` keeps working — it backs CLIDispatchTests' Swift
Testing coverage of the CLI. **Don't reintroduce a `main.swift` file** — same trap as
stroke / facet / ws-tabs.

## Source-of-truth references

Two cross-cutting docs to consult before the layer-specific rules below:

- **[docs/glossary.md](docs/glossary.md)** — chord の正規 (canonical)
  用語表。同じ概念に複数の名前を当てない (= "alias" だけで input/action を
  曖昧化しない、"state-store" と "variables" が混在しない、等) ための辞書。
  各 entry に `Don't call it:` 欄があり、PR レビューでの即時 NG ワードの根拠
  に使える。**コード変更で用語を新設 / rename した場合は同 PR で更新**
  (PR template の glossary checkbox 参照)。
- **[docs/non-goals.md](docs/non-goals.md)** — chord が **意図的に持たない
  機能** と「再検討する条件」。隣接プロジェクト
  (skhd / skhd.zig / Karabiner / ZMK) の機能を chord に取り込むべきか毎回
  議論が再燃するのを防ぐ。

実装タスク / ロードマップは furrow tracker
([`akira-toriyama/projects`](https://github.com/akira-toriyama/projects)・label
`chord`) が正本 → §Roadmap board / task tracker。

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
- v2 extended the contract to **paired down/up consume**: when a
  down is swallowed, the corresponding up is too (tracked via the
  Controller's `pendingUps` table). The OS sees neither half.
  Without this pair, the OS would receive a "phantom" key-up for
  a key it never saw go down. See the "Key-up / paired consume"
  section below for the details.
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

### `chord config --show` and the chord.bindings.v3 schema

- **JSON output is the contract**, plain-text output is just for
  humans. The schema lives at
  [docs/schema/chord.bindings.v3.json](docs/schema/chord.bindings.v3.json)
  and is the authority — any wire-format change must update both
  [Sources/ChordCore/Schema.swift](Sources/ChordCore/Schema.swift)
  AND the schema file in the same commit, OR the consumer-facing
  contract drifts silently. The v1 JSON file
  (`chord.bindings.v1.json`) is kept under `docs/schema/` for
  history; do not edit it. (No separate v2 file was ever
  published — the v1→v3 jump happened within the live schema; v3
  is current.)
- **Consumer pinning guidance**: external repos integrating this
  schema should pin to a **tagged URL** (`…/v0.8.0/…`), not
  `…/main/…` — `main` moves under their feet, a tag does not.
  Stronger still: vendor the file into the consumer repo
  (`docs/external/chord.bindings.v3.json`). Mirror this advice in
  the schema's `description` field too (single source of truth
  for future consumers reading the schema cold).
- **Renaming any `ConfigWarning.Kind` raw value or any enum
  value in the schema (trigger.kind, action.kind, dropped.kind,
  side_requirement, modifier_token) is a schema major bump**
  (e.g. v3 → v4). Adding new values to those enums is forward-
  compatible if existing consumers treat unknown values gracefully
  — schema docs say so; honour it.
- **stdout vs stderr separation is strict**: `config --show --json` puts
  JSON on stdout, every warning / log line on stderr.
  `chord config --show --json | jq …` must never break because chord
  printed a warning to the same stream.
- **`modifier_sides` is per-logical-modifier, not flat**. Reason:
  canon Q1-2 — keeps consumer code clean (checking "ctrl
  is held" is one field lookup, not an OR over `ctrl|lctrl|rctrl`).
  Don't flatten.
- **`apps: null` vs `apps: []` semantics**. `null` = user did not
  write `apps` (matches every app). `["*"]` is folded to `null` by
  the loader. `apps: []` (empty array) falls through to
  `Matcher.appsAllow`, which with no allowlist and no exclusion
  returns `false` — i.e. the binding never fires for any app. This
  is almost certainly a user mistake, not a useful zero-binding
  shape; flag it (TODO: warning kind) rather than treating it as
  configuration.
- **`dropped[]` is populated regardless of `--include-dropped`**;
  the flag only controls text rendering. Machine consumers always
  see drops.
- **`chord daemon --reload --dry-run` is a pure parser + differ** — it
  does NOT post the DNC notification, never touches the daemon's
  state. The diff is computed against the snapshot the running
  daemon writes to `/tmp/chord-loaded.json` on every
  `loadConfig`; if no snapshot exists (daemon never ran on this
  boot), every binding shows as "added" with a `note:` line
  explaining the situation. Bindings are matched by `name`, so
  re-numbering (line shifts from inserts above) never surfaces
  as a change — only semantic field deltas
  (`BindingsSchema.semanticallyEqual` ignores `index` /
  `source_line`).
- **`chord config --validate --json` reuses the same Document** and adds
  an optional `validation` block (`ok` / `strict` /
  `parsed_counts` / `dropped_count` / `warning_count` /
  `undefined_aliases`). `config --show --json` does NOT include this
  block — the field is documented as optional in the schema, so
  both emitters produce valid v3 documents. The `ok` flag already
  accounts for `--strict`, so a consumer just branches on
  `validation.ok` instead of re-computing from counts. Exit code
  matches `validation.ok` (0 vs 1).
- **Stable sort**: JSONEncoder uses `.sortedKeys`, so the output
  diff-friendly. Don't switch to insertion order.

### Aliases (the `[action-aliases]` and `[input-aliases]` tables)

The original v0.5 single `[aliases]` table was split in v0.6 into
**two tables with different semantics**:

- `[action-aliases]` → `@name` references in `action-shell` (was
  the original `[aliases]`)
- `[input-aliases]` → `$name` references in `input = "..."`
  (modifier-set naming, new in v0.6)

`[aliases]` is dead — do not reintroduce it; the v3 schema's
`ConfigWarning.Kind` values carry the new names
(`action-alias-non-string`, `input-alias-non-string`, etc.).
Rules:

- **Flat name → string lookup, per table**. Both accept only
  `string` values; anything else is dropped with a warning
  (`action-alias-non-string` / `input-alias-non-string`).
- **`[action-aliases]` applies to `action-shell` only**.
  `action-keys` is parsed through `InputParser` and treats `@name`
  as an unknown token (drops the binding via the existing
  parse-error path) — canon confirmed `action-keys` reuse is not
  needed.
- **`@name(args)` is supported since chord 0.9.0** — the alias
  body uses `{{1}}` / `{{2}}` placeholders, the call site supplies
  positional args. Malformed calls (missing args, unbalanced
  parens) surface as `action-alias-call-error`. The pre-0.9.0
  "single-token `@name` only" rule still applies when the body
  has no placeholders.
- **`[input-aliases]` rules**: names must NOT shadow built-in
  modifier tokens (`cmd`, `ctrl`, `shift`, `opt`, `fn`, plus
  L/R-prefixed variants) — collision yields
  `input-alias-shadows-modifier`. Bodies must be made of built-in
  tokens only — no nested alias references (= cycle-free by
  construction).
- **Undefined `@name` drops the binding with a warning** in the
  exact format canon asked for:
  ```
  warning: binding 'NAME' (config.toml:LINE) references undefined alias '@xyz'; binding dropped
  ```
  The `(config.toml:LINE)` suffix comes from `Toml.Row.span` — each
  `[[X]]` row `Toml.parse` returns is a `Toml.Row` carrying the
  `SourceSpan` of its header (swift-toml-edit 2.0.0). The line is
  resolved at parse time (`row.span?.line`) and threaded into the
  binding / warning as an explicit value; synthesized desugar rows
  inherit the originating row's line the same way. This replaced the
  old synthetic `__line__` dict key (`TOML.lineKey`), which every
  consumer had to skip and a user key could shadow — a typed `Row`
  field can't collide and rides on value-copy when a row is cloned.
  (#148 / #138-E.)
- The Controller startup / reload log line surfaces alias counts
  and `undefined-aliases=N` alongside the bindings / fallbacks /
  dropped totals — so a single `tail -f /tmp/chord.log` shows the
  full state of the config without re-running `config --validate`.

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
  considered for v1 and explicitly deferred (canon's
  v1 use case is keyboard-only).
- **Use case**: "play a sound when ULTRA_LL fires on an
  undefined key" — canon's effect-feedback that was
  previously hand-enumerated as 4 modsets × ~30 keys against an
  upstream daemon's hard-error dedup; one `[[fallbacks]]` row
  per modset now suffices.

### State machine (v2 — Karabiner-style leader keys)

- **The store is `ChordCore`'s `VariableStore`**
  ([Sources/ChordCore/VariableStore.swift](Sources/ChordCore/VariableStore.swift)),
  a `final class` wrapping a flat `[String: Entry]` behind its own
  `NSLock` (`@unchecked Sendable`). It is **owned by ChordCore but
  driven by the Controller** — a module-global
  `let variableStore = VariableStore(scheduler: DispatchStateScheduler())`
  in Controller.swift. (Extracted from the Controller's old
  file-private globals so the concurrency-sensitive logic is
  directly unit-testable.) Reads on the tap thread go through
  `variableStore.snapshot() -> StateSnapshot` (a value-typed copy
  of the dict taken under the lock); the Matcher consumes it via
  `Matcher.Event.state`. Writes go through
  `variableStore.set(name:value:holdWhile:timeoutMs:)`,
  `toggle(name:)` (atomic 0↔1 flip in a single lock window), and
  `extendTimer(name:)` (B-α reset-on-use). Every public method takes
  the lock for its whole body; the lock window never wraps a
  callback. **Don't replace it with an actor** — the tap thread
  cannot `await`.
- **Action.setVariable / Action.toggleVariable are intercepted by
  the Controller**, not the ActionDispatcher. State ownership
  belongs to the App layer (it drives the store); the Adapter has
  no legitimate reason to know about the variable store. The
  dispatcher's `case .setVariable` path is a debug-log no-op safety
  net for tests that exercise it directly.
- **An unset variable reads as 0**. `Condition.variable(_, equals: 0)`
  is the idiomatic "mode cleared" check. Writing 0 via
  `variableStore.set(...)` removes the entry — the dict doesn't
  accumulate zeroed keys.
- **`hold-while` is the lifecycle**. A binding's `action-set-var`
  with `hold-while = "cmd + opt"` ties the variable to that
  modifier mask: when the OS-side modifier state no longer
  satisfies the mask (via `Modifiers.isStillHeld(in:)`), the
  Controller forwards the flagsChanged event to
  `variableStore.clearStale(currentMods:)`, which clears the entry.
  Without `hold-while`, the variable persists until an explicit
  `action-set-value = 0` write.
- **`isStillHeld(in:)` is permissive of extras**. Distinct from
  `matches(event:)`: adding shift on top of held cmd+opt must NOT
  clear a `hold-while = "cmd + opt"` variable, because the user
  hasn't done anything to indicate "leave the mode". Strict-side
  bits (`.lcmd`, `.rshift`, …) require the exact side; any-side
  bits (`.cmd`) accept either.
- **Reload wipes everything** — `variableStore.reset()` (the state
  dict and its timers) plus the pending-up table. A reload may have
  dropped the binding that owned a variable, leaving an entry no one
  can clear (silent leak). Same policy as the config loader: reload
  = clean slate.
- **State is intentionally narrow**: single-variable equality
  (`Condition.variable`) OR an AND conjunction of equalities
  (`Condition.conjunction`, built from `when-vars = { a = 1, b = 2 }`,
  chord 0.9.0+) — still **no OR, no NOT, no nested modes**, and no
  state-emitting conditions (a binding can `set-variable` /
  `toggle-variable` OR gate on `when-var` / `when-vars`, but the
  gate predicate cannot itself mutate state). This matches the
  canon migration's actual leader-key use cases and keeps the
  parser surface bounded. Anything richer belongs in stroke or in
  Karabiner.
- **`action-toggle-var` (`Action.toggleVariable`)** flips a variable
  between 0 and 1 on each press (any non-zero collapses to 0). Like
  `setVariable` it is intercepted by the Controller, not the
  dispatcher; it goes through `variableStore.toggle(name:)` so the
  read and write stay in one lock window. No hold-while / timeout
  applies — the lifecycle is "until the next toggle".

### Variable lifecycle — `hold-while-timeout` (chord 0.4.0)

- **`hold-while`** ties the variable to a held modifier mask. Only
  useful when the modifiers stay physically held at the OS level
  across keystrokes. Many programmable keyboards (ZMK macros that
  emit atomic strict-side chords; Karabiner complex_modifications)
  drop the modifiers between primary keys — `hold-while` would
  clear the variable before the next primary arrived. Verified by
  observing flagsChanged transitions of 1-2ms duration immediately
  after a `keyDown` on those setups.
- **`hold-while-timeout`** is the inactivity-timer
  lifecycle. `VariableStore` schedules timers through an injected
  `StateScheduler` protocol; the production `DispatchStateScheduler`
  uses a one-shot `DispatchSourceTimer` on a dedicated serial queue
  labelled `"chord.state.timer"` (qos `.userInitiated`). On expiry the
  store's private `timerFired(name:)` takes the lock and removes the
  entry. (This replaced the old `stateTimerQueue` / `sharedTimers` /
  `Controller.timerFired` / `cancelTimerLocked` Controller globals.)
  B-α "reset-on-use": every binding gated on the same variable calls
  `variableStore.extendTimer(name:)` before returning — sustained
  editing sessions don't time out.
- **Mutual exclusion**: a binding writing both `hold-while` and
  `hold-while-timeout` is dropped at parse time. They pick
  different lifecycles for the same variable.
- **Cleanup paths cancel timers**: reload (`VariableStore.reset()`),
  modifier release (`clearStale(currentMods:)`), explicit clear
  (`action-set-value = 0`, i.e. `set(...)` with value 0) all cancel
  the timer (private `cancelTimerLocked`) so a delayed fire doesn't
  mutate stale state.
- **No global default**. Each `action-set-var` binding declares
  its own timeout. Vim's `timeoutlen` global is a known pain
  point — different leaders have different ergonomics
  (window-management snap = fast, editing leader = slow).

### Key-up / paired consume (v2)

- **EventTap.mask now includes `keyUp` and the three `*MouseUp`
  variants** alongside the down events. `flagsChanged` was always
  in the mask; v2 routes it to the state-cleanup path via
  `EventKind.modifiersChanged` rather than dropping it at
  `makeInputEvent`.
- **B1 contract — implicit consume of paired up**: when the
  Controller consumes a down event, it registers the binding in
  the `pendingUps` table keyed by `Trigger` alone. When the up
  arrives, the table entry is taken and consumed (the OS never
  saw the down; sending the up alone would leave it in a
  phantom-key-up state). The binding's `onUpAction` fires at this
  point if present.
- **Keyed by Trigger alone, not (Trigger, Modifiers)**. The user
  may lift modifiers between the down and the up (releases `cmd`
  before releasing `j`); the up event then carries a different
  modifier mask than the down. Matching on trigger alone keeps
  the pair coherent.
- **`onUpAction` is optional**. A binding with only a primary
  action still gets paired-up consume — the up is swallowed even
  without an `action-*-on-up` declaration, again for B1
  coherence.
- **`EventKind.modifiersChanged` never reaches the matcher**.
  The Controller branches on `event.kind` before consulting the
  matcher and routes flagsChanged events directly to
  `variableStore.clearStale(currentMods:)`. The matcher only ever
  sees `.down`. (Up events go through the pending-ups path, never
  the matcher.)

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
  `chord config --validate` is the explicit verification path (exit 2 if
  anything dropped).

### TOML parser

- **TOML parsing is delegated to swift-toml-edit's `Toml` module**
  (Sill-1 — the family's one TOML implementation).
  [Sources/ChordCore/TOML.swift](Sources/ChordCore/TOML.swift) is now a
  thin shim: `@_exported import Toml` + `public typealias TOML = Toml`,
  so existing `TOML.parse` / `TOML.Value` references resolve unchanged.
  The former hand-rolled parser (ported from stroke's `parseTOMLSubset`)
  was retired when chord moved onto swift-toml-edit (sill 0.11.0 era).
- **Inline tables ARE supported** and chord relies on them:
  `when-vars = { a = 1, b = 2 }` (`[when]` conditions — Config+Condition.swift)
  and `[[remap]] map = { … }` (Config+Remap.swift) both decode
  `Toml.Value.table`. New `.toml` surface is bounded by swift-toml-edit's
  full TOML 1.0 support, not a local parser budget.

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
  ULTRA_LL parity the canon migration is built on.
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
  `debugMode`, set from the `CHORD_DEBUG` env var at startup —
  run.sh sets it; brew / raw launch stays quiet).
- **Both write to `/tmp/chord.log`**; `CHORD_DEBUG` also mirrors to
  stderr so foreground users see events live.
- **Use `Log.debug` liberally** in EventTap / dispatch hot paths.
  It costs one bool check when disabled. Skip per-mouseMoved
  logging if such a tap ever gets added — that fires too often
  even with the gate.

### Debugging — how Claude Code observes a running daemon

chord is **headless** (`LSUIElement`, no Dock icon, no window).
The agent cannot "look at the screen" to see what it's doing — so
the daemon is built to be debuggable entirely from the terminal.

1. **Run in the foreground with `CHORD_DEBUG=1`** so events stream live:
   `CHORD_DEBUG=1 .build/debug/chord`. This sets `debugMode = true` and
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
   sees (use `CHORD_DEBUG=1` and trigger the chord).
4. **Check config** with `chord config --validate` (exit 0 + binding
   count, or exit 2). The `chord config --doctor` form additionally
   reports Accessibility status and whether the daemon is
   currently running.

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`event-tap: tapCreate failed` in the log and no bindings fire.
Re-grant in System Settings, or use the persistent cert
(`setup-signing-cert.sh`) so the grant survives. Use
`pgrep -lf chord` to see what's running and `./stop.sh` to clear
stray instances before relaunching.

### `chord daemon --resign` and the brew-sandbox signing trap

- **Homebrew's build sandbox blocks `security` from touching the
  user's login keychain** — confirmed via brew source spelunk
  (`Library/Homebrew/sandbox.rb`) + the v0.3.x install logs (sign-id
  resolved to `-` despite the cert existing in the user's keychain).
  There is **no per-formula sandbox-bypass DSL** (`allow_network_access!`
  is the only escape hatch and it's network-only).
- **Formula installs always ad-hoc-sign.** Don't reintroduce the
  in-formula `setup-signing-cert.sh` invocation pattern — it fell
  back to ad-hoc anyway, just silently and confusingly. The current
  formula intentionally `codesign --force --sign -` and points the
  user at `chord daemon --resign` for the persistent-identity swap.
- **`chord daemon --resign` orchestrates** codesign + service restart in
  one CLI step. Detection order: `/opt/homebrew/Cellar/chord/*/Chord.app`
  → `/Applications/Chord.app` → `~/Applications/Chord.app`. Picks the
  highest-versioned Cellar entry when multiple are present
  (`sorted(by: >)`). Falls back to `launchctl kickstart` if
  `brew services` fails. Re-sign succeeds with exit 0 even if the
  restart step fails — re-signing is the load-bearing action.
- **Cross-app pattern**: stroke / facet hit the same brew sandbox
  trap. Apply the same `daemon --resign` shape to those repos when
  ferrying changes.

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

- **Grammar**: `chord <domain> --<verb> [--mod]` (yabai-style
  domain-verb, powered by the shared sill CLIKit tokenizer; chord
  keeps its own verb vocabulary). Each domain takes exactly one
  verb; combining verbs, or passing a flag outside its domain,
  exits `2` (unknown flag → "did you mean …?" hint — no silent
  fallback, *Rule of Repair*). **`config` domain** (settings;
  standalone, no daemon) — `config --validate` (`--strict` /
  `--json`) / `config --show` (`--json` / `--include-dropped`) /
  `config --doctor` / `config --emit-schema` (config.toml INPUT
  JSON Schema, Draft-07, for editor completion — emitted from the
  `ChordConfigSchema` descriptor; regenerate the committed
  `config.schema.json` with `chord config --emit-schema >
  config.schema.json`). **`daemon` domain** (lifecycle; needs a
  running daemon, exit `3` if none) — `daemon --reload`
  (`--dry-run`) / `daemon --quit` / `daemon --pause` /
  `daemon --resume` / `daemon --toggle` / `daemon --show` /
  `daemon --watch` / `daemon --resign`. Top-level — `chord` (runs
  the daemon) / `--help` (alias `-h`) / `--version` (alias `-V`).
  Verbose logging is env-var-triggered (`CHORD_DEBUG=1`, set by
  run.sh) — not a flag, so a brew / raw launch stays quiet.
- **CLI is yabai-style domain-verb** (atelier Phase 3 M4). `dispatch(_:)`
  in [Sources/ChordApp/Main.swift](Sources/ChordApp/Main.swift) peels the
  domain noun (`config` / `daemon`) and routes to that domain's verb table
  (`configVerbs` / `daemonVerbs`, each `verb → honoured modifiers`) via
  `dispatchDomain`. The shared sill `CLIKit` tokenizer parses argv (unknown
  flag → loud exit 2 with a nearest-match hint; `-h`/`-V` carve-out);
  `dispatchDomain` then enforces chord's policy: exactly one verb per domain,
  and a recognised modifier the chosen verb doesn't honour is rejected as
  "has no effect with --X" (exit 2 — closes the pre-#63 silent-drop hole
  where `chord daemon --quit --json` used to ignore `--json`). When adding a
  flag, add it to the domain's verb table — do NOT bolt an
  `if args.contains(...)` into `main()`. CLIKit parse errors map to
  `SubcommandOutcome.fail(2, …)` (NOT `CLIKit.die`) so dispatch stays
  unit-testable.
- **Single `exit()` site** lives in `applyOutcome`. Handlers
  return `SubcommandOutcome { exitCode, stdout?, stderr? }` and
  the dispatch entry calls `applyOutcome(_:) -> Never`. The two
  `exit()` calls inside `runServer` are intentional (daemon
  startup-fatal paths, no caller to test). Do NOT scatter `exit()`
  across handlers.
- **`daemon --pause` / `daemon --resume`** flip a single `pausedFlag` guarded by
  `pauseLock`, read from the tap callback's hot path before the
  matcher snapshot is even consulted. `daemon --pause` returns
  `.passthrough` for every event without touching the matcher, so
  the daemon stays AX-granted and the keystroke cost is one bool
  check + one mutex acquire. Intended for screencasts / games /
  Zoom screen-sharing where chord shouldn't be eating input.
- **`daemon --toggle`** is sugar: reads the daemon's status file, looks
  for "paused" / "resumed", and posts the opposite DNC
  notification. Implemented entirely on the client side — no new
  IPC channel. The status file is updated by the server on every
  transition, so a fast `chord daemon --toggle` ↔ `chord daemon --toggle`
  loop stays consistent.
- **`config --validate` is lenient by default; `--strict` is for CI**.
  Without `--strict`, drops are non-fatal (a typo in one binding
  doesn't fail the pipeline). With `--strict`, any warning or
  drop exits `1`. The summary line always prints
  `parsed: N bindings, M fallbacks; dropped: K, warnings: W` —
  machine-readable enough for awk / grep until `config --show --json`
  lands.
- **`config --doctor`** reports Accessibility
  (`Permissions.isAccessibilityTrusted()`), config, daemon
  liveness. Exit 1 if any check fails.
- **`daemon --reload` / `daemon --quit` talk to the running daemon over
  Distributed Notification Center** (`com.chord.app.control`, see
  [Sources/ChordApp/Control.swift](Sources/ChordApp/Control.swift))
  — same pattern as facet / stroke. Don't invent a different IPC **for
  control** (the write-only verbs). They exit `3` if no daemon is running.
- **`daemon --show` is one-way the other direction**: DNC can't reply,
  so the daemon rewrites a small status file
  (`/tmp/chord.status`) on start / reload / each fired binding,
  and `daemon --show` just reads it. The file is enough **for that one
  scalar status line** — don't reach for request/response just to read
  pause state.
- **`chord query --…` is the read-only request/response channel** — the
  deliberate exception to "don't invent an IPC", for structured runtime
  state the scalar status file can't carry: live state-var values (keyed
  by name), loaded-binding counts, the recent-fires history. It's an
  AF_UNIX socket (`/tmp/chord-query.sock`,
  [QuerySchema](Sources/ChordCore/QuerySchema.swift), wire version
  `chord.query.v1`); the daemon listens on a serial queue
  ([QueryServer.swift](Sources/ChordApp/QueryServer.swift)) and replies
  with one JSON document, never touching the tap hot path. The three IPC
  shapes are split by direction + payload and must stay that way:
  **control** (reload / quit / pause) is write-only DNC; the **one scalar
  status line** is the status file; **structured reads** are the query
  socket. Don't collapse them, and don't add a fourth.
- **Config auto-reload**: a `DispatchSource` vnode source on
  [ChordConfig.path](Sources/ChordCore/Models.swift) re-arms on
  the atomic-save rename / delete and calls `controller.reload()`
  on edit. `daemon --reload` is now just the manual trigger for the same
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

### config.toml grammar additions

When a feature PR adds a new section / field to `config.toml`:

- **Breaking changes are OK**. The config grammar is part of the
  versioned `chord.bindings.v*` schema; major bumps are how we
  reshape it. Don't paper over a bad shape with a deprecation
  alias just to avoid the bump — if the new shape is right, ship
  it and bump the schema. (Existing rename history: v0.5 single
  `[aliases]` → v0.6 split `[action-aliases]` / `[input-aliases]`.)
- **Style preference (want / better — not must)**: prefer the
  **self-contained section** shape over **hoisted-shared field**
  shape. Hoisting only one or two fields above N entries is
  usually not worth the syntactic divergence; if every entry can
  carry the shared field with no real cost, that's the cleaner
  shape:

  ```toml
  # preferred (self-contained)
  [[bindings]]
  input = "rctrl + ralt + rshift - c"
  apps = ["com.google.Chrome"]
  action-keys = "ctrl + shift - tab"

  [[bindings]]
  input = "rctrl + ralt + rshift - c"
  apps = ["com.microsoft.VSCode"]
  action-keys = "cmd + shift - ["
  ```

  ```toml
  # disliked (hoisted shared `input`)
  [[bindings]]
  input = "rctrl + ralt + rshift - c"

    [[bindings.per-app]]
    bundle-id = "com.google.Chrome"
    action-keys = "ctrl + shift - tab"

    [[bindings.per-app]]
    bundle-id = "com.microsoft.VSCode"
    action-keys = "cmd + shift - ["
  ```

- **Hoisted-shared shape is OK when it earns its keep**. Examples
  where the disliked shape is currently kept because the
  bookkeeping payoff is large:
  - `[[remap]] modifiers = "..."; map = { … }` collapses N
    bindings (potentially 10+) into one row — significant.
  - `[[sequence]] prefix = "..."; timeout-ms = N; [[sequence.bindings]] …`
    desugars to 1 prefix + N children of state-var binding
    machinery; writing it long-hand is 3× the lines.
  - `[[bindings.per-app]]` is the marginal one — saves only one
    `input` line per binding. Issue #64 tracks the
    deprecation-vs-keep call; new feature PRs should not extend
    the per-app shape without revisiting that issue first.

- **Don't invent a third style**. The two existing shapes
  (self-contained `[[bindings]]` and the three hoisting sugars
  above) are the surface today. Adding e.g. a top-level
  `default-modifiers = "ctrl"` that every section inherits would
  be a new third style; prefer adding a new sugar that follows
  one of the existing shapes.

### CLI option additions

Mirror of the `config.toml` policy above — **same two rules**
applied to flags added to `chord <domain> --<verb> --…`:

- **Breaking changes are OK**. The CLI surface is part of the
  user contract but not the schema-versioned wire contract;
  renames are visible in `--help`, and the README CLI table /
  glossary §7 are kept in sync. Don't add a long-term alias
  (`--old-name` → `--new-name`) just to avoid the rename if the
  new spelling is right. Existing precedent: PR #63 removed
  `chord daemon --quit --json`'s silent-accept-then-drop behaviour
  outright rather than warning-then-removing across two releases.
- **Style preference (want / better — not must)**: each
  verb's modifiers should be **self-contained**. A modifier
  flag belongs to one verb and is declared against it in the
  domain's verb table (`configVerbs` / `daemonVerbs`,
  [Sources/ChordApp/Main.swift](Sources/ChordApp/Main.swift)).
  Avoid:
  - **A global modifier-flag pool** (the pre-#63 design where
    `--strict` / `--json` / `--dry-run` lived in a single
    silently-accepted set, regardless of verb). That's the
    CLI analogue of `config.toml`'s "hoisted shared field" shape —
    same drawbacks: a flag's applicability is invisible at the
    call site.
  - **Aliases that mean different things to different
    verbs**. If `--filter` means "regex" to `config --show` and
    "glob" to `config --validate`, that's the CLI version of inventing
    a third style.
- **Shared spelling is OK when N verbs genuinely share the
  semantic**. `--json` legitimately means "machine-readable
  document" across `config --validate` / `config --show` (and
  `config --doctor`); declaring it against each verb in the domain's
  verb table is the documented form of the shared semantic,
  not boilerplate to flatten.
- **Don't invent a third style**. Today the only shapes are:
  - `chord <DOMAIN> --VERB` (the bare verb that selects the action)
  - `chord <DOMAIN> --VERB --MODIFIER` (modifier flag declared for
    that verb in the domain's verb table — `configVerbs` / `daemonVerbs`
    / `queryVerbs`)
  - `chord <DOMAIN> --VERB --MODIFIER VALUE` (space-separated value via
    CLIKit's `.value` arity — first used by `query --recent-fires
    --limit N`. The value-taking modifiers are listed in the domain's
    `*ValueFlags` set; the value is consumed verbatim, so a `-`-leading
    arg is a value, not a flag — the D0 hazard. Every other modifier is
    still a bare boolean).

  Adding e.g. `chord <DOMAIN> --MODIFIER=value` (`=`-attached value),
  short-flag-clustering (`-sj` for `-s -j`), or positional
  arguments would be a new style. Discuss before introducing one.

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
  `eventMask` of `keyDown | keyUp | flagsChanged | leftMouseDown |
  leftMouseUp | rightMouseDown | rightMouseUp | otherMouseDown |
  otherMouseUp | scrollWheel` (the up variants back the v2 paired
  down/up consume). Reach here when changing the mask, the tap
  location, or the user-data sentinel scheme.
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
  *(reviewed 2026-05-24)* — the IPC chord uses for **control**
  (`daemon --reload` / `daemon --quit`). Fire-and-forget; the status file at
  `/tmp/chord.status` is the scalar reverse channel. Same pattern as
  facet / stroke; don't invent a separate request/response IPC **for
  control**. Read-only structured state is the documented exception —
  the `chord query` AF_UNIX socket
  ([QuerySchema](Sources/ChordCore/QuerySchema.swift), `chord.query.v1`);
  see the §IPC notes above for the three-shapes split.

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
  after Karabiner's popular `Hyper` rule. Don't ship general
  HID-level *remapping* of ordinary keys inside chord — that's
  Karabiner's job. (The v-key path is a deliberately narrow
  exception: it *reads* one self-defined vendor report — usage page
  0xFF31 — from the canon dongle via IOHIDManager and never
  intercepts or remaps normal keyboard HID. See docs/non-goals.md
  §USP / §2.)

### Formats / conventions

- [TOML 1.0.0 spec](https://toml.io/en/v1.0.0)
  *(reviewed 2026-05-24)* — the grammar chord's config implements.
  TOML parsing is delegated to swift-toml-edit's `Toml` module
  (full TOML 1.0); `Sources/ChordCore/TOML.swift` is a thin shim.
  Inline tables ARE supported and chord relies on them (`when-vars
  = { a = 1, b = 2 }`, `[[remap]] map = { … }`). The former
  hand-rolled subset parser is retired; new `.toml` surface is
  bounded by swift-toml-edit's support, not a local parser budget.
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

## Shared libraries (atelier)

chord は swift app family の共有ライブラリに乗る（plan [atelier](https://github.com/akira-toriyama/atelier)）。
共有 lib が持つ責務は**再実装せずライブラリ側を拡張**する（北極星＝「facet の theme を真似て」を二度と言わない）。
モジュール → target の正確な配線は [Package.swift](Package.swift) を正とする。

- **[sill](https://github.com/akira-toriyama/sill)** — 共有 theming / CLI 基盤。設計 → [`docs/DESIGN.md`](https://github.com/akira-toriyama/sill/blob/main/docs/DESIGN.md)。chord は headless ゆえ theming は非消費・`CLIKit`（CLI tokenizer）のみ使用。
- **[swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit)** — family 唯一の TOML 実装（`Toml` module・Swift 版 toml_edit）。chord は config.toml パースに使用。

**自己完結しない — 共有候補は sill に PR を模索**: app 単独で実装する前に「2 つ以上の app で冗長になりそうか」を問い、そうなら sill への PR を検討する（過剰共通化はしない・zero-debt ≠ 全部共有）。

## 作業方針 (multi-session work policy)

長尺の作業を**セッション跨ぎ**で安全に進めるための運用ルール。
記録先は furrow tracker (`akira-toriyama/projects`・label `chord`) →
§Roadmap board / task tracker。破壊的変更 / 品質重視の扱いは既存ポリシーを
参照 — ここでは重複させない: 破壊的変更は §config.toml grammar additions・
§CLI option additions の "Breaking changes are OK"、品質重視は
§Conventions の "Quality-first phased workflow"
("Don't push without explicit OK") が正。

- **1 セッションで完了しなくてよい**。大きな作業は plan(計画)と
  execute(実行)に分け、複数セッションに跨ってよい。途中で
  終わること自体は失敗ではない — 失敗は**進行状況を残さずに
  終わること**。
- **進行状況は必ず 1 箇所に記録し、二重管理しない**。進行中の
  作業ごとに furrow task を 1 枚持ち、その body
  (`furrow show <id>`・`.furrow/bodies/<id>.md`) が進行状況の唯一の真実
  (single source of truth)。Project #5 のミラー (§Roadmap board / task
  tracker) とは**粒度で棲み分ける**: Project = 高レベルな issue /
  milestone の status、task body = その実装のための細粒度な計画 +
  進行ログ。両者は `#N` / `t-NNNN` で相互リンクし、同じ情報を二重に
  持たない。
- **task body の構成**: ゴール (+ `Closes #N`) / 計画チェックリスト /
  進行ログ / 未達成・保留。
- **未達成を暗黙にしない**。チェック未了・保留・既知の積み残しは
  task body に**明示的に**残す (黙って消さない)。「この作業の中で
  まだやる」ものは同 body に、「別途やる」ものは別 task を起票して
  Inbox (status `inbox`) へ — どちらかに必ず可視化する。
- **task のライフサイクル**: 未達成が残る限り task は open
  (`backlog` / `ready` / `in-progress`)。全項目が完了したら status を
  `done` にし、紐付く issue があれば board でも Done へ。→ **open な
  `chord` task に積み残しが残っていない = 進行中の積み残しなし**、
  という不変条件を保つ。
- **セッション境界の所作**: 作業再開時はまず該当 task を読み
  (`furrow ls -l chord` → `furrow show <id>`)、終了時 (あるいは節目) に
  必ず body の進行ログを更新してから終わる。
- **記録形式は furrow の per-task markdown body** (`.furrow/bodies/*.md`・
  手編集 OK)。より良い管理方法が見つかれば乗り換える — その場合も
  この「1 箇所 / 未達成を残す / 粒度で棲み分け」の原則は維持する。
- **これらは原則であって教条ではない**。重視はするが、ある場面で
  適用しても**メリットが無い**、あるいは運用してみて**作業しづらい**
  と感じたら、黙って無視するのでも形だけ遵守するのでもなく
  **相談する** (未達成を暗黙にしないのと同じ精神 — ルールの不都合も
  可視化する)。相談は原則そのものを見直す契機にしてよい
  ([docs/non-goals.md](docs/non-goals.md) の「再検討する条件」と
  同じ姿勢)。

## Roadmap board / task tracker

issue 運用（集約 Project「roadmap」#5・Inbox 既定 / Status フロー / `Closes #N`）は
family 共通ポリシー。正典 → https://github.com/akira-toriyama/atelier/blob/main/docs/roadmap-board.md

chord の作業タスク（バックログ・設計メモ・引き継ぎ）の**正本は private repo
[`akira-toriyama/projects`](https://github.com/akira-toriyama/projects)**（自作 furrow 製・
plain-text の `.furrow/` = JSON index + per-task markdown body）。`chord` ラベルで絞る:
`furrow ls -l chord`（着手候補 = ready / in-progress）/ `furrow show <id>`。`furrow next`
は actionable（next-lane = ready / in-progress かつ deps 完了）を canonical order で出す
（`-l chord` で repo 絞り・`-n` で件数制限）。Project #5 はその公開ミラー（手動）。**`docs/plans/` の plan-file 運用は 2026-06-25 に退役**し projects へ移行
済み（細粒度な計画 + 進行ログは furrow の per-task body が持つ）。furrow 未導入なら
`go install github.com/akira-toriyama/furrow/cmd/furrow@latest`（brew tap には未掲載）、
最悪 `.furrow/`
（index.json + bodies/）を直接読む。`.furrow/index.json` は furrow が機械生成＝手編集禁止・
`bodies/*.md` は手編集 OK。
