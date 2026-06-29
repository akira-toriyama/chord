import Testing
@testable import ChordCore

/// Coverage for the v2 state-machine surface — `Condition`,
/// `StateSnapshot`, `Modifiers.isStillHeld(in:)`, and the v2 TOML
/// fields (`action-set-var` / `when-var` / `hold-while` /
/// `action-*-on-up`). The Controller-side wiring (pending-up table,
/// flagsChanged routing) is exercised in
/// `ChordIntegrationTests` against the synthetic event source.
@Suite struct StateTests {

    // MARK: - Matcher condition gate

    @Test func conditionGateBlocksWhenVariableUnset() {
        let bind = Binding(
            name: "wm-k", trigger: .key(0x28),
            modifiers: [.cmd, .opt], apps: nil,
            action: .noop,
            condition: .variable(name: "wm", equals: 1))
        let m = Matcher(bindings: [bind])
        // Variable unset → reads as 0 → predicate fails.
        let hit = m.find(
            .init(
                trigger: .key(0x28),
                modifiers: [.lcmd, .lopt],
                bundleID: nil,
                state: StateSnapshot()))
        #expect(hit == nil, "binding should not fire when wm == 0 (unset)")
    }

    @Test func conditionGateFiresWhenVariableMatches() {
        let bind = Binding(
            name: "wm-k", trigger: .key(0x28),
            modifiers: [.cmd, .opt], apps: nil,
            action: .noop,
            condition: .variable(name: "wm", equals: 1))
        let m = Matcher(bindings: [bind])
        let hit = m.find(
            .init(
                trigger: .key(0x28),
                modifiers: [.lcmd, .lopt],
                bundleID: nil,
                state: StateSnapshot(variables: ["wm": 1])))
        #expect(hit?.name == "wm-k")
    }

    @Test func conditionGateRespectsExactValue() {
        let bind = Binding(
            name: "layer-3", trigger: .key(0x00),
            modifiers: [], apps: nil, action: .noop,
            condition: .variable(name: "layer", equals: 3))
        let m = Matcher(bindings: [bind])
        let two = m.find(
            .init(
                trigger: .key(0x00), modifiers: [],
                bundleID: nil,
                state: StateSnapshot(variables: ["layer": 2])))
        let three = m.find(
            .init(
                trigger: .key(0x00), modifiers: [],
                bundleID: nil,
                state: StateSnapshot(variables: ["layer": 3])))
        #expect(two == nil)
        #expect(three?.name == "layer-3")
    }

    // MARK: - StateSnapshot

    @Test func stateSnapshotUnsetReadsAsZero() {
        let s = StateSnapshot()
        #expect(s.value("missing") == 0)
    }

    @Test func stateSnapshotReturnsStoredValue() {
        let s = StateSnapshot(variables: ["wm": 1, "layer": 3])
        #expect(s.value("wm") == 1)
        #expect(s.value("layer") == 3)
        #expect(s.value("nope") == 0)
    }

    // MARK: - Modifiers.isStillHeld (hold-while subset check)

    @Test func holdWhileSatisfiedByLeftSideOnly() {
        let hold: Modifiers = [.cmd, .opt]  // any-side
        let current: Modifiers = [.lcmd, .lopt]
        #expect(hold.isStillHeld(in: current))
    }

    @Test func holdWhileFailsWhenAModifierReleased() {
        let hold: Modifiers = [.cmd, .opt]
        let current: Modifiers = [.lcmd]  // opt was released
        #expect(!hold.isStillHeld(in: current))
    }

    @Test func holdWhilePermissiveOfExtras() {
        // Adding shift on top of held cmd+opt must NOT clear the
        // variable — matches() would say false because shift category
        // disagrees; isStillHeld is the looser check.
        let hold: Modifiers = [.cmd, .opt]
        let current: Modifiers = [.lcmd, .lopt, .lshift]
        #expect(hold.isStillHeld(in: current))
    }

    @Test func holdWhileStrictSide() {
        let hold: Modifiers = [.lcmd]
        #expect(hold.isStillHeld(in: [.lcmd]))
        // Right-side cmd does not satisfy strict-left holdWhile.
        #expect(!hold.isStillHeld(in: [.rcmd]))
    }

    // MARK: - Config: v2 TOML fields

    @Test func parseActionSetVar() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "enter wm"
            input = "cmd + opt - j"
            action-set-var = "wm"
            hold-while = "cmd + opt"
            """)
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        if case .setVariable(let name, let value) = b.action {
            #expect(name == "wm")
            #expect(value == 1, "action-set-value defaults to 1")
        } else {
            Issue.record("expected setVariable action, got \(b.action)")
        }
        #expect(b.holdWhile == [.cmd, .opt])
    }

    @Test func parseActionSetWithExplicitValue() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "leave wm"
            input = "esc"
            action-set-var = "wm"
            action-set-value = 0
            """)
        #expect(res.config.bindings.count == 1)
        if case .setVariable(_, let v) = res.config.bindings[0].action {
            #expect(v == 0)
        } else {
            Issue.record("expected setVariable")
        }
    }

    @Test func parseConditionAndOnUp() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "wm-l"
            input = "cmd + opt - l"
            when-var = "wm"
            action-shell = "yabai -m window --grid 1:1:0:0:1:1"
            action-shell-on-up = "yabai -m window --minimize"
            """)
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        #expect(b.condition == .variable(name: "wm", equals: 1))
        guard case .shell(let body) = b.onUpAction ?? .noop else {
            Issue.record("expected shell onUpAction, got \(String(describing: b.onUpAction))")
            return
        }
        #expect(body == "yabai -m window --minimize")
    }

    @Test func orphanWhenVarValueDropsBinding() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "orphan"
            input = "f13"
            when-var-value = 1
            action-noop = true
            """)
        #expect(
            res.config.bindings.count == 0,
            "orphan when-var-value must drop the binding")
        #expect(res.droppedBindings == 1)
        #expect(res.warnings.contains { $0.kind == .conditionParseError })
    }

    @Test func holdWhileEmptyDropsBinding() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad-hold"
            input = "cmd - j"
            action-set-var = "x"
            hold-while = ""
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    // MARK: - hold-while-timeout (chord 0.4.0)

    @Test func parseHoldWhileTimeout() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "j-layer (timeout)"
            input = "rctrl + ralt + rshift - j"
            action-set-var = "jlayer"
            hold-while-timeout = 800
            """)
        #expect(res.config.bindings.count == 1)
        #expect(res.config.bindings[0].holdWhileTimeoutMs == 800)
        #expect(
            res.config.bindings[0].holdWhile == nil,
            "timeout-only binding should not carry holdWhile")
    }

    @Test func holdWhileTimeoutZeroDropsBinding() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad-timeout"
            input = "f13"
            action-set-var = "x"
            hold-while-timeout = 0
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    @Test func holdWhileTimeoutNegativeDropsBinding() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad-timeout"
            input = "f13"
            action-set-var = "x"
            hold-while-timeout = -100
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    @Test func holdWhileAndTimeoutMutuallyExclusive() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "both-lifecycles"
            input = "cmd - j"
            action-set-var = "x"
            hold-while = "cmd"
            hold-while-timeout = 500
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains { $0.kind == .holdWhileParseError },
            "both lifecycles should produce a holdWhileParseError")
    }

    @Test func schemaEmitsHoldWhileTimeout() throws {
        let b = try firstBinding(
            """
            [[bindings]]
            name = "j-layer"
            input = "rctrl + ralt + rshift - j"
            action-set-var = "jlayer"
            hold-while-timeout = 800
            """)
        #expect(b["hold_while_timeout"] as? Int == 800)
        #expect(
            b["hold_while"] == nil,
            "timeout-only binding omits hold_while in JSON")
    }

    // MARK: - Schema v2 emission

    @Test func schemaEmitsSetVariableAction() throws {
        let json = try parseToBindingsJSON(
            """
            [[bindings]]
            name = "enter"
            input = "cmd + opt - j"
            action-set-var = "wm"
            hold-while = "cmd + opt"
            """)
        #expect(json["schema"] as? String == "chord.bindings.v3")
        let bs = try #require(json["bindings"] as? [[String: Any]])
        let b = bs[0]
        let action = try #require(b["action"] as? [String: Any])
        #expect(action["kind"] as? String == "set-variable")
        #expect(action["variable"] as? String == "wm")
        #expect(action["value"] as? Int == 1)
        let hold = try #require(b["hold_while"] as? [String])
        #expect(hold.sorted() == ["cmd", "opt"])
    }

    @Test func schemaEmitsConditionAndOnUp() throws {
        let b = try firstBinding(
            """
            [[bindings]]
            name = "wm-l"
            input = "cmd + opt - l"
            when-var = "wm"
            action-shell = "max"
            action-shell-on-up = "min"
            """)
        let cond = try #require(b["condition"] as? [String: Any])
        #expect(cond["kind"] as? String == "variable")
        #expect(cond["variable"] as? String == "wm")
        #expect(cond["equals"] as? Int == 1)
        let onUp = try #require(b["action_on_up"] as? [String: Any])
        #expect(onUp["kind"] as? String == "shell")
        #expect(onUp["command"] as? String == "min")
    }
}
