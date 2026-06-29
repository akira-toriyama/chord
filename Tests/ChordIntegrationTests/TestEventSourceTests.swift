import Foundation
import Testing
import ChordCore
import ChordAdapterTest

@Suite struct TestEventSourceTests {
    @MainActor
    @Test func handlerConsumesMatchedAndPassesUnmatched() throws {
        let cfg = """
            [[bindings]]
            name = "screenshot"
            input = "mouse.side1"
            action-shell = "true"
            """
        let result = try Config.parse(cfg)
        let matcher = Matcher(bindings: result.config.bindings)

        let src = TestEventSource()
        try src.start { event in
            let me = Matcher.Event(
                trigger: event.trigger,
                modifiers: event.modifiers,
                bundleID: event.frontmostBundleID)
            return matcher.find(me) == nil ? .passthrough : .consume
        }

        let matched = src.feed(
            .init(
                trigger: .mouseButton(.side1),
                modifiers: [],
                frontmostBundleID: nil))
        let unmatched = src.feed(
            .init(
                trigger: .key(0x00),
                modifiers: [],
                frontmostBundleID: nil))
        #expect(matched == .consume)
        #expect(unmatched == .passthrough)
    }

    /// End-to-end happy path for `[[sequence]]` over the synthetic
    /// event source. Controller-side timer behaviour is out of scope
    /// here (`ChordCore` doesn't depend on Dispatch timers); this
    /// pins the **matcher + state-var contract** that the Controller
    /// composes on top of: prefix fires unconditionally and writes
    /// `_seq_<name>`, children fire only while the variable is set.
    @MainActor
    @Test func sequenceLeaderFlowThroughEventSource() throws {
        let cfg = """
            [[sequence]]
            name = "j"
            prefix = "cmd + opt - j"
            timeout-ms = 500

              [[sequence.bindings]]
              input = "k"
              action-keys = "return"

              [[sequence.bindings]]
              input = "l"
              action-keys = "backspace"
            """
        let result = try Config.parse(cfg)
        #expect(result.droppedBindings == 0)
        let matcher = Matcher(bindings: result.config.bindings)

        // Stand-in for the Controller's state-var store. The real
        // Controller lives in ChordApp/ behind AppKit/AX deps; here we
        // just need the snapshot-mutation rule (setVariable writes,
        // explicit 0 clears, reload wipes). The closure passed to
        // `src.start` is @Sendable under Swift 6 strict concurrency,
        // so the mutable state needs a reference-type wrapper.
        let state = StateBox()

        let src = TestEventSource()
        try src.start { event in
            let me = Matcher.Event(
                trigger: event.trigger,
                modifiers: event.modifiers,
                bundleID: event.frontmostBundleID,
                state: state.snapshot)
            guard let hit = matcher.find(me) else { return .passthrough }
            state.apply(hit.action)
            return .consume
        }

        // 1. Child key alone (no prefix yet): not in mode → passthrough.
        let kBefore = src.feed(
            .init(
                trigger: .key(0x28),  // k
                modifiers: [.lcmd, .lopt],
                frontmostBundleID: nil))
        #expect(
            kBefore == .passthrough,
            "child must not fire before prefix sets _seq_j")
        #expect(state.snapshot.value("_seq_j") == 0)

        // 2. Prefix: enters mode, consumes, sets _seq_j = 1.
        let prefix = src.feed(
            .init(
                trigger: .key(0x26),  // j
                modifiers: [.lcmd, .lopt],
                frontmostBundleID: nil))
        #expect(prefix == .consume)
        #expect(state.snapshot.value("_seq_j") == 1)

        // 3. Child within mode: consumes (would emit return).
        let kAfter = src.feed(
            .init(
                trigger: .key(0x28),
                modifiers: [.lcmd, .lopt],
                frontmostBundleID: nil))
        #expect(kAfter == .consume)

        // 4. Second child also fires.
        let lInMode = src.feed(
            .init(
                trigger: .key(0x25),  // l
                modifiers: [.lcmd, .lopt],
                frontmostBundleID: nil))
        #expect(lInMode == .consume)

        // 5. Simulate Controller's timeout clear: wipe state.
        state.reset()
        let kAfterTimeout = src.feed(
            .init(
                trigger: .key(0x28),
                modifiers: [.lcmd, .lopt],
                frontmostBundleID: nil))
        #expect(
            kAfterTimeout == .passthrough,
            "child should stop firing after timeout-clear")
    }
}

/// Mutable StateSnapshot wrapper for tests that need to feed a
/// `@Sendable` handler closure (Swift 6 strict concurrency rejects
/// capturing mutable `var state` from such a closure).
///
/// Internal locking is conservative — the test thread is the only
/// writer in practice, but `TestEventSource` documents that callers
/// MAY drive `feed` from another queue, and the same lock protects
/// readers too. `@unchecked Sendable` is the same escape hatch
/// chord's own `nonisolated(unsafe) sharedMatcher` uses.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = StateSnapshot()

    var snapshot: StateSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func apply(_ action: Action) {
        lock.lock(); defer { lock.unlock() }
        if case .setVariable(let name, let value) = action {
            var v = current.variables
            if value == 0 { v[name] = nil } else { v[name] = value }
            current = StateSnapshot(variables: v)
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        current = StateSnapshot()
    }
}
