import ChordAdapterMacOS
import ChordCore
import Foundation

// Controller+DragScroll.swift — the `action-drag-scroll` mode.
//
// Drag-scroll is the only action with a DURATION: the key-down opens it,
// the paired key-up closes it, and in between the [MotionSource] feeds
// pointer deltas here. That span is App-layer state, so the Controller
// owns it — the same reason `setVariable` / `toggleVariable` are
// intercepted here instead of reaching the Adapter's dispatcher.

/// The live drag-scroll mode. Exactly one can be open at a time: the
/// cursor has one anchor, so a second concurrent mode has nothing
/// coherent to mean.
struct DragScrollSession {
    /// The trigger that opened the mode. Only the paired `.up` for THIS
    /// trigger closes it — matching the pendingUps table, which is keyed
    /// the same way and for the same reason (modifiers may have been
    /// released in between).
    let trigger: Trigger
    let bindingName: String
    /// The single variable this binding is gated on, if any. Motion
    /// short-circuits the matcher, so without this nothing would keep a
    /// `hold-while-timeout` on that variable alive across a long drag —
    /// the mode would cut itself off mid-scroll (the B-α reset-on-use
    /// contract, extended to the one path that bypasses `find`).
    let gatedVariable: String?
    var accumulator: DragScrollAccumulator
    /// Monotonic ns of the last `extendTimer` call. Motion arrives ~96×/s
    /// and each extend reschedules a DispatchSourceTimer; throttling to
    /// [extendIntervalNs] keeps that off the hot path without letting the
    /// variable lapse.
    var lastExtendNs: UInt64
    /// Watchdog handle, cancelled when the mode ends normally.
    var watchdog: StateSchedulerToken?
}

/// Cross-thread drag-scroll state, in the same `nonisolated(unsafe)` +
/// NSLock idiom as `sharedMatcher` / `pendingUps`. Every WRITE happens on
/// the main run loop — the tap callback, the vkey run-loop source, the
/// `@MainActor` control paths, and (by an explicit hop, see
/// [startDragScroll]) the watchdog. The lock is what makes the off-main
/// READ safe: `dragScrollStatus()` is answered on the query socket's
/// serial queue.
nonisolated(unsafe) private var dragScrollSession: DragScrollSession?
private let dragScrollLock = NSLock()

/// Whether the [MotionSource] actually installed. `maybeStartMotionSource`
/// is allowed to fail (the Accessibility grant dropped by an ad-hoc re-sign
/// since the main tap was created, the process tap limit) and the daemon
/// deliberately keeps running — but a mode with no capture behind it would
/// still swallow the key, log `drag-scroll: start`, and name itself in
/// `chord query --status`, which is the exact field a user consults to find
/// out what is eating their pointer. Guarded by [dragScrollLock] because the
/// writer is `loadConfig` and the reader is the tap callback.
nonisolated(unsafe) private var motionAvailable = false

/// Run `body` on the mode's single writer thread — inline when already
/// there. Same shape as `MacOSMotionSource.setCapturing`, and for the same
/// reason: hopping when we are already on main would only add a scheduling
/// delay, and it would put the watchdog's effect out of reach of a
/// synchronous test.
private func onMain(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

#if DEBUG
    /// Watchdog scheduler. Shares `DispatchStateScheduler` with the variable
    /// store's B-α timers — same one-shot semantics, same dedicated serial
    /// queue. Swappable under DEBUG because the watchdog is the one wedge
    /// exit no sequence of fed events can reach; a test needs to stand in
    /// for the wall clock. Reset by `startForTesting`.
    nonisolated(unsafe) var dragScrollScheduler: any StateScheduler =
        DispatchStateScheduler()
    /// Where a completed [ScrollTick] goes. Indirected under DEBUG only so a
    /// test can assert on the App-layer motion→scroll path without posting
    /// real CGEvents into whatever window happens to be frontmost on the
    /// machine running the suite.
    nonisolated(unsafe) var dragScrollSink: @Sendable (ScrollTick) -> Void = {
        ActionDispatcher.postScroll($0)
    }
#else
    private let dragScrollScheduler: any StateScheduler = DispatchStateScheduler()
    private let dragScrollSink: @Sendable (ScrollTick) -> Void = {
        ActionDispatcher.postScroll($0)
    }
#endif

/// Minimum gap between `extendTimer` calls during a drag (250 ms).
private let extendIntervalNs: UInt64 = 250_000_000

extension Controller {
    /// Open the mode. Called from the tap callback, inline in the consume
    /// decision for the binding's key-down.
    ///
    /// `trigger` is the EVENT's trigger, not the binding's — a `[[fallbacks]]`
    /// row carries `.anyKey`, while the release that has to close the mode
    /// arrives as the concrete `.key(code)`. Keying on the event is what the
    /// pendingUps table does, for the same reason.
    ///
    /// Idempotent per trigger: macOS autorepeat re-delivers `keyDown` while
    /// the key is held, and re-anchoring the cursor on every typematic tick
    /// would walk the pin across the screen. A repeat for the already-open
    /// trigger is therefore a no-op regardless of the binding's `repeat`
    /// strategy.
    /// Record whether the motion source installed. Called from `loadConfig`
    /// on every reload that declares a drag-scroll binding.
    nonisolated func setMotionAvailable(_ value: Bool) {
        dragScrollLock.lock()
        motionAvailable = value
        dragScrollLock.unlock()
    }

    /// Returns `false` when the mode could not be opened, which happens only
    /// when the motion source failed to install. The caller relays the event
    /// to the OS in that case — swallowing a key for an action that provably
    /// cannot run is worse than not binding it.
    @discardableResult
    nonisolated func startDragScroll(
        spec: DragScrollSpec, binding: Binding, trigger: Trigger
    ) -> Bool {
        var gated: String?
        if case .variable(let name, _) = binding.condition { gated = name }

        dragScrollLock.lock()
        guard motionAvailable else {
            dragScrollLock.unlock()
            Log.line(
                "drag-scroll: '\(binding.name)' inert — the motion source is "
                    + "not installed; relaying the event instead")
            return false
        }
        if let live = dragScrollSession, live.trigger == trigger {
            dragScrollLock.unlock()
            return true  // autorepeat / duplicate down — keep the existing anchor
        }
        // A different trigger already owns the pointer: close that mode
        // first so there is never more than one anchor.
        let previous = dragScrollSession
        dragScrollSession = DragScrollSession(
            trigger: trigger,
            bindingName: binding.name,
            gatedVariable: gated,
            accumulator: DragScrollAccumulator(spec: spec),
            lastExtendNs: DispatchTime.now().uptimeNanoseconds,
            watchdog: nil)
        dragScrollLock.unlock()

        if let previous {
            previous.watchdog?.cancel()
            Log.line(
                "drag-scroll: '\(previous.bindingName)' superseded by "
                    + "'\(binding.name)'")
        }

        // Bound the worst failure mode. If the release edge never arrives
        // — a dropped v-key release report, a dongle unplugged mid-drag —
        // the mode would otherwise pin the cursor and eat pointer motion
        // for the rest of the daemon's life. The watchdog turns "forever"
        // into `max-ms`.
        let weakSelf = WeakWrap(self)
        let token = dragScrollScheduler.schedule(afterMs: spec.maxMs) {
            // Hop to main before touching the mode, so it has exactly ONE
            // writer thread. Every other mutation already happens there (the
            // tap callback, the vkey run-loop source and the @MainActor
            // control paths all run on the main run loop). Firing on the
            // timer's own queue instead would leave two windows open: the
            // session could be nil'd between a concurrent start's two lock
            // acquisitions, and `setCapturing(false)` would take
            // MacOSMotionSource's asynchronous branch — landing its
            // `tapEnable(false)` on a SUCCESSOR session, which then stays
            // live in the table while capturing nothing.
            onMain {
                weakSelf.value?.stopDragScroll(
                    trigger: trigger,
                    reason: "watchdog (\(spec.maxMs)ms)")
            }
        }
        dragScrollLock.lock()
        if var live = dragScrollSession, live.trigger == trigger, live.watchdog == nil {
            live.watchdog = token
            dragScrollSession = live
            dragScrollLock.unlock()
        } else {
            // The mode ended (or was superseded) while we were scheduling.
            dragScrollLock.unlock()
            token.cancel()
        }

        motionSource.setCapturing(true)
        Log.line(
            "drag-scroll: start '\(binding.name)' "
                + "(speed=\(spec.speed) axis=\(spec.axis.rawValue) "
                + "invert=\(spec.invert) max=\(spec.maxMs)ms)")
        return true
    }

    /// Close the mode. `trigger` scopes the stop to one session: the
    /// watchdog for a mode that already ended (and was replaced by a new
    /// one) must not tear down its successor. Pass `nil` to stop
    /// unconditionally — reload / pause / shutdown.
    nonisolated func stopDragScroll(trigger: Trigger?, reason: String) {
        dragScrollLock.lock()
        guard let live = dragScrollSession else {
            dragScrollLock.unlock()
            return
        }
        if let trigger, live.trigger != trigger {
            dragScrollLock.unlock()
            return  // a stale stop for a session that is already gone
        }
        dragScrollSession = nil
        dragScrollLock.unlock()

        live.watchdog?.cancel()
        motionSource.setCapturing(false)
        Log.line("drag-scroll: stop '\(live.bindingName)' (\(reason))")
    }

    /// One pointer delta arrived while the mode is open. Runs on the
    /// motion tap's run loop (the main thread), synchronously inside its
    /// callback — so this must stay allocation-light and lock-brief.
    nonisolated func handleMotion(_ delta: MotionDelta) {
        dragScrollLock.lock()
        guard var live = dragScrollSession else {
            dragScrollLock.unlock()
            return
        }
        let tick = live.accumulator.step(delta)
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldExtend =
            live.gatedVariable != nil
            && now &- live.lastExtendNs >= extendIntervalNs
        if shouldExtend { live.lastExtendNs = now }
        let gated = live.gatedVariable
        dragScrollSession = live
        dragScrollLock.unlock()

        // B-α reset-on-use, for the one path that never reaches `find`:
        // a drag gated on a variable with `hold-while-timeout` counts as
        // use of that variable.
        if shouldExtend, let gated { variableStore.extendTimer(name: gated) }

        // Sub-pixel deltas accumulate rather than post — see
        // DragScrollAccumulator.
        if let tick { dragScrollSink(tick) }
    }

    /// Whether a drag-scroll mode is currently open, and which binding
    /// owns it. Read by `chord query --status` so a wedged pointer is
    /// diagnosable without a debugger.
    nonisolated func dragScrollStatus() -> String? {
        dragScrollLock.lock()
        defer { dragScrollLock.unlock() }
        return dragScrollSession?.bindingName
    }
}

#if DEBUG
    extension Controller {
        /// Restore both DEBUG seams to their production behaviour. Called by
        /// `startForTesting` alongside the other module-global resets, so a
        /// test that swaps the scheduler or the sink cannot leak into the
        /// next one.
        static func resetDragScrollSeamsForTesting() {
            dragScrollScheduler = DispatchStateScheduler()
            dragScrollSink = { ActionDispatcher.postScroll($0) }
        }
    }
#endif
