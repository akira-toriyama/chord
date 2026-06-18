import XCTest
@testable import ChordCore

/// T7a — direct unit coverage for `VariableStore`, the concurrency-
/// sensitive state store extracted from `Controller`. A manual
/// (virtual-clock) [StateScheduler] lets the inactivity-timeout paths
/// be driven deterministically — they were previously unreachable by
/// the integration test, which wiped the store by hand.
final class VariableStoreTests: XCTestCase {

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

        func schedule(afterMs: Int,
                      _ fire: @escaping @Sendable () -> Void) -> StateSchedulerToken {
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

    func testSetThenSnapshotReflectsValue() {
        let (store, _) = makeStore()
        store.set(name: "wm", value: 3, holdWhile: nil, timeoutMs: nil)
        XCTAssertEqual(store.snapshot().value("wm"), 3)
    }

    func testSetZeroClearsEntry() {
        let (store, _) = makeStore()
        store.set(name: "wm", value: 1, holdWhile: nil, timeoutMs: nil)
        store.set(name: "wm", value: 0, holdWhile: nil, timeoutMs: nil)
        // value 0 removes the key entirely (matcher reads unset == 0).
        XCTAssertEqual(store.snapshot().value("wm"), 0)
        XCTAssertTrue(store.snapshot().variables.isEmpty)
    }

    // MARK: - toggle (single-window atomicity)

    func testToggleFlipsAndReturnsOldNew() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.toggle(name: "t").old, 0)
        XCTAssertEqual(store.snapshot().value("t"), 1)
        let second = store.toggle(name: "t")
        XCTAssertEqual(second.old, 1)
        XCTAssertEqual(second.new, 0)
        XCTAssertEqual(store.snapshot().value("t"), 0)
    }

    func testToggleCollapsesAnyNonZeroToZero() {
        let (store, _) = makeStore()
        store.set(name: "t", value: 5, holdWhile: nil, timeoutMs: nil)
        let r = store.toggle(name: "t")
        XCTAssertEqual(r.old, 5)
        XCTAssertEqual(r.new, 0)
        XCTAssertEqual(store.snapshot().value("t"), 0)
    }

    // MARK: - hold-while clearStale

    func testClearStaleRemovesReleasedHoldWhileOnly() {
        let (store, _) = makeStore()
        store.set(name: "held", value: 1, holdWhile: [.cmd], timeoutMs: nil)
        store.set(name: "plain", value: 1, holdWhile: nil, timeoutMs: nil)
        // cmd released entirely → "held" clears; "plain" (no hold-while) stays.
        let cleared = store.clearStale(currentMods: [])
        XCTAssertEqual(cleared, ["held"])
        XCTAssertEqual(store.snapshot().value("held"), 0)
        XCTAssertEqual(store.snapshot().value("plain"), 1)
    }

    func testClearStaleKeepsStillHeldEntry() {
        let (store, _) = makeStore()
        store.set(name: "held", value: 1, holdWhile: [.cmd], timeoutMs: nil)
        // any-side cmd is still satisfied by the left cmd → kept.
        let cleared = store.clearStale(currentMods: [.lcmd])
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(store.snapshot().value("held"), 1)
    }

    // MARK: - inactivity timeout

    func testTimeoutFiresAndClearsEntry() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        XCTAssertEqual(sched.pendingCount, 1)
        XCTAssertEqual(store.snapshot().value("j"), 1)
        sched.fireAll()  // deadline elapses
        XCTAssertEqual(store.snapshot().value("j"), 0, "timeout clears the variable")
    }

    func testExtendTimerReschedules() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        store.extendTimer(name: "j")
        // The old timer is cancelled and a fresh one scheduled — exactly
        // one pending, two total scheduled, one cancelled.
        XCTAssertEqual(sched.scheduleCount, 2)
        XCTAssertEqual(sched.cancelCount, 1)
        XCTAssertEqual(sched.pendingCount, 1)
        XCTAssertEqual(store.snapshot().value("j"), 1)
    }

    func testExtendTimerNoOpWhenNoTimer() {
        let (store, sched) = makeStore()
        store.set(name: "x", value: 1, holdWhile: nil, timeoutMs: nil)
        store.extendTimer(name: "x")       // no timer attached
        store.extendTimer(name: "absent")  // unset variable
        XCTAssertEqual(sched.scheduleCount, 0)
    }

    func testSetZeroCancelsPendingTimer() {
        let (store, sched) = makeStore()
        store.set(name: "j", value: 1, holdWhile: nil, timeoutMs: 800)
        store.set(name: "j", value: 0, holdWhile: nil, timeoutMs: nil)
        XCTAssertEqual(sched.cancelCount, 1)
        XCTAssertEqual(sched.pendingCount, 0)
    }

    // MARK: - reset

    func testResetWipesStateAndCancelsTimers() {
        let (store, sched) = makeStore()
        store.set(name: "a", value: 1, holdWhile: nil, timeoutMs: 500)
        store.set(name: "b", value: 2, holdWhile: nil, timeoutMs: nil)
        store.reset()
        XCTAssertTrue(store.snapshot().variables.isEmpty)
        XCTAssertEqual(sched.pendingCount, 0, "reset cancels pending timers")
    }
}
