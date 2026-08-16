import ChordAdapterTest
import ChordCore
import Foundation
import Testing

@testable import ChordApp

/// The `action-drag-scroll` mode driven through the **real**
/// `Controller.handle()` spine, same seam as `ControllerSpineTests`.
///
/// What matters here is not the arithmetic (that is
/// `DragScrollTests`) but the **arm / disarm ledger**. Drag-scroll pins
/// the cursor, so a mode that outlives its trigger is the one failure the
/// user cannot click their way out of. Every test below therefore asserts
/// on `TestMotionSource.captureLog` — the ordered record of every
/// `setCapturing` transition — and `[true, false]` is the shape of a
/// correctly-closed drag.
///
/// Deltas are fed at a speed low enough that no whole scroll pixel is ever
/// reached, so these tests exercise the delivery path without posting real
/// CGEvent scrolls into whatever window happens to be frontmost on the
/// machine running them.
/// Stands in for the wall clock so the `max-ms` watchdog — the one wedge
/// exit no sequence of fed events can reach — is drivable. Same shape as
/// `VariableStoreTests.ManualScheduler`. File scope, not nested, so it keeps
/// the `nonisolated` conformance the protocol needs.
private final class ManualScheduler: StateScheduler, @unchecked Sendable {
    private final class Token: StateSchedulerToken, @unchecked Sendable {
        let id: Int
        let onCancel: @Sendable (Int) -> Void
        init(id: Int, onCancel: @escaping @Sendable (Int) -> Void) {
            self.id = id
            self.onCancel = onCancel
        }
        func cancel() { onCancel(id) }
    }
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: () -> Void] = [:]
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(
        afterMs: Int,
        _ fire: @escaping @Sendable () -> Void
    ) -> StateSchedulerToken {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        pending[id] = fire
        scheduleCount += 1
        return Token(id: id) { [weak self] tid in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.pending.removeValue(forKey: tid) != nil { self.cancelCount += 1 }
        }
    }

    /// Simulate every pending deadline elapsing at once.
    func fireAll() {
        lock.lock()
        let fires = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for f in fires { f() }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

/// Collects the ticks `handleMotion` would have posted, so the App-layer
/// motion→scroll path can be asserted without firing real scroll events into
/// whatever window is frontmost on the machine running the suite.
private final class TickSink: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [ScrollTick] = []
    func append(_ t: ScrollTick) {
        lock.lock()
        defer { lock.unlock() }
        ticks.append(t)
    }
    var values: [ScrollTick] {
        lock.lock()
        defer { lock.unlock() }
        return ticks
    }
}

/// Small enough that a 1px delta never completes a scroll pixel — the default
/// for tests that are about the arm/disarm ledger rather than the scroll
/// output, so they never post a real CGEvent.
private let inertSpeed = 0.001

@Suite(.serialized) @MainActor
final class DragScrollSpineTests {

    /// Retained for the same reason `ControllerSpineTests` retains: the tap
    /// closure holds the Controller weakly, so a dropped reference silently
    /// turns every `feed()` into `.passthrough`.
    private var live: [Controller] = []

    private func wired(
        _ bindings: [Binding],
        fallbacks: [Binding] = []
    ) throws -> (Controller, TestEventSource, TestMotionSource) {
        let src = TestEventSource()
        let motion = TestMotionSource()
        let ctrl = Controller(source: src, motionSource: motion)
        try ctrl.startForTesting(
            matcher: Matcher(bindings: bindings, fallbacks: fallbacks, excludeApps: []))
        live.append(ctrl)
        return (ctrl, src, motion)
    }

    private func dragBinding(
        _ name: String = "drag",
        trigger: Trigger = .key(0x00),
        spec: DragScrollSpec = DragScrollSpec(speed: inertSpeed),
        condition: Condition? = nil
    ) -> Binding {
        Binding(
            name: name, trigger: trigger, modifiers: [], apps: nil,
            action: .dragScroll(spec), condition: condition)
    }

    private func down(
        _ t: Trigger, app: String? = nil, repeat isRepeat: Bool = false
    ) -> InputEvent {
        InputEvent(
            trigger: t, modifiers: [], frontmostBundleID: app,
            kind: .down, isRepeat: isRepeat)
    }
    private func up(_ t: Trigger, app: String? = nil) -> InputEvent {
        InputEvent(trigger: t, modifiers: [], frontmostBundleID: app, kind: .up)
    }

    // MARK: - the normal span

    @Test func downArmsTheCaptureAndTheReleaseDisarmsIt() throws {
        let (_, src, motion) = try wired([dragBinding()])

        #expect(motion.startCount == 1, "a drag-scroll config installs the capture")
        #expect(!motion.isCapturing, "installed disarmed — no drag has started")
        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(motion.isCapturing, "the down opens the mode")

        #expect(src.feed(up(.key(0x00))) == .consume, "B1 still holds — the up is consumed")
        #expect(!motion.isCapturing, "the release closes the mode")
        #expect(motion.captureLog == [true, false])
    }

    /// The release closes the mode even when the pending-up entry names a
    /// DIFFERENT binding. Autorepeat re-runs `registerPendingUp` against a
    /// freshly re-evaluated matcher, so any mid-hold change in match state
    /// (frontmost app, gate variable, input source) overwrites the entry —
    /// and a release that trusted it would leave the cursor pinned until the
    /// watchdog.
    @Test func releaseClosesTheModeWhenAutorepeatRematchedToAnotherBinding() throws {
        // An app-scoped drag row plus a wildcard fallback — the documented
        // shape, and the one where a mid-hold app switch changes the match.
        var drag = dragBinding("drag", trigger: .key(0x00))
        drag.apps = ["com.apple.Safari"]
        let sound = Binding(
            name: "fallback", trigger: .anyKey, modifiers: [], apps: nil, action: .noop)
        let (ctrl, src, motion) = try wired([drag], fallbacks: [sound])

        #expect(src.feed(down(.key(0x00), app: "com.apple.Safari")) == .consume)
        #expect(motion.isCapturing, "the down opens the mode")

        // The frontmost app changes mid-hold, so the next typematic tick
        // matches the fallback and overwrites pendingUps[.key(0x00)].
        #expect(src.feed(down(.key(0x00), app: "com.apple.Finder", repeat: true)) == .consume)
        #expect(motion.isCapturing, "a repeat elsewhere must not close the live mode")

        #expect(src.feed(up(.key(0x00), app: "com.apple.Finder")) == .consume)
        #expect(!motion.isCapturing, "the release closes the mode it no longer pairs with")
        #expect(ctrl.dragScrollStatus() == nil)
        #expect(motion.captureLog == [true, false])
    }

    @Test func motionIsDeliveredOnlyWhileArmed() throws {
        let (_, src, motion) = try wired([dragBinding()])

        motion.feed(MotionDelta(dx: 1, dy: 1))
        #expect(motion.delivered.isEmpty, "motion before the drag reaches nothing")

        src.feed(down(.key(0x00)))
        motion.feed(MotionDelta(dx: 1, dy: 1))
        motion.feed(MotionDelta(dx: 1, dy: 1))
        #expect(motion.delivered.count == 2)

        src.feed(up(.key(0x00)))
        motion.feed(MotionDelta(dx: 1, dy: 1))
        #expect(motion.delivered.count == 2, "motion after the release reaches nothing")
    }

    /// A keyboard-only config must not install a motion tap at all — the
    /// whole reason motion lives on a second, lazily-created source.
    @Test func aConfigWithoutDragScrollNeverArmsTheMotionSource() throws {
        let plain = Binding(
            name: "plain", trigger: .key(0x00), modifiers: [], apps: nil,
            action: .noop)
        let (_, src, motion) = try wired([plain])

        #expect(src.feed(down(.key(0x00))) == .consume)
        #expect(src.feed(up(.key(0x00))) == .consume)
        #expect(motion.captureLog.isEmpty)
        #expect(motion.startCount == 0, "the capture is never even installed")
    }

    /// The session is keyed by the EVENT's trigger, not the binding's. A
    /// `[[fallbacks]]` row carries `.anyKey` while the release that has to
    /// close the mode arrives as a concrete `.key(code)` — the one shape
    /// where the two differ.
    @Test func aWildcardFallbackDragIsKeyedByTheConcreteRelease() throws {
        let wildcard = Binding(
            name: "any-drag", trigger: .anyKey, modifiers: [], apps: nil,
            action: .dragScroll(DragScrollSpec(speed: inertSpeed)))
        let (ctrl, src, motion) = try wired([], fallbacks: [wildcard])

        #expect(src.feed(down(.key(0x05))) == .consume)
        #expect(ctrl.dragScrollStatus() == "any-drag")

        #expect(src.feed(up(.key(0x05))) == .consume)
        #expect(motion.captureLog == [true, false], "the concrete release closes it")
        #expect(ctrl.dragScrollStatus() == nil)
    }

    /// The App-layer motion path: `handleMotion` has to write the stepped
    /// accumulator BACK into the session, or the sub-pixel carry is lost on
    /// every event and `speed < 1` never scrolls. Asserted through the sink
    /// rather than a real CGEvent post.
    @Test func motionAccumulatesThroughTheSessionAndReachesTheSink() throws {
        let ticks = TickSink()
        let (_, src, motion) = try wired([
            dragBinding("drag", spec: DragScrollSpec(speed: 0.5))
        ])
        dragScrollSink = { ticks.append($0) }

        src.feed(down(.key(0x00)))
        for _ in 0..<4 { motion.feed(MotionDelta(dx: 0, dy: 1)) }
        src.feed(up(.key(0x00)))

        // 4 × 1px × 0.5 = 2px, delivered as two whole-pixel ticks. Without
        // the write-back every event would carry 0.5 and round to zero.
        #expect(
            ticks.values == [
                ScrollTick(vertical: 1, horizontal: 0),
                ScrollTick(vertical: 1, horizontal: 0)
            ])
    }

    // MARK: - the wedge safety nets

    /// macOS re-delivers `keyDown` while a key is held. Re-opening the mode
    /// on every typematic tick would re-latch the cursor anchor, walking
    /// the pin across the screen as the user drags.
    @Test func autorepeatDoesNotReArmTheMode() throws {
        let (_, src, motion) = try wired([dragBinding()])

        src.feed(down(.key(0x00)))
        src.feed(down(.key(0x00), repeat: true))
        src.feed(down(.key(0x00), repeat: true))

        // `captureLog` alone cannot see this: re-arming an armed capture is a
        // no-op transition, so it would read `[true]` with or without the
        // per-trigger early return. `setCapturingCalls` records every call,
        // which is where a re-latched anchor would show.
        #expect(motion.setCapturingCalls == [true], "one arm request, not one per repeat")
        #expect(motion.captureLog == [true])
        src.feed(up(.key(0x00)))
        #expect(motion.captureLog == [true, false])
    }

    /// One anchor means one mode. A second drag trigger takes over rather
    /// than running alongside.
    @Test func aSecondTriggerSupersedesTheFirst() throws {
        let (_, src, motion) = try wired([
            dragBinding("a", trigger: .key(0x00)),
            dragBinding("b", trigger: .key(0x01))
        ])

        src.feed(down(.key(0x00)))
        src.feed(down(.key(0x01)))
        #expect(motion.isCapturing)

        // The superseded trigger's release must not close the live mode.
        src.feed(up(.key(0x00)))
        #expect(motion.isCapturing, "a stale release does not close its successor")

        src.feed(up(.key(0x01)))
        #expect(!motion.isCapturing)
    }

    /// A reload wipes daemon state. The binding that owns the mode may be
    /// gone from the new config, which would leave the cursor pinned with
    /// nothing able to release it — the same silent-leak shape the variable
    /// store guards against, except the user cannot work around this one.
    @Test func reloadClosesAnOpenMode() throws {
        let (ctrl, src, motion) = try wired([dragBinding()])

        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)

        // startForTesting resets the spine exactly as a reload does.
        try ctrl.startForTesting(matcher: Matcher(bindings: [], excludeApps: []))
        #expect(!motion.isCapturing, "reload closes the mode")
        #expect(motion.startCount == 1, "a reload does not re-install the capture")
    }

    /// The release can arrive with no pending-up behind it (a reload
    /// cleared the table between the down and the up). The mode still has
    /// to close — it is keyed on the trigger, not on the pending-up entry.
    @Test func releaseClosesTheModeEvenWithNoPendingUp() throws {
        let (ctrl, src, motion) = try wired([dragBinding()])

        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)

        // Drop just the pending-up table, leaving the mode open — what a
        // partially-applied reset would look like.
        ctrl.clearPendingUpsForTesting()
        #expect(src.feed(up(.key(0x00))) == .passthrough)
        #expect(!motion.isCapturing, "the release closes the mode regardless")
    }

    /// The `max-ms` watchdog. Unlike the other four exits this one cannot be
    /// reached by feeding events — it exists precisely for the case where the
    /// release edge never arrives (an unplugged dongle, a dropped v-key
    /// release report), so it is driven through the injected scheduler.
    @Test func theWatchdogClosesAModeWhoseReleaseNeverArrives() throws {
        let clock = ManualScheduler()
        let (ctrl, src, motion) = try wired([dragBinding()])
        dragScrollScheduler = clock

        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)
        #expect(clock.scheduleCount == 1, "opening the mode arms the watchdog")

        clock.fireAll()  // max-ms elapses with no release in sight
        #expect(!motion.isCapturing, "the watchdog closes the mode")
        #expect(ctrl.dragScrollStatus() == nil)
        #expect(motion.captureLog == [true, false])
    }

    /// A normal release must cancel the watchdog, or a later, unrelated drag
    /// would be torn down by the previous one's pending fire.
    @Test func aNormalReleaseCancelsTheWatchdog() throws {
        let clock = ManualScheduler()
        let (_, src, motion) = try wired([dragBinding()])
        dragScrollScheduler = clock

        src.feed(down(.key(0x00)))
        src.feed(up(.key(0x00)))
        #expect(clock.cancelCount == 1)
        #expect(clock.pendingCount == 0)

        // A second drag survives the first one's (already cancelled) deadline.
        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)
        #expect(motion.captureLog == [true, false, true])
    }

    /// `daemon --pause` means "chord stops eating input", and a pinned cursor
    /// is the loudest form of it. The paused hot path returns before the
    /// matcher, so the release that would normally close the mode never
    /// arrives — pausing has to close it directly.
    @Test func pauseClosesAnOpenMode() throws {
        let (ctrl, src, motion) = try wired([dragBinding()])

        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)

        ctrl.setPausedForTesting(true)
        #expect(!motion.isCapturing, "pausing closes the mode")
        #expect(ctrl.dragScrollStatus() == nil)
        ctrl.setPausedForTesting(false)
    }

    /// Daemon shutdown. Also pins the ordering: `stopDragScroll` has to run
    /// before `motionSource.stop()`, or the mode would outlive its capture.
    @Test func daemonStopClosesAnOpenMode() throws {
        let (ctrl, src, motion) = try wired([dragBinding()])

        src.feed(down(.key(0x00)))
        #expect(motion.isCapturing)

        ctrl.stop()
        #expect(!motion.isCapturing, "daemon stop closes the mode")
        #expect(ctrl.dragScrollStatus() == nil)
        #expect(motion.captureLog == [true, false], "closed once, not twice")
    }

    // MARK: - observability

    @Test func statusNamesTheBindingHoldingThePointer() throws {
        let (ctrl, src, _) = try wired([dragBinding("grab")])

        #expect(ctrl.dragScrollStatus() == nil)
        src.feed(down(.key(0x00)))
        #expect(
            ctrl.dragScrollStatus() == "grab",
            "`chord query --status` can name what is eating the pointer")
        src.feed(up(.key(0x00)))
        #expect(ctrl.dragScrollStatus() == nil)
    }
}
