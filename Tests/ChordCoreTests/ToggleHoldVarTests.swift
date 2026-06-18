import XCTest
@testable import ChordCore

/// chord 0.9.0+: `action-toggle-var` flips a variable between 0 and 1
/// on each press. `action-hold-var` is sugar for setVariable(1) on
/// down + setVariable(0) on paired key-up — the existing pendingUps
/// + onUpAction infrastructure handles the up half automatically.
final class ToggleHoldVarTests: XCTestCase {

    // MARK: - action-toggle-var

    func testToggleVarProducesToggleAction() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "toggle wm"
        input = "cmd - x"
        action-toggle-var = "wm"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .toggleVariable(let n) = b.action {
            XCTAssertEqual(n, "wm")
        } else { XCTFail("expected .toggleVariable") }
        // Toggle has no auto-onUp.
        XCTAssertNil(b.onUpAction)
    }

    func testToggleVarRejectsSetValue() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "wm"
        action-set-value = 5
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionSetParseError
        })
    }

    func testToggleVarRejectsCombinedWithSetVar() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "wm"
        action-set-var = "other"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionSetParseError &&
            $0.message.contains("mutually exclusive")
        })
    }

    func testToggleVarRejectsSeqReservedNamespace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "_seq_intruder"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionSetParseError &&
            $0.message.contains("_seq_")
        })
    }

    func testToggleVarOnUpRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-shell = "echo"
        action-toggle-var-on-up = "wm"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
    }

    // MARK: - action-hold-var

    func testHoldVarSynthesisesPairedSetClear() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "hold-wm"
        input = "cmd - x"
        action-hold-var = "wm"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        // Primary = setVariable(wm, 1).
        if case .setVariable(let n, let v) = b.action {
            XCTAssertEqual(n, "wm")
            XCTAssertEqual(v, 1)
        } else { XCTFail("expected .setVariable(_, 1)") }
        // Paired up = setVariable(wm, 0).
        if case .setVariable(let n, let v) = b.onUpAction ?? .noop {
            XCTAssertEqual(n, "wm")
            XCTAssertEqual(v, 0)
        } else { XCTFail("expected onUp .setVariable(_, 0)") }
        // No hold-while / timeout (lifecycle is the paired up).
        XCTAssertNil(b.holdWhile)
        XCTAssertNil(b.holdWhileTimeoutMs)
    }

    func testHoldVarRejectsExplicitOnUp() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "wm"
        action-shell-on-up = "echo nope"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.message.contains("action-hold-var owns the on-up half")
        })
    }

    func testHoldVarRejectsCombinedWithSetVar() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "wm"
        action-set-var = "other"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionSetParseError
        })
    }

    func testHoldVarRejectsCombinedWithToggle() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "a"
        action-hold-var = "b"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
    }

    func testHoldVarRejectsSeqReservedNamespace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "_seq_intruder"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
    }

    // MARK: - Schema round-trip

    func testSchemaEmitsToggleVariableKind() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "toggle"
        input = "cmd - x"
        action-toggle-var = "wm"
        """)
        let action = try XCTUnwrap(b["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "toggle-variable")
        XCTAssertEqual(action["variable"] as? String, "wm")
        XCTAssertNil(action["value"], "toggle has no value field")
    }

    func testSchemaEmitsHoldVarAsSetVariablePair() throws {
        // hold-var is parse-time sugar; the JSON shows the desugared
        // setVariable + setVariable-on-up pair.
        let b = try firstBinding("""
        [[bindings]]
        name = "hold"
        input = "cmd - x"
        action-hold-var = "wm"
        """)
        let primary = try XCTUnwrap(b["action"] as? [String: Any])
        XCTAssertEqual(primary["kind"] as? String, "set-variable")
        XCTAssertEqual(primary["value"] as? Int, 1)
        let onUp = try XCTUnwrap(b["action_on_up"] as? [String: Any])
        XCTAssertEqual(onUp["kind"] as? String, "set-variable")
        XCTAssertEqual(onUp["value"] as? Int, 0)
    }
}
