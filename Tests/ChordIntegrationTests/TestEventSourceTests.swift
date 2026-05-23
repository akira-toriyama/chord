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
}
