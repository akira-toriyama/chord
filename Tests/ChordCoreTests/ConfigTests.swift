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

    func testShellPlusKeysCombineOnDown() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree --loading=2000"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.bindings.count, 1)
        let b = r.config.bindings[0]
        // Shell becomes the primary (it fires first on down)…
        switch b.action {
        case .shell(let s):
            XCTAssertEqual(s, "facet --view=tree --loading=2000")
        default: XCTFail("expected shell primary action")
        }
        // …and the keys land in extraDownActions (posted right after).
        XCTAssertEqual(b.extraDownActions.count, 1)
        switch b.extraDownActions.first {
        case .keys(let mods, let code):
            XCTAssertEqual(mods, [.ctrl])
            XCTAssertEqual(code, 0x7C)
        default: XCTFail("expected a chained keys action")
        }
    }

    func testShellPlusBadKeysDropsBinding() throws {
        let source = """
        [[bindings]]
        name = "broken combo"
        input = "ctrl - right"
        action-shell = "true"
        action-keys = "no-such-key"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 1)
        XCTAssertEqual(r.config.bindings.count, 0)
    }

    func testExtraActionsSurfaceInWireSchema() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: r)
        let extra = doc.bindings[0].extraActions
        XCTAssertEqual(extra?.count, 1)
        XCTAssertEqual(extra?.first?.kind, "keys")
        XCTAssertEqual(extra?.first?.key?.keycode, 0x7C)
    }
}
