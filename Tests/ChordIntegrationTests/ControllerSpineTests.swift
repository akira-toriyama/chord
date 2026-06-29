import Testing
import ChordCore
import ChordAdapterTest
@testable import ChordApp

/// C3 runtime#2 — drives the **real** `Controller.handle()` consume/pass
/// spine through a `TestEventSource`, exercising the production code path
/// that `CLAUDE.md` names "DO NOT regress".
///
/// `TestEventSourceTests` validates a *parallel reimplementation* (it calls
/// `matcher.find()` in its own handler); the actual down/up pairing,
/// autorepeat, on-up, modifier-only and passthrough logic in the Controller
/// had no direct coverage. These tests close that gap by installing the
/// genuine `handle()` via the `startForTesting` seam and asserting both the
/// returned `EventOutcome` and the shared spine state.
///
/// NOTE: the hot-path state (`sharedMatcher`, `pendingUps`, the modifier
/// baseline, the variable store) is module-global; `startForTesting` resets
/// it per call, so every test starts clean regardless of order. `.serialized`
/// makes that ordering guarantee explicit (and survives someone later making
/// a test `async`, which would break the @MainActor-implies-serial property).
@Suite(.serialized) @MainActor
final class ControllerSpineTests {

    /// The tap closure holds only a WEAK reference to the Controller (so the
    /// production cycle Controller→source→closure→Controller doesn't leak).
    /// In production the app owns the Controller; in a test nothing else
    /// does, so we retain every wired Controller here for the instance's
    /// lifetime — otherwise it deallocates and every `feed()` silently
    /// returns `.passthrough`. A fresh test instance per method drops these
    /// naturally; `startForTesting` resets the shared spine state.
    private var live: [Controller] = []

    private func wired(
        _ bindings: [Binding],
        excludeApps: [String] = []
    ) throws
        -> (Controller, TestEventSource)
    {
        let matcher = Matcher(bindings: bindings, excludeApps: excludeApps)
        let src = TestEventSource()
        let ctrl = Controller(source: src)
        try ctrl.startForTesting(matcher: matcher)
        live.append(ctrl)
        return (ctrl, src)
    }

    private func bind(
        _ name: String, _ trigger: Trigger,
        mods: Modifiers = [],
        action: Action = .noop,
        condition: Condition? = nil,
        onUp: Action? = nil,
        passthrough: Bool = false,
        repeatStrategy: RepeatStrategy = .fireEach
    ) -> Binding {
        Binding(
            name: name, trigger: trigger, modifiers: mods, apps: nil,
            action: action, condition: condition, onUpAction: onUp,
            passthrough: passthrough, repeatStrategy: repeatStrategy)
    }

    private func down(
        _ t: Trigger, mods: Modifiers = [],
        repeat isRepeat: Bool = false,
        app: String? = nil
    ) -> InputEvent {
        InputEvent(
            trigger: t, modifiers: mods, frontmostBundleID: app,
            kind: .down, isRepeat: isRepeat)
    }
    private func up(_ t: Trigger, app: String? = nil) -> InputEvent {
        InputEvent(trigger: t, modifiers: [], frontmostBundleID: app, kind: .up)
    }
    private func modsChanged(_ mods: Modifiers, app: String? = nil) -> InputEvent {
        InputEvent(
            trigger: .modifiersOnly, modifiers: mods,
            frontmostBundleID: app, kind: .modifiersChanged)
    }

    // MARK: - B1 contract: down/up pairing

    /// The OS saw NEITHER half of a consumed chord, so the `.up` of a
    /// consumed `.down` must also be consumed; the `.up` of an unmatched
    /// (passed-through) `.down` must pass. Exactly one pending-up is held
    /// between the paired events, and the table empties on release.
    @Test func consumedDownPairsItsUpAndPassthroughDoesNot() throws {
        let (ctrl, src) = try wired([bind("a", .key(0x00))])

        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(
            ctrl.pendingUpCountForTesting() == 1,
            "a consumed down registers exactly one pending up")
        #expect(
            src.feed(up(.key(0x00))) == .consume,
            "the up of a consumed down is consumed (B1)")
        #expect(
            ctrl.pendingUpCountForTesting() == 0,
            "the pending up is removed once paired")

        // An unmatched key: neither half is touched.
        #expect(src.feed(down(.key(0x0B))) == .passthrough)
        #expect(
            ctrl.pendingUpCountForTesting() == 0,
            "a passed-through down registers no pending up")
        #expect(src.feed(up(.key(0x0B))) == .passthrough)

        // A second up for an already-paired trigger is not double-consumed.
        #expect(src.feed(up(.key(0x00))) == .passthrough)
    }

    // MARK: - autorepeat strategy

    /// `repeat = fire-each | ignore | passthrough` decides what the
    /// typematic `.down` (isRepeat == true) does after the initial press.
    /// Asserted on BOTH the outcome AND whether the action re-fires — each
    /// binding toggles a distinct variable, so a mis-wired `.ignore` that
    /// fell through and re-fired would be caught (its outcome alone is
    /// `.consume`, identical to `.fireEach`, and would not distinguish them).
    @Test func autorepeatStrategies() throws {
        let (ctrl, src) = try wired([
            bind(
                "ig", .key(0x01), action: .toggleVariable(name: "ig"),
                repeatStrategy: .ignore),
            bind(
                "pt", .key(0x02), action: .toggleVariable(name: "pt"),
                repeatStrategy: .passthrough),
            bind(
                "fe", .key(0x03), action: .toggleVariable(name: "fe"),
                repeatStrategy: .fireEach)
        ])

        // ignore: initial consumes + fires once; the repeat is also consumed
        // (so the OS never sees a phantom repeat) but the action does NOT
        // re-fire — the toggle stays put.
        #expect(src.feed(down(.key(0x01))) == .consume)
        #expect(ctrl.variableSnapshotForTesting().value("ig") == 1)
        #expect(src.feed(down(.key(0x01), repeat: true)) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("ig") == 1,
            "ignore: the repeat must not re-fire the action")

        // passthrough: initial consumes + fires; the repeat passes to the OS
        // and (returning before dispatch) does not re-fire either.
        #expect(src.feed(down(.key(0x02))) == .consume)
        #expect(ctrl.variableSnapshotForTesting().value("pt") == 1)
        #expect(src.feed(down(.key(0x02), repeat: true)) == .passthrough)
        #expect(
            ctrl.variableSnapshotForTesting().value("pt") == 1,
            "passthrough: the repeat must not re-fire the action")

        // fire-each (default): the repeat is treated like a fresh down and
        // re-fires — the toggle flips back.
        #expect(src.feed(down(.key(0x03))) == .consume)
        #expect(ctrl.variableSnapshotForTesting().value("fe") == 1)
        #expect(src.feed(down(.key(0x03), repeat: true)) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("fe") == 0,
            "fire-each: the repeat re-fires the action")
    }

    // MARK: - on-up dispatch

    /// A binding's `onUpAction` fires when its paired `.up` arrives — here a
    /// `setVariable` that a second binding gates on, proving the on-up ran
    /// through the real `handleKeyUp` path (not just that the up consumed).
    @Test func onUpActionFiresThroughRealPath() throws {
        let (ctrl, src) = try wired([
            bind(
                "leader", .key(0x00),
                onUp: .setVariable(name: "mode", value: 1)),
            bind(
                "gated", .key(0x0B),
                condition: .variable(name: "mode", equals: 1))
        ])

        // Before the leader releases, the gated binding does not match.
        #expect(src.feed(down(.key(0x0B))) == .passthrough)

        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(src.feed(up(.key(0x00))) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("mode") == 1,
            "on-up setVariable ran on release")

        // Now the gated binding matches and consumes.
        #expect(src.feed(down(.key(0x0B))) == .consume)
    }

    // MARK: - state interception on the down path

    /// `toggleVariable` is intercepted by the Controller (state lives here,
    /// not the dispatcher) and flips 0↔1 on each consumed down — the up is
    /// paired but does not toggle.
    @Test func toggleVariableOnDownFlips() throws {
        let (ctrl, src) = try wired([
            bind("t", .key(0x00), action: .toggleVariable(name: "flag"))
        ])

        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("flag") == 1,
            "first down toggles 0 → 1")
        #expect(src.feed(up(.key(0x00))) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("flag") == 1,
            "the paired up does not toggle")
        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(
            ctrl.variableSnapshotForTesting().value("flag") == 0,
            "second down toggles 1 → 0")
    }

    // MARK: - modifier-only entry/exit

    /// A `.modifiersChanged` event never matches a trigger (always passes),
    /// but crosses the entry/exit edges of `.modifiersOnly` bindings through
    /// `fireModifierOnlyBindings` against the shared `prevMods` baseline.
    @Test func modifierOnlyEntryAndExit() throws {
        let (ctrl, src) = try wired([
            bind(
                "win", .modifiersOnly, mods: [.cmd],
                action: .setVariable(name: "win", value: 1),
                onUp: .setVariable(name: "win", value: 0))
        ])

        // Enter cmd → entry action sets win=1; the event still passes.
        #expect(src.feed(modsChanged([.lcmd])) == .passthrough)
        #expect(
            ctrl.variableSnapshotForTesting().value("win") == 1,
            "mask-entry fired the primary action")

        // Release cmd → exit action (onUp) clears win.
        #expect(src.feed(modsChanged([])) == .passthrough)
        #expect(
            ctrl.variableSnapshotForTesting().value("win") == 0,
            "mask-exit fired the onUp action")
    }

    // MARK: - passthrough binding

    /// A `passthrough = true` binding runs its action but lets the original
    /// event reach the OS, and — because the OS sees the native up — it
    /// registers NO pending up.
    @Test func passthroughBindingFiresButDoesNotPair() throws {
        let (ctrl, src) = try wired([
            bind(
                "p", .key(0x00),
                action: .setVariable(name: "p", value: 1),
                passthrough: true)
        ])

        #expect(
            src.feed(down(.key(0x00))) == .passthrough,
            "passthrough binding lets the down reach the OS")
        #expect(
            ctrl.variableSnapshotForTesting().value("p") == 1,
            "the action still fired")
        #expect(
            ctrl.pendingUpCountForTesting() == 0,
            "passthrough binding registers no pending up")
        #expect(
            src.feed(up(.key(0x00))) == .passthrough,
            "and the up passes (no pairing to honor)")
    }
}
