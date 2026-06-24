import Testing
@testable import ChordCore

/// chord 0.9.0+: `action-keys` accepts a string OR an array of
/// strings. The first element becomes the binding's primary action;
/// the rest land on `Binding.extraDownActions` and fire in order on
/// the same key-down (same path the v0.4.0 `action-shell + action-keys`
/// multi-action uses).
@Suite struct ActionKeysArrayTests {

    // MARK: - Single-string form (regression)

    @Test func singleStringActionKeysUnchanged() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        action-keys = "cmd - c"
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .keys(_, let kc) = b.action {
            #expect(kc == 0x08)   // 'c'
        } else { Issue.record("expected .keys primary") }
        #expect(b.extraDownActions.isEmpty)
        #expect(b.actionRaw == "cmd - c")
    }

    // MARK: - Array form

    @Test func arrayFormBuildsPrimaryPlusExtras() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "copy-switch-paste"
        input = "cmd - p"
        action-keys = ["cmd - c", "cmd - tab", "cmd - v"]
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        // Primary = first element ('c').
        if case .keys(_, let kc) = b.action {
            #expect(kc == 0x08)
        } else { Issue.record("expected .keys primary") }
        // Extras = rest of array.
        #expect(b.extraDownActions.count == 2)
        if case .keys(_, let kc) = b.extraDownActions[0] {
            #expect(kc == 0x30)    // 'tab'
        } else { Issue.record("extras[0] should be .keys") }
        if case .keys(_, let kc) = b.extraDownActions[1] {
            #expect(kc == 0x09)    // 'v'
        } else { Issue.record("extras[1] should be .keys") }
    }

    @Test func singleElementArrayBehavesLikeString() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single-array"
        input = "cmd - x"
        action-keys = ["cmd - c"]
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .keys(_, let kc) = b.action {
            #expect(kc == 0x08)
        } else { Issue.record("expected .keys") }
        #expect(b.extraDownActions.isEmpty,
                "1-element array → primary only, no extras")
    }

    // MARK: - Combined with action-shell (v0.4.0 multi-action extended)

    @Test func shellPlusKeysArrayLayersAsExtras() throws {
        // action-shell is primary, every array element is an extra.
        let res = try Config.parse("""
        [[bindings]]
        name = "shell-plus-arr"
        input = "cmd - x"
        action-shell = "echo hi"
        action-keys = ["cmd - c", "cmd - v"]
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .shell = b.action {} else { Issue.record("expected .shell primary") }
        #expect(b.extraDownActions.count == 2)
    }

    @Test func shellPlusKeysStringStillWorks() throws {
        // Regression for v0.4.0 single-string multi-action form.
        let res = try Config.parse("""
        [[bindings]]
        name = "v04-style"
        input = "cmd - x"
        action-shell = "echo hi"
        action-keys = "cmd - c"
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .shell = b.action {} else { Issue.record("expected .shell") }
        #expect(b.extraDownActions.count == 1)
    }

    // MARK: - Validation

    @Test func emptyArrayRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "empty"
        input = "cmd - x"
        action-keys = []
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("at least one")
        })
    }

    @Test func nonStringElementRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-element"
        input = "cmd - x"
        action-keys = ["cmd - c", 42]
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    @Test func unparseableElementRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-token"
        input = "cmd - x"
        action-keys = ["cmd - c", "not-a-key"]
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    @Test func onUpArrayRejected() throws {
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
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("on-up")
        })
    }

    @Test func onUpSingleStringStillWorks() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "onup-single"
        input = "cmd - x"
        action-shell = "echo down"
        action-keys-on-up = "cmd - c"
        """)
        #expect(res.droppedBindings == 0)
        if case .keys = res.config.bindings[0].onUpAction {} else {
            Issue.record("expected .keys onUp")
        }
    }

    // MARK: - Schema round-trip

    @Test func schemaEmitsExtraActionsForKeysArray() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "seq"
        input = "cmd - p"
        action-keys = ["cmd - c", "cmd - v"]
        """)
        // Primary is keys.
        let action = try #require(b["action"] as? [String: Any])
        #expect(action["kind"] as? String == "keys")
        // Extra actions emitted.
        let extras = try #require(b["extra_actions"] as? [[String: Any]])
        #expect(extras.count == 1)
        #expect(extras[0]["kind"] as? String == "keys")
    }
}
