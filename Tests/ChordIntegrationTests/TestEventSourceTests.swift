import XCTest
import ChordCore
import ChordAdapterTest

final class TestEventSourceTests: XCTestCase {
    @MainActor
    func testHandlerConsumesMatchedAndPassesUnmatched() throws {
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
            let me = Matcher.Event(trigger: event.trigger,
                                   modifiers: event.modifiers,
                                   bundleID: event.frontmostBundleID)
            return matcher.find(me) == nil ? .passthrough : .consume
        }

        let matched = src.feed(.init(trigger: .mouseButton(.side1),
                                     modifiers: [],
                                     frontmostBundleID: nil))
        let unmatched = src.feed(.init(trigger: .key(0x00),
                                       modifiers: [],
                                       frontmostBundleID: nil))
        XCTAssertEqual(matched, .consume)
        XCTAssertEqual(unmatched, .passthrough)
    }

    /// End-to-end happy path for `[[sequence]]` over the synthetic
    /// event source. Controller-side timer behaviour is out of scope
    /// here (`ChordCore` doesn't depend on Dispatch timers); this
    /// pins the **matcher + state-var contract** that the Controller
    /// composes on top of: prefix fires unconditionally and writes
    /// `_seq_<name>`, children fire only while the variable is set.
    @MainActor
    func testSequenceLeaderFlowThroughEventSource() throws {
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
        XCTAssertEqual(result.droppedBindings, 0)
        let matcher = Matcher(bindings: result.config.bindings)

        // Test harness emulates the Controller's state-var write path.
        // Real Controller code lives in ChordApp/ behind AppKit/AX
        // dependencies; here we just need the snapshot-mutation rule.
        var state = StateSnapshot()
        func applyAction(_ action: Action) {
            if case .setVariable(let name, let value) = action {
                var v = state.variables
                if value == 0 { v[name] = nil } else { v[name] = value }
                state = StateSnapshot(variables: v)
            }
        }

        let src = TestEventSource()
        try src.start { event in
            let me = Matcher.Event(trigger: event.trigger,
                                   modifiers: event.modifiers,
                                   bundleID: event.frontmostBundleID,
                                   state: state)
            guard let hit = matcher.find(me) else { return .passthrough }
            applyAction(hit.action)
            return .consume
        }

        // 1. Child key alone (no prefix yet): not in mode → passthrough.
        let kBefore = src.feed(.init(trigger: .key(0x28),       // k
                                     modifiers: [.lcmd, .lopt],
                                     frontmostBundleID: nil))
        XCTAssertEqual(kBefore, .passthrough,
                       "child must not fire before prefix sets _seq_j")
        XCTAssertEqual(state.value("_seq_j"), 0)

        // 2. Prefix: enters mode, consumes, sets _seq_j = 1.
        let prefix = src.feed(.init(trigger: .key(0x26),        // j
                                    modifiers: [.lcmd, .lopt],
                                    frontmostBundleID: nil))
        XCTAssertEqual(prefix, .consume)
        XCTAssertEqual(state.value("_seq_j"), 1)

        // 3. Child within mode: consumes (would emit return).
        let kAfter = src.feed(.init(trigger: .key(0x28),
                                    modifiers: [.lcmd, .lopt],
                                    frontmostBundleID: nil))
        XCTAssertEqual(kAfter, .consume)

        // 4. Second child also fires.
        let lInMode = src.feed(.init(trigger: .key(0x25),       // l
                                     modifiers: [.lcmd, .lopt],
                                     frontmostBundleID: nil))
        XCTAssertEqual(lInMode, .consume)

        // 5. Simulate Controller's timeout clear: var → 0.
        state = StateSnapshot()
        let kAfterTimeout = src.feed(.init(trigger: .key(0x28),
                                           modifiers: [.lcmd, .lopt],
                                           frontmostBundleID: nil))
        XCTAssertEqual(kAfterTimeout, .passthrough,
                       "child should stop firing after timeout-clear")
    }
}
