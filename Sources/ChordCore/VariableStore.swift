import Foundation

/// Abstracts the one-shot timer the variable store uses for the B-α
/// inactivity timeout, so [VariableStore] (and therefore ChordCore)
/// stays Foundation-only and unit-testable: production injects a
/// `DispatchSourceTimer`-backed implementation, tests inject a manual /
/// virtual clock. Mirrors the existing `EventSource` injection seam.
public protocol StateScheduler: Sendable {
    /// Run `fire` once after `afterMs` milliseconds. The returned token
    /// cancels the pending fire when `cancel()` is called; cancelling
    /// after the fire has already run is a no-op.
    func schedule(afterMs: Int,
                  _ fire: @escaping @Sendable () -> Void) -> StateSchedulerToken
}

/// Handle to a scheduled [StateScheduler] fire.
public protocol StateSchedulerToken: Sendable {
    func cancel()
}

/// The chord daemon's variable store: the `[String: Int]` state that
/// `Action.setVariable` / `action-toggle-var` write and that
/// `Condition.variable` predicates read, plus the per-variable B-α
/// inactivity timers and the hold-while auto-clear.
///
/// Extracted from `Controller`'s four file-private globals
/// (`sharedState` / `stateLock` / `sharedTimers` / `stateTimerQueue`)
/// so the concurrency-sensitive logic is directly unit-testable. All
/// access is serialised by a single `NSLock`; every public method takes
/// the lock for its whole body so the read-modify-write windows the
/// tap thread and the vkey HID callback share are atomic (notably
/// [toggle], whose read and write MUST stay in one lock window).
///
/// `@unchecked Sendable`: the mutable state is private and guarded by
/// `lock`; the injected `StateScheduler` is `Sendable`.
public final class VariableStore: @unchecked Sendable {
    /// One stored variable. `value` is the current integer; `holdWhile`,
    /// if set, ties the entry's lifetime to a held modifier mask
    /// (cleared via [clearStale] on release); `timeoutMs`, if set, is
    /// the inactivity window after which the entry self-clears.
    public struct Entry: Sendable {
        public let value: Int
        public let holdWhile: Modifiers?
        public let timeoutMs: Int?
        public init(value: Int, holdWhile: Modifiers?, timeoutMs: Int?) {
            self.value = value
            self.holdWhile = holdWhile
            self.timeoutMs = timeoutMs
        }
    }

    private let lock = NSLock()
    private var state: [String: Entry] = [:]
    private var timers: [String: StateSchedulerToken] = [:]
    private let scheduler: StateScheduler

    public init(scheduler: StateScheduler) {
        self.scheduler = scheduler
    }

    /// Value-typed snapshot, safe to hand to the matcher off-lock (the
    /// dictionary is copied inside the lock then released).
    public func snapshot() -> StateSnapshot {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Int] = [:]
        for (k, e) in state { out[k] = e.value }
        return StateSnapshot(variables: out)
    }

    /// Apply a `setVariable`. Writing `0` clears the entry (matches the
    /// matcher's "unset == 0" reading and keeps zeroed keys from
    /// accumulating). `timeoutMs` schedules a B-α inactivity timer;
    /// `nil` (or `value == 0`) cancels any prior timer.
    public func set(name: String, value: Int,
                    holdWhile: Modifiers?, timeoutMs: Int?) {
        lock.lock(); defer { lock.unlock() }
        // Always cancel a pre-existing timer — we are either replacing
        // it (new lifecycle) or clearing the entry.
        cancelTimerLocked(name: name)
        if value == 0 {
            state.removeValue(forKey: name)
        } else {
            state[name] = Entry(value: value, holdWhile: holdWhile,
                                timeoutMs: timeoutMs)
            if let ms = timeoutMs { scheduleTimerLocked(name: name, ms: ms) }
        }
    }

    /// Flip a variable `0↔1` atomically — the read and the write happen
    /// in a SINGLE lock window. Reading via [snapshot] and writing via
    /// [set] would release the lock in between, so two concurrent
    /// toggles could read the same value and lose one flip. Returns
    /// `(old, new)` for logging. Toggles never carry hold-while/timeout,
    /// so any pre-existing timer is cancelled.
    @discardableResult
    public func toggle(name: String) -> (old: Int, new: Int) {
        lock.lock(); defer { lock.unlock() }
        let current = state[name]?.value ?? 0
        cancelTimerLocked(name: name)
        if current == 0 {
            state[name] = Entry(value: 1, holdWhile: nil, timeoutMs: nil)
            return (0, 1)
        } else {
            state.removeValue(forKey: name)
            return (current, 0)
        }
    }

    /// Reset the inactivity timer for a currently-active, timer-bound
    /// variable (B-α reset-on-use): the variable stays alive as long as
    /// the user keeps using it within the timeout window. No-op when the
    /// variable is unset or has no timer.
    public func extendTimer(name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = state[name], let ms = entry.timeoutMs else { return }
        cancelTimerLocked(name: name)
        scheduleTimerLocked(name: name, ms: ms)
    }

    /// Remove every entry whose `holdWhile` mask is no longer satisfied
    /// by `currentMods`. Returns the cleared names so the caller can log
    /// them (the store itself stays log-policy-free for hold-while).
    public func clearStale(currentMods: Modifiers) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var cleared: [String] = []
        for (name, entry) in state {
            guard let hold = entry.holdWhile else { continue }
            if !hold.isStillHeld(in: currentMods) {
                state.removeValue(forKey: name)
                cancelTimerLocked(name: name)
                cleared.append(name)
            }
        }
        return cleared
    }

    /// Wipe the store and cancel all timers. Called on config reload so a
    /// delayed fire can't mutate a stale store and dropped bindings don't
    /// strand state nothing can clear.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        cancelAllTimersLocked()
        state = [:]
    }

    // MARK: - locked helpers (caller holds `lock`)

    /// Timer fired — clear the variable. Re-checks under the lock because
    /// it may have been reset / cleared between scheduling and firing.
    private func timerFired(name: String) {
        lock.lock(); defer { lock.unlock() }
        timers.removeValue(forKey: name)
        if state.removeValue(forKey: name) != nil {
            Log.debug("state: clear \(name) (timeout)")
        }
    }

    private func cancelTimerLocked(name: String) {
        timers.removeValue(forKey: name)?.cancel()
    }

    private func scheduleTimerLocked(name: String, ms: Int) {
        timers[name] = scheduler.schedule(afterMs: ms) { [weak self] in
            self?.timerFired(name: name)
        }
    }

    private func cancelAllTimersLocked() {
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
    }
}
