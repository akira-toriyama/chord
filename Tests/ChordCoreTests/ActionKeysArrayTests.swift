import XCTest
@testable import ChordCore

/// chord 0.9.0+: `action-keys` accepts a string OR an array of
/// strings. The first element becomes the binding's primary action;
/// the rest land on `Binding.extraDownActions` and fire in order on
/// the same key-down (same path the v0.4.0 `action-shell + action-keys`
/// multi-action uses).
final class ActionKeysArrayTests: XCTestCase {

    // MARK: - Single-string form (regression)

    func testSingleStringActionKeysUnchanged() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        action-keys = "cmd - c"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .keys(_, let kc) = b.action {
            XCTAssertEqual(kc, 0x08)   // 'c'
        } else { XCTFail("expected .keys primary") }
        XCTAssertTrue(b.extraDownActions.isEmpty)
        XCTAssertEqual(b.actionRaw, "cmd - c")
    }

    // MARK: - Array form

    func testArrayFormBuildsPrimaryPlusExtras() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "copy-switch-paste"
        input = "cmd - p"
        action-keys = ["cmd - c", "cmd - tab", "cmd - v"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        // Primary = first element ('c').
        if case .keys(_, let kc) = b.action {
            XCTAssertEqual(kc, 0x08)
        } else { XCTFail("expected .keys primary") }
        // Extras = rest of array.
        XCTAssertEqual(b.extraDownActions.count, 2)
        if case .keys(_, let kc) = b.extraDownActions[0] {
            XCTAssertEqual(kc, 0x30)    // 'tab'
        } else { XCTFail("extras[0] should be .keys") }
        if case .keys(_, let kc) = b.extraDownActions[1] {
            XCTAssertEqual(kc, 0x09)    // 'v'
        } else { XCTFail("extras[1] should be .keys") }
    }

    func testSingleElementArrayBehavesLikeString() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single-array"
        input = "cmd - x"
        action-keys = ["cmd - c"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .keys(_, let kc) = b.action {
            XCTAssertEqual(kc, 0x08)
        } else { XCTFail("expected .keys") }
        XCTAssertTrue(b.extraDownActions.isEmpty,
                      "1-element array → primary only, no extras")
    }

    // MARK: - Combined with action-shell (v0.4.0 multi-action extended)

    func testShellPlusKeysArrayLayersAsExtras() throws {
        // action-shell is primary, every array element is an extra.
        let res = try Config.parse("""
        [[bindings]]
        name = "shell-plus-arr"
        input = "cmd - x"
        action-shell = "echo hi"
        action-keys = ["cmd - c", "cmd - v"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .shell = b.action {} else { XCTFail("expected .shell primary") }
        XCTAssertEqual(b.extraDownActions.count, 2)
    }

    func testShellPlusKeysStringStillWorks() throws {
        // Regression for v0.4.0 single-string multi-action form.
        let res = try Config.parse("""
        [[bindings]]
        name = "v04-style"
        input = "cmd - x"
        action-shell = "echo hi"
        action-keys = "cmd - c"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .shell = b.action {} else { XCTFail("expected .shell") }
        XCTAssertEqual(b.extraDownActions.count, 1)
    }

    // MARK: - Validation

    func testEmptyArrayRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "empty"
        input = "cmd - x"
        action-keys = []
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("at least one")
        })
    }

    func testNonStringElementRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-element"
        input = "cmd - x"
        action-keys = ["cmd - c", 42]
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    func testUnparseableElementRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-token"
        input = "cmd - x"
        action-keys = ["cmd - c", "not-a-key"]
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    func testOnUpArrayRejected() throws {
        // Binding.onUpAction is a single Action; on-up array would
        // silently drop extras. Reject at parse to keep the user
        // honest.
        let res = try Config.parse("""
        [[bindings]]
        name = "onup-array"
        input = "cmd - x"
        action-shell = "echo down"
        action-keys-on-up = ["cmd - c", "cmd - v"]
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("on-up")
        })
    }

    func testOnUpSingleStringStillWorks() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "onup-single"
        input = "cmd - x"
        action-shell = "echo down"
        action-keys-on-up = "cmd - c"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .keys = res.config.bindings[0].onUpAction {} else {
            XCTFail("expected .keys onUp")
        }
    }

    // MARK: - Schema round-trip

    func testSchemaEmitsExtraActionsForKeysArray() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "seq"
        input = "cmd - p"
        action-keys = ["cmd - c", "cmd - v"]
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        // Primary is keys.
        let action = b["action"] as! [String: Any]
        XCTAssertEqual(action["kind"] as? String, "keys")
        // Extra actions emitted.
        let extras = b["extra_actions"] as! [[String: Any]]
        XCTAssertEqual(extras.count, 1)
        XCTAssertEqual(extras[0]["kind"] as? String, "keys")
    }
}
