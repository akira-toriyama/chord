import Testing
@testable import ChordCore

/// chord 0.9.0+: `action-toggle-var` flips a variable between 0 and 1
/// on each press. `action-hold-var` is sugar for setVariable(1) on
/// down + setVariable(0) on paired key-up — the existing pendingUps
/// + onUpAction infrastructure handles the up half automatically.
@Suite struct ToggleHoldVarTests {

    // MARK: - action-toggle-var

    @Test func toggleVarProducesToggleAction() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "toggle wm"
        input = "cmd - x"
        action-toggle-var = "wm"
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .toggleVariable(let n) = b.action {
            #expect(n == "wm")
        } else { Issue.record("expected .toggleVariable") }
        // Toggle has no auto-onUp.
        #expect(b.onUpAction == nil)
    }

    @Test func toggleVarRejectsSetValue() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "wm"
        action-set-value = 5
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionSetParseError
        })
    }

    @Test func toggleVarRejectsCombinedWithSetVar() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "wm"
        action-set-var = "other"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionSetParseError &&
            $0.message.contains("mutually exclusive")
        })
    }

    @Test func toggleVarRejectsSeqReservedNamespace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "_seq_intruder"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionSetParseError &&
            $0.message.contains("_seq_")
        })
    }

    @Test func toggleVarOnUpRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-shell = "echo"
        action-toggle-var-on-up = "wm"
        """)
        #expect(res.config.bindings.count == 0)
    }

    // MARK: - action-hold-var

    @Test func holdVarSynthesisesPairedSetClear() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "hold-wm"
        input = "cmd - x"
        action-hold-var = "wm"
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        // Primary = setVariable(wm, 1).
        if case .setVariable(let n, let v) = b.action {
            #expect(n == "wm")
            #expect(v == 1)
        } else { Issue.record("expected .setVariable(_, 1)") }
        // Paired up = setVariable(wm, 0).
        if case .setVariable(let n, let v) = b.onUpAction ?? .noop {
            #expect(n == "wm")
            #expect(v == 0)
        } else { Issue.record("expected onUp .setVariable(_, 0)") }
        // No hold-while / timeout (lifecycle is the paired up).
        #expect(b.holdWhile == nil)
        #expect(b.holdWhileTimeoutMs == nil)
    }

    @Test func holdVarRejectsExplicitOnUp() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "wm"
        action-shell-on-up = "echo nope"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.message.contains("action-hold-var owns the on-up half")
        })
    }

    @Test func holdVarRejectsCombinedWithSetVar() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "wm"
        action-set-var = "other"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionSetParseError
        })
    }

    @Test func holdVarRejectsCombinedWithToggle() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-toggle-var = "a"
        action-hold-var = "b"
        """)
        #expect(res.config.bindings.count == 0)
    }

    @Test func holdVarRejectsSeqReservedNamespace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-hold-var = "_seq_intruder"
        """)
        #expect(res.config.bindings.count == 0)
    }

    // MARK: - Schema round-trip

    @Test func schemaEmitsToggleVariableKind() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "toggle"
        input = "cmd - x"
        action-toggle-var = "wm"
        """)
        let action = try #require(b["action"] as? [String: Any])
        #expect(action["kind"] as? String == "toggle-variable")
        #expect(action["variable"] as? String == "wm")
        #expect(action["value"] == nil, "toggle has no value field")
    }

    @Test func schemaEmitsHoldVarAsSetVariablePair() throws {
        // hold-var is parse-time sugar; the JSON shows the desugared
        // setVariable + setVariable-on-up pair.
        let b = try firstBinding("""
        [[bindings]]
        name = "hold"
        input = "cmd - x"
        action-hold-var = "wm"
        """)
        let primary = try #require(b["action"] as? [String: Any])
        #expect(primary["kind"] as? String == "set-variable")
        #expect(primary["value"] as? Int == 1)
        let onUp = try #require(b["action_on_up"] as? [String: Any])
        #expect(onUp["kind"] as? String == "set-variable")
        #expect(onUp["value"] as? Int == 0)
    }
}
