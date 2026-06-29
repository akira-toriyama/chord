import Testing
@testable import ChordCore

/// chord 0.9.0+: `passthrough = true` lets a binding fire its action
/// (action-shell only) AND let the original event reach the OS.
/// Replaces the v0.4.0 workaround of posting `action-keys` with the
/// same input as a re-send.
@Suite struct PassthroughTests {

    // MARK: - Parse + Binding shape

    @Test func passthroughDefaultsFalse() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "plain"
            input = "cmd - x"
            action-shell = "echo plain"
            """)
        #expect(res.config.bindings.count == 1)
        #expect(!res.config.bindings[0].passthrough)
    }

    @Test func passthroughWithActionShell() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "tap-and-relay"
            input = "ctrl + fn - right"
            action-shell = "facet --view=tree"
            passthrough = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        #expect(b.passthrough)
        if case .shell(let s) = b.action {
            #expect(s == "facet --view=tree")
        } else {
            Issue.record("expected .shell")
        }
    }

    @Test func passthroughWithSetVariableIsAllowed() throws {
        // setVariable + passthrough lets the OS see the keystroke
        // AND the binding write state. Niche but well-defined.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "passive mode-arm"
            input = "cmd - x"
            action-set-var = "mode"
            passthrough = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 1)
        #expect(res.config.bindings[0].passthrough)
        if case .setVariable = res.config.bindings[0].action {
        } else {
            Issue.record("expected .setVariable")
        }
    }

    // MARK: - Validation: forbidden combinations

    @Test func passthroughWithActionKeysRejected() throws {
        // action-keys + passthrough would emit the keystroke twice.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "conflict"
            input = "cmd - x"
            action-keys = "cmd - y"
            passthrough = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .actionKeysParseError && $0.message.contains("passthrough")
            })
    }

    @Test func passthroughWithShellPlusKeysRejected() throws {
        // Multi-action (shell + extra keys) + passthrough is the
        // explicit duplicate of the v0.4.0 workaround — pick one.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "conflict-multi"
            input = "ctrl + fn - right"
            action-shell = "facet --view=tree"
            action-keys = "ctrl + fn - right"
            passthrough = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .actionKeysParseError && $0.message.contains("passthrough")
            })
    }

    @Test func passthroughWithActionNoopRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "absurd"
            input = "cmd - x"
            action-noop = true
            passthrough = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .missingAction && $0.message.contains("passthrough")
            })
    }

    @Test func passthroughWithOnUpRejected() throws {
        // No paired-up is captured when the event flows through, so
        // action-*-on-up would never fire — make the contradiction
        // explicit at parse time.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "conflict-onup"
            input = "cmd - x"
            action-shell = "echo down"
            action-shell-on-up = "echo up"
            passthrough = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .missingAction && $0.message.contains("on-up")
            })
    }

    // MARK: - Schema round-trip

    @Test func schemaEmitsPassthrough() throws {
        let b = try firstBinding(
            """
            [[bindings]]
            name = "relay"
            input = "ctrl - x"
            action-shell = "echo"
            passthrough = true
            """)
        #expect(b["passthrough"] as? Bool == true)
    }

    @Test func schemaOmitsPassthroughWhenFalse() throws {
        // Nil-Optional fields are omitted by JSONEncoder — keeps the
        // common case (passthrough = false) lean.
        let b = try firstBinding(
            """
            [[bindings]]
            name = "plain"
            input = "cmd - x"
            action-shell = "echo"
            """)
        #expect(
            b["passthrough"] == nil,
            "passthrough is omitted from JSON when false")
    }
}
