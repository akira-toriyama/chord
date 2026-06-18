import XCTest
@testable import ChordCore

/// chord 0.9.0+: `passthrough = true` lets a binding fire its action
/// (action-shell only) AND let the original event reach the OS.
/// Replaces the v0.4.0 workaround of posting `action-keys` with the
/// same input as a re-send.
final class PassthroughTests: XCTestCase {

    // MARK: - Parse + Binding shape

    func testPassthroughDefaultsFalse() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo plain"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertFalse(res.config.bindings[0].passthrough)
    }

    func testPassthroughWithActionShell() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "tap-and-relay"
        input = "ctrl + fn - right"
        action-shell = "facet --view=tree"
        passthrough = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.passthrough)
        if case .shell(let s) = b.action {
            XCTAssertEqual(s, "facet --view=tree")
        } else { XCTFail("expected .shell") }
    }

    func testPassthroughWithSetVariableIsAllowed() throws {
        // setVariable + passthrough lets the OS see the keystroke
        // AND the binding write state. Niche but well-defined.
        let res = try Config.parse("""
        [[bindings]]
        name = "passive mode-arm"
        input = "cmd - x"
        action-set-var = "mode"
        passthrough = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertTrue(res.config.bindings[0].passthrough)
        if case .setVariable = res.config.bindings[0].action {} else {
            XCTFail("expected .setVariable")
        }
    }

    // MARK: - Validation: forbidden combinations

    func testPassthroughWithActionKeysRejected() throws {
        // action-keys + passthrough would emit the keystroke twice.
        let res = try Config.parse("""
        [[bindings]]
        name = "conflict"
        input = "cmd - x"
        action-keys = "cmd - y"
        passthrough = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("passthrough")
        })
    }

    func testPassthroughWithShellPlusKeysRejected() throws {
        // Multi-action (shell + extra keys) + passthrough is the
        // explicit duplicate of the v0.4.0 workaround — pick one.
        let res = try Config.parse("""
        [[bindings]]
        name = "conflict-multi"
        input = "ctrl + fn - right"
        action-shell = "facet --view=tree"
        action-keys = "ctrl + fn - right"
        passthrough = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("passthrough")
        })
    }

    func testPassthroughWithActionNoopRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "absurd"
        input = "cmd - x"
        action-noop = true
        passthrough = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingAction &&
            $0.message.contains("passthrough")
        })
    }

    func testPassthroughWithOnUpRejected() throws {
        // No paired-up is captured when the event flows through, so
        // action-*-on-up would never fire — make the contradiction
        // explicit at parse time.
        let res = try Config.parse("""
        [[bindings]]
        name = "conflict-onup"
        input = "cmd - x"
        action-shell = "echo down"
        action-shell-on-up = "echo up"
        passthrough = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingAction &&
            $0.message.contains("on-up")
        })
    }

    // MARK: - Schema round-trip

    func testSchemaEmitsPassthrough() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "relay"
        input = "ctrl - x"
        action-shell = "echo"
        passthrough = true
        """)
        XCTAssertEqual(b["passthrough"] as? Bool, true)
    }

    func testSchemaOmitsPassthroughWhenFalse() throws {
        // Nil-Optional fields are omitted by JSONEncoder — keeps the
        // common case (passthrough = false) lean.
        let b = try firstBinding("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo"
        """)
        XCTAssertNil(b["passthrough"],
                     "passthrough is omitted from JSON when false")
    }
}
