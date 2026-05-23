import XCTest
@testable import ChordCore

final class ConfigTests: XCTestCase {
    func testParsesAllActionShapes() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        exclude-apps = ["com.apple.dt.Xcode"]

        [[bindings]]
        name = "launch terminal"
        input = "f13"
        action-shell = "open -a Terminal"

        [[bindings]]
        name = "screenshot"
        input = "mouse.side1"
        action-keys = "cmd + shift - 4"

        [[bindings]]
        name = "block caps"
        input = "caps_lock"
        action-noop = true
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.config.bindings.count, 3)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.options.excludeApps,
                       ["com.apple.dt.Xcode"])

        switch r.config.bindings[0].action {
        case .shell(let s): XCTAssertEqual(s, "open -a Terminal")
        default: XCTFail("expected shell action")
        }
        switch r.config.bindings[1].action {
        case .keys(let mods, let code):
            XCTAssertEqual(mods, [.cmd, .shift])
            XCTAssertEqual(code, 0x15)
        default: XCTFail("expected keys action")
        }
        XCTAssertEqual(r.config.bindings[2].action, .noop)
    }

    func testBadBindingDoesNotBreakOthers() throws {
        let source = """
        [[bindings]]
        name = "bad"
        input = "no-such-key"
        action-shell = "true"

        [[bindings]]
        name = "good"
        input = "f14"
        action-shell = "true"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 1)
        XCTAssertEqual(r.config.bindings.count, 1)
        XCTAssertEqual(r.config.bindings[0].name, "good")
    }
}
