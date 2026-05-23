# Architecture

```
                 ┌────────────────────────────────────────┐
                 │            ChordApp (executable)        │
                 │  @main, CLI parsing, Controller, IPC   │
                 └────────────────┬───────────────────────┘
                                  │ depends on
        ┌─────────────────────────┴────────────────────────┐
        ▼                                                  ▼
┌──────────────────────┐                       ┌──────────────────────┐
│ ChordAdapterMacOS    │                       │  ChordCore           │
│ ─ EventTap           │ ─── implements ──────▶│  ─ EventSource (port)│
│ ─ FrontmostTracker   │                       │  ─ Matcher           │
│ ─ ActionDispatcher   │                       │  ─ Config + TOML     │
│ ─ Permissions        │                       │  ─ KeyCodes / Models │
│   (AppKit/CG/AX)     │                       │  (no AppKit / no CG) │
└──────────────────────┘                       └──────────▲───────────┘
                                                          │
                                              implements  │
                                                          │
                                               ┌──────────┴───────────┐
                                               │ ChordAdapterTest      │
                                               │ ─ TestEventSource     │
                                               │ (XCTest only)         │
                                               └──────────────────────┘
```

## Layer rules

`ChordCore` is pure. It can `import Foundation` and `CoreGraphics`
for `CGFloat` / `CGPoint`, but it cannot `import AppKit`,
`CoreGraphics` event types, `ApplicationServices`, `IOKit`, or
anything else that would tie its code to macOS at runtime. Its
unit tests are the contract.

`ChordAdapterMacOS` is the **only** module that touches OS-level
event APIs. If you find yourself writing `CGEvent` outside this
module, there's a missing protocol — add it to `ChordCore` and
have the adapter conform.

`ChordAdapterTest` exists so the matcher pipeline can be driven
end-to-end without real hardware. It is a `.target` (not a
`.testTarget`) so non-test code can import it for sandbox /
fixture work, but in practice only `ChordIntegrationTests` does.

`ChordApp` orchestrates: parse argv, load config, build the
`Matcher`, install the EventSource, and wire the consume/dispatch
loop. Anything that requires `@MainActor` (NSApplication,
NSWorkspace observation, IPC observer registration) lives here.

## The consume / pass spine

The whole reason `chord` exists is that it *swallows* a triggering
event and substitutes an action. The spine that delivers that:

1. `MacOSEventSource.start(handler:)` installs the CGEventTap.
2. The tap's C callback fires on the tap's run loop. It strips
   our own synthetic events (tagged with `syntheticUserData`),
   converts the `CGEvent` to a Core `InputEvent`, and calls the
   handler **synchronously**.
3. The handler is `Controller.handle`, which reads the latest
   `Matcher` snapshot from a lock-guarded slot, asks it for a
   match, and either returns `.passthrough` (no match) or
   dispatches the binding's action and returns `.consume`.
4. `.consume` becomes `nil` returned from the C callback, which
   tells the OS to drop the event.

The decision is synchronous all the way through. AsyncStream is
deliberately not used: by the time an async consumer pulled an
event off the stream, the OS would have already routed it.

## Re-entrancy

`ActionDispatcher.postKeys` posts synthetic events via
`.cghidEventTap`. Those events come back into our own session
tap. To prevent infinite recursion, the dispatcher tags every
synthetic `CGEvent` with `EventTap.syntheticUserData` (a sentinel
value) in the `.eventSourceUserData` field, and the tap callback
short-circuits any event carrying that tag.

## Cross-thread state

`Matcher` snapshots are shared between the main actor (where the
controller publishes a new one after config reload) and the tap
thread (where the callback reads one per event). The slot is a
`nonisolated(unsafe) static var` guarded by a small `NSLock`. The
critical section on either side holds the lock for a single
pointer read/write; do NOT extend it to cover work that could
block.

`FrontmostTracker` is the same shape: NSWorkspace notifications on
main update the slot; the tap thread reads it. App-scoped binding
matches see the bundle id as it was the last time the user
activated an app — drift between event and read is bounded by the
notification latency, which in practice is sub-millisecond.

## What's NOT in scope

- HID-level remapping. Use Karabiner-Elements for that; chord
  taps the result.
- Click-and-drag gestures or path-based input. Use
  [stroke](https://github.com/akira-toriyama/stroke) for that.
- Window-management primitives. Use [yabai](https://github.com/koekeishiya/yabai),
  [Rectangle](https://rectangleapp.com), or
  [facet](https://github.com/akira-toriyama/facet); chord shells
  out to them.
- A settings GUI. Not now, not later. The TOML file is the
  surface.
