import Foundation  // NSLock — XCTest used to re-export this transitively
import Testing
@testable import ChordCore

/// T7a — direct unit coverage for `VariableStore`, the concurrency-
/// sensitive state store extracted from `Controller`. A manual
/// (virtual-clock) [StateScheduler] lets the inactivity-timeout paths
/// be driven deterministically — they were previously unreachable by
/// the integration test, which wiped the store by hand.
///
/// Each test builds its own `VariableStore` via `makeStore()`, so there
/// is no shared/global state between tests — the suite is safe to run
/// in parallel (no `.serialized` needed).
@Suite struct VariableStoreTests {

    /// Records scheduled fires and runs them on demand instead of after
    /// a wall-clock delay. Thread-safe (the store calls back into it).
    private final class ManualScheduler: StateScheduler, @unchecked Sendable {
        private final class Token: StateSchedulerToken, @unchecked Sendable {
            let id: Int
            let onCancel: @Sendable (Int) -> Void
            init(id: Int, onCancel: @escaping @Sendable (Int) -> Void) {
                self.id = id; self.onCancel = onCancel
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
            lock.lock(); defer { lock.unlock() }
            let id = nextID; nextID += 1
            pending[id] = fire
            scheduleCount += 1
            return Token(id: id) { [weak self] tid in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
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

        var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    }

    private func makeStore() -> (VariableStore, ManualScheduler) {
        let sched = ManualScheduler()
        return (VariableStore(scheduler: sched), sched)
    }

    // MARK: - set / snapshot

    @Test func setThenSnapshotReflectsValue() {
        let (store, _) = makeStore()
        store.set(name: "wm", value: 3, holdWhile: nil, timeoutMs: nil)
        #expect(store.snapshot().value("wm") == 3)
    }

    @Test func setZeroClearsEntry() {
        let (store, _) = makeStore()
        store.set(name: "wm", value: 1, holdWhile: nil, timeoutMs: nil)
        store.set(name: "wm", value: 0, holdWhile: nil, timeoutMs: nil)
        // value 0 removes the key entirely (matcher reads unset == 0).
        #expect(store.snapshot().value("wm") == 0)
        #expect(store.snapshot().variables.isEmpty)
    }

    // MARK: - toggle (single-window atomicity)

    @Test func toggleFlipsAndReturnsOldNew() {
        let (store, _) = makeStore()
        #expect(store.toggle(name: "t").old == 0)
        #expect(store.snapshot().value("t") == 1)
        let second = store.toggle(name: "t")
        #expect(second.old == 1)
        #expect(second.new == 0)
        #expect(store.snapshot().value("t") == 0)
    }

    @Test func toggleCollapsesAnyNonZeroToZero() {
        let (store, _) = makeStore()
        store.set(name: "t", value: 5, holdWhile: nil, timeoutMs: nil)
        let r = store.toggle(name: "t")
        #expect(r.old == 5)
        #expect(r.new == 0)
        #expect(store.snapshot().value("t") == 0)
    }

    // MARK: - hold-while clearStale

    @Test func clearStaleRemovesReleasedHoldWhileOnly() {
        let (store, _) = makeStore()
        store.set(name: "held", value: 1, holdWhile: [.cmd], timeoutMs: nil)
        store.set(name: "plain", value: 1, holdWhile: nil, timeoutMs: nil)
        // cmd released entirely → "held" clears; "plain" (no hold-while) stays.
        let cleared = store.clearStale(currentMods: [])
        #expect(cleared == ["held"])
        #expect(store.snapshot().value("held") == 0)
        #expect(store.snapshot().value("plain") == 1)
    }

    @Test func clearStaleKeepsStillHeldEntry() {
        let (store, _) = makeStore()
        store.set(name: "held", value: 1, holdWhile: [.cmd], timeoutMs: nil)
        // any-side cmd is still satisfied by the left cmd → kept.
        let cleared = store.clearStale(currentMods: [.lcmd])
        #expect(cleared.isEmpty)
        #expect(store.snapshot().value("held") == 1)
    }

    // MARK: - inactivity timeout

    @Test func timeoutFiresAndClearsEntry() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        #expect(sched.pendingCount == 1)
        #expect(store.snapshot().value("j") == 1)
        sched.fireAll()  // deadline elapses
        #expect(store.snapshot().value("j") == 0, "timeout clears the variable")
    }

    @Test func extendTimerReschedules() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        store.extendTimer(name: "j")
        // The old timer is cancelled and a fresh one scheduled — exactly
        // one pending, two total scheduled, one cancelled.
        #expect(sched.scheduleCount == 2)
        #expect(sched.cancelCount == 1)
        #expect(sched.pendingCount == 1)
        #expect(store.snapshot().value("j") == 1)
    }

    @Test func extendTimerNoOpWhenNoTimer() {
        let (store, sched) = makeStore()
        store.set(name: "x", value: 1, holdWhile: nil, timeoutMs: nil)
        store.extendTimer(name: "x")  // no timer attached
        store.extendTimer(name: "absent")  // unset variable
        #expect(sched.scheduleCount == 0)
    }

    @Test func setZeroCancelsPendingTimer() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        store.set(name: "j", value: 0, holdWhile: nil, timeoutMs: nil)
        #expect(sched.cancelCount == 1)
        #expect(sched.pendingCount == 0)
    }

    // MARK: - reset

    @Test func resetWipesStateAndCancelsTimers() {
        let (store, sched) = makeStore()
        store.set(name: "a", value: 1, holdWhile: nil, timeoutMs: 500)
        store.set(name: "b", value: 2, holdWhile: nil, timeoutMs: nil)
        store.reset()
        #expect(store.snapshot().variables.isEmpty)
        #expect(sched.pendingCount == 0, "reset cancels pending timers")
    }
}
