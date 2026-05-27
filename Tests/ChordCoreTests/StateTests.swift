import XCTest
@testable import ChordCore

/// Coverage for the v2 state-machine surface — `Condition`,
/// `StateSnapshot`, `Modifiers.isStillHeld(in:)`, and the v2 TOML
/// fields (`action-set-var` / `when-var` / `hold-while` /
/// `action-*-on-up`). The Controller-side wiring (pending-up table,
/// flagsChanged routing) is exercised in
/// `ChordIntegrationTests` against the synthetic event source.
final class StateTests: XCTestCase {

    // MARK: - Matcher condition gate

    func testConditionGateBlocksWhenVariableUnset() {
        let bind = Binding(name: "wm-k", trigger: .key(0x28),
                           modifiers: [.cmd, .opt], apps: nil,
                           action: .noop,
                           condition: .variable(name: "wm", equals: 1))
        let m = Matcher(bindings: [bind])
        // Variable unset → reads as 0 → predicate fails.
        let hit = m.find(.init(trigger: .key(0x28),
                               modifiers: [.lcmd, .lopt],
                               bundleID: nil,
                               state: StateSnapshot()))
        XCTAssertNil(hit, "binding should not fire when wm == 0 (unset)")
    }

    func testConditionGateFiresWhenVariableMatches() {
        let bind = Binding(name: "wm-k", trigger: .key(0x28),
                           modifiers: [.cmd, .opt], apps: nil,
                           action: .noop,
                           condition: .variable(name: "wm", equals: 1))
        let m = Matcher(bindings: [bind])
        let hit = m.find(.init(trigger: .key(0x28),
                               modifiers: [.lcmd, .lopt],
                               bundleID: nil,
                               state: StateSnapshot(variables: ["wm": 1])))
        XCTAssertEqual(hit?.name, "wm-k")
    }

    func testConditionGateRespectsExactValue() {
        let bind = Binding(name: "layer-3", trigger: .key(0x00),
                           modifiers: [], apps: nil, action: .noop,
                           condition: .variable(name: "layer", equals: 3))
        let m = Matcher(bindings: [bind])
        let two = m.find(.init(trigger: .key(0x00), modifiers: [],
                               bundleID: nil,
                               state: StateSnapshot(variables: ["layer": 2])))
        let three = m.find(.init(trigger: .key(0x00), modifiers: [],
                                 bundleID: nil,
                                 state: StateSnapshot(variables: ["layer": 3])))
        XCTAssertNil(two)
        XCTAssertEqual(three?.name, "layer-3")
    }

    // MARK: - StateSnapshot

    func testStateSnapshotUnsetReadsAsZero() {
        let s = StateSnapshot()
        XCTAssertEqual(s.value("missing"), 0)
    }

    func testStateSnapshotReturnsStoredValue() {
        let s = StateSnapshot(variables: ["wm": 1, "layer": 3])
        XCTAssertEqual(s.value("wm"), 1)
        XCTAssertEqual(s.value("layer"), 3)
        XCTAssertEqual(s.value("nope"), 0)
    }

    // MARK: - Modifiers.isStillHeld (hold-while subset check)

    func testHoldWhileSatisfiedByLeftSideOnly() {
        let hold: Modifiers = [.cmd, .opt]   // any-side
        let current: Modifiers = [.lcmd, .lopt]
        XCTAssertTrue(hold.isStillHeld(in: current))
    }

    func testHoldWhileFailsWhenAModifierReleased() {
        let hold: Modifiers = [.cmd, .opt]
        let current: Modifiers = [.lcmd]    // opt was released
        XCTAssertFalse(hold.isStillHeld(in: current))
    }

    func testHoldWhilePermissiveOfExtras() {
        // Adding shift on top of held cmd+opt must NOT clear the
        // variable — matches() would say false because shift category
        // disagrees; isStillHeld is the looser check.
        let hold: Modifiers = [.cmd, .opt]
        let current: Modifiers = [.lcmd, .lopt, .lshift]
        XCTAssertTrue(hold.isStillHeld(in: current))
    }

    func testHoldWhileStrictSide() {
        let hold: Modifiers = [.lcmd]
        XCTAssertTrue(hold.isStillHeld(in: [.lcmd]))
        // Right-side cmd does not satisfy strict-left holdWhile.
        XCTAssertFalse(hold.isStillHeld(in: [.rcmd]))
    }

    // MARK: - Config: v2 TOML fields

    func testParseActionSetVar() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "enter wm"
        input = "cmd + opt - j"
        action-set-var = "wm"
        hold-while = "cmd + opt"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        if case .setVariable(let name, let value) = b.action {
            XCTAssertEqual(name, "wm")
            XCTAssertEqual(value, 1, "action-set-value defaults to 1")
        } else {
            XCTFail("expected setVariable action, got \(b.action)")
        }
        XCTAssertEqual(b.holdWhile, [.cmd, .opt])
    }

    func testParseActionSetWithExplicitValue() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "leave wm"
        input = "esc"
        action-set-var = "wm"
        action-set-value = 0
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        if case .setVariable(_, let v) = res.config.bindings[0].action {
            XCTAssertEqual(v, 0)
        } else {
            XCTFail("expected setVariable")
        }
    }

    func testParseConditionAndOnUp() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "wm-l"
        input = "cmd + opt - l"
        when-var = "wm"
        action-shell = "yabai -m window --grid 1:1:0:0:1:1"
        action-shell-on-up = "yabai -m window --minimize"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertEqual(b.condition,
                       .variable(name: "wm", equals: 1))
        guard case .shell(let body) = b.onUpAction ?? .noop else {
            return XCTFail("expected shell onUpAction, got \(String(describing: b.onUpAction))")
        }
        XCTAssertEqual(body, "yabai -m window --minimize")
    }

    func testOrphanWhenVarValueDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "orphan"
        input = "f13"
        when-var-value = 1
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0,
                       "orphan when-var-value must drop the binding")
        XCTAssertEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains { $0.kind == .conditionParseError })
    }

    func testHoldWhileEmptyDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-hold"
        input = "cmd - j"
        action-set-var = "x"
        hold-while = ""
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    // MARK: - v2.1 hold-while-timeout

    func testParseHoldWhileTimeout() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "j-layer (timeout)"
        input = "rctrl + ralt + rshift - j"
        action-set-var = "jlayer"
        hold-while-timeout = 800
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.config.bindings[0].holdWhileTimeoutMs, 800)
        XCTAssertNil(res.config.bindings[0].holdWhile,
                     "timeout-only binding should not carry holdWhile")
    }

    func testHoldWhileTimeoutZeroDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-timeout"
        input = "f13"
        action-set-var = "x"
        hold-while-timeout = 0
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    func testHoldWhileTimeoutNegativeDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-timeout"
        input = "f13"
        action-set-var = "x"
        hold-while-timeout = -100
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .holdWhileParseError })
    }

    func testHoldWhileAndTimeoutMutuallyExclusive() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "both-lifecycles"
        input = "cmd - j"
        action-set-var = "x"
        hold-while = "cmd"
        hold-while-timeout = 500
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .holdWhileParseError },
                      "both lifecycles should produce a holdWhileParseError")
    }

    func testSchemaEmitsHoldWhileTimeout() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "j-layer"
        input = "rctrl + ralt + rshift - j"
        action-set-var = "jlayer"
        hold-while-timeout = 800
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        XCTAssertEqual(b["hold_while_timeout"] as? Int, 800)
        XCTAssertNil(b["hold_while"],
                     "timeout-only binding omits hold_while in JSON")
    }

    // MARK: - Schema v2 emission

    func testSchemaEmitsSetVariableAction() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "enter"
        input = "cmd + opt - j"
        action-set-var = "wm"
        hold-while = "cmd + opt"
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schema"] as? String, "chord.bindings.v2")
        let b = (json["bindings"] as! [[String: Any]])[0]
        let action = b["action"] as! [String: Any]
        XCTAssertEqual(action["kind"] as? String, "set-variable")
        XCTAssertEqual(action["variable"] as? String, "wm")
        XCTAssertEqual(action["value"] as? Int, 1)
        let hold = b["hold_while"] as! [String]
        XCTAssertEqual(hold.sorted(), ["cmd", "opt"])
    }

    func testSchemaEmitsConditionAndOnUp() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "wm-l"
        input = "cmd + opt - l"
        when-var = "wm"
        action-shell = "max"
        action-shell-on-up = "min"
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        let cond = b["condition"] as! [String: Any]
        XCTAssertEqual(cond["kind"] as? String, "variable")
        XCTAssertEqual(cond["variable"] as? String, "wm")
        XCTAssertEqual(cond["equals"] as? Int, 1)
        let onUp = b["action_on_up"] as! [String: Any]
        XCTAssertEqual(onUp["kind"] as? String, "shell")
        XCTAssertEqual(onUp["command"] as? String, "min")
    }
}
