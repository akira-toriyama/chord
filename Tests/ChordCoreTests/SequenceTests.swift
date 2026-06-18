import XCTest
@testable import ChordCore

/// `[[sequence]]` is **syntactic sugar over v2 state-var**.
/// The Matcher / Controller see only the expanded bindings; runtime
/// behaviour is covered by the existing v2 state-var tests
/// ([StateTests](StateTests.swift)). These tests pin the
/// **expansion contract**: shape, ordering, validation, error paths.
final class SequenceTests: XCTestCase {

    // MARK: - TOML nested array-of-tables

    func testNestedArrayOfTablesPreservesParentRows() throws {
        // Bug regression: the previous TOML.swift assumed `[[a.b]]`
        // navigated through a `.table` parent and lost data when the
        // parent was already an `.arrayOfTables` (`[[a]]`).
        let v = try TOML.parse("""
        [[sequence]]
        name = "outer"

          [[sequence.bindings]]
          input = "k"

          [[sequence.bindings]]
          input = "l"
        """)
        let rows = v["sequence"]?.asArrayOfTables ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"]?.asString, "outer")
        let children = rows[0]["bindings"]?.asArrayOfTables ?? []
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0]["input"]?.asString, "k")
        XCTAssertEqual(children[1]["input"]?.asString, "l")
    }

    func testMultipleSequencesEachKeepTheirChildren() throws {
        let v = try TOML.parse("""
        [[sequence]]
        name = "first"
          [[sequence.bindings]]
          input = "a"

        [[sequence]]
        name = "second"
          [[sequence.bindings]]
          input = "b"
          [[sequence.bindings]]
          input = "c"
        """)
        let rows = v["sequence"]?.asArrayOfTables ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["bindings"]?.asArrayOfTables?.count, 1)
        XCTAssertEqual(rows[1]["bindings"]?.asArrayOfTables?.count, 2)
    }

    // MARK: - Basic expansion

    func testSequenceExpandsToPrefixPlusChildren() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "j-layer"
        prefix = "cmd + opt - j"
        timeout-ms = 1500

          [[sequence.bindings]]
          input = "k"
          action-keys = "return"

          [[sequence.bindings]]
          input = "l"
          action-keys = "backspace"
        """)
        XCTAssertEqual(res.config.bindings.count, 3,
                       "1 sequence with 2 children → 3 expanded bindings")
        XCTAssertEqual(res.droppedBindings, 0)

        // Prefix binding (position 0).
        let prefix = res.config.bindings[0]
        XCTAssertEqual(prefix.name, "j-layer [enter]")
        if case .setVariable(let n, let v) = prefix.action {
            XCTAssertEqual(n, "_seq_j-layer")
            XCTAssertEqual(v, 1)
        } else {
            XCTFail("expected setVariable, got \(prefix.action)")
        }
        XCTAssertEqual(prefix.holdWhileTimeoutMs, 1500)
        XCTAssertNil(prefix.holdWhile,
                     "sequence prefix uses timeout, not modifier-bound hold")
        XCTAssertNil(prefix.condition,
                     "prefix is unconditional — entering the sequence")

        // First child (position 1).
        let c1 = res.config.bindings[1]
        XCTAssertEqual(c1.name, "j-layer.1")
        XCTAssertEqual(c1.condition,
                       .variable(name: "_seq_j-layer", equals: 1))
        if case .keys(_, let kc) = c1.action {
            XCTAssertEqual(kc, 0x24, "return = 0x24")
        } else {
            XCTFail("expected keys action, got \(c1.action)")
        }
        XCTAssertEqual(c1.modifiers, [.cmd, .opt],
                       "child inherits prefix modset")

        // Second child (position 2).
        let c2 = res.config.bindings[2]
        XCTAssertEqual(c2.name, "j-layer.2")
        XCTAssertEqual(c2.condition,
                       .variable(name: "_seq_j-layer", equals: 1))
    }

    func testChildInputUsesPrefixModsetVerbatim() throws {
        // Modset string is preserved as-written (no canonicalisation),
        // so the alias form stays the alias form for downstream
        // schema / config --show output.
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[sequence]]
        name = "j"
        prefix = "$ULTRA_LL - j"
        timeout-ms = 1500

          [[sequence.bindings]]
          input = "k"
          action-keys = "return"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 2)
        // Child input should round-trip through the synthesized
        // "$ULTRA_LL - k" string.
        XCTAssertEqual(res.config.bindings[1].inputRaw, "$ULTRA_LL - k")
        XCTAssertEqual(res.config.bindings[1].modifiers, [.rctrl, .ropt, .rshift])
    }

    func testChildInheritsActionShellAndApps() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "x"
        prefix = "cmd + opt - x"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "y"
          action-shell = "echo hi"
          apps = ["com.apple.Safari"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let child = res.config.bindings[1]
        if case .shell(let body) = child.action {
            XCTAssertEqual(body, "echo hi")
        } else {
            XCTFail("expected shell action, got \(child.action)")
        }
        XCTAssertEqual(child.apps, ["com.apple.Safari"])
    }

    // MARK: - Ordering vs regular [[bindings]]

    func testSequencesAppearBeforeRegularBindings() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "regular-1"
        input = "f13"
        action-noop = true

        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "k"
          action-noop = true

        [[bindings]]
        name = "regular-2"
        input = "f14"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 4,
                       "2 regular + 2 sequence-expanded")
        // Sequence-expanded come first (so prefix wins on collision).
        XCTAssertEqual(res.config.bindings[0].name, "leader [enter]")
        XCTAssertEqual(res.config.bindings[1].name, "leader.1")
        XCTAssertEqual(res.config.bindings[2].name, "regular-1")
        XCTAssertEqual(res.config.bindings[3].name, "regular-2")
    }

    // MARK: - Prefix collision detection

    func testPrefixCollisionDropsRegularBinding() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "k"
          action-noop = true

        [[bindings]]
        name = "regular-j"
        input = "cmd + opt - j"
        action-keys = "j"
        """)
        XCTAssertEqual(res.droppedBindings, 1,
                       "regular binding dropped due to prefix collision")
        XCTAssertEqual(res.config.bindings.count, 2,
                       "only the 2 expanded sequence bindings remain")
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError },
                      "collision should emit sequenceParseError")
    }

    func testRegularBindingWithDifferentModsDoesNotCollide() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "k"
          action-noop = true

        [[bindings]]
        name = "regular-j"
        input = "cmd - j"
        action-noop = true
        """)
        XCTAssertEqual(res.droppedBindings, 0,
                       "cmd-j and cmd+opt-j are distinct")
        XCTAssertEqual(res.config.bindings.count, 3)
    }

    // MARK: - Validation: missing / malformed fields

    func testMissingPrefixDropsSequence() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "broken"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "k"
          action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    func testMissingTimeoutMsDropsSequence() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "broken"
        prefix = "cmd - j"

          [[sequence.bindings]]
          input = "k"
          action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    func testZeroTimeoutMsDropsSequence() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "broken"
        prefix = "cmd - j"
        timeout-ms = 0

          [[sequence.bindings]]
          input = "k"
          action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    func testPrefixWithoutModifierDropsSequence() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "broken"
        prefix = "f13"
        timeout-ms = 500

          [[sequence.bindings]]
          input = "k"
          action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    func testEmptyChildrenDropsSequence() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "broken"
        prefix = "cmd - j"
        timeout-ms = 500
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    func testChildMissingInputIsDroppedButSiblingsSurvive() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "j-layer"
        prefix = "cmd + opt - j"
        timeout-ms = 500

          [[sequence.bindings]]
          action-keys = "return"

          [[sequence.bindings]]
          input = "l"
          action-keys = "backspace"
        """)
        // 1 prefix + 1 valid child = 2 bindings, 1 dropped.
        XCTAssertEqual(res.config.bindings.count, 2)
        XCTAssertEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains { $0.kind == .missingInput })
    }

    // MARK: - Validation: name / nesting

    func testDuplicateSequenceNameDropsSecond() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "k"
          action-noop = true

        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - x"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "y"
          action-noop = true
        """)
        // First sequence → 2 bindings. Second sequence dropped entirely.
        XCTAssertEqual(res.config.bindings.count, 2)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .sequenceParseError &&
            $0.message.contains("duplicate")
        })
    }

    func testNestedSequenceIsRejected() throws {
        // Nested [[sequence.sequence]] would parse with the new
        // nested-AoT TOML support but is explicitly out of scope.
        let res = try Config.parse("""
        [[sequence]]
        name = "outer"
        prefix = "cmd + opt - j"
        timeout-ms = 500

          [[sequence.sequence]]
          name = "inner"
          prefix = "cmd - x"
          timeout-ms = 200
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .sequenceParseError &&
            $0.message.contains("nested")
        })
    }

    func testSequenceNameUnderscorePrefixIsRejected() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "_seq_internal"
        prefix = "cmd + opt - j"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "k"
          action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .sequenceParseError &&
            $0.message.contains("'_seq_'")
        })
    }

    // MARK: - Reserved variable namespace (`_seq_*`)

    func testUserBindingCannotWriteToReservedVarNamespace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "intruder"
        input = "cmd - x"
        action-set-var = "_seq_intruder"
        """)
        XCTAssertEqual(res.config.bindings.count, 0,
                       "user-defined _seq_* var must be rejected")
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionSetParseError &&
            $0.message.contains("_seq_")
        })
    }

    func testUserBindingCanWriteToNonReservedVar() throws {
        // Regression guard: only the `_seq_` prefix is reserved.
        let res = try Config.parse("""
        [[bindings]]
        name = "ok"
        input = "cmd - x"
        action-set-var = "my-var"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
    }

    // MARK: - Matcher behavior (end-to-end through Matcher)

    func testPrefixFiresWithoutAnyVariable() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "j-layer"
        prefix = "cmd + opt - j"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "k"
          action-keys = "return"
        """)
        let m = Matcher(bindings: res.config.bindings)
        // The prefix is a bare unconditional binding; an empty
        // StateSnapshot must satisfy it.
        let prefix = m.find(.init(trigger: .key(0x26),    // 'j'
                                  modifiers: [.lcmd, .lopt],
                                  bundleID: nil,
                                  state: StateSnapshot()))
        XCTAssertNotNil(prefix)
        XCTAssertEqual(prefix?.name, "j-layer [enter]")
    }

    func testChildFiresOnlyWhenSequenceVarIsSet() throws {
        let res = try Config.parse("""
        [[sequence]]
        name = "j-layer"
        prefix = "cmd + opt - j"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "k"
          action-keys = "return"
        """)
        let m = Matcher(bindings: res.config.bindings)
        // Child key 'k' with no state → unset _seq_j-layer → no fire.
        let off = m.find(.init(trigger: .key(0x28),       // 'k'
                               modifiers: [.lcmd, .lopt],
                               bundleID: nil,
                               state: StateSnapshot()))
        XCTAssertNil(off, "child should not fire when var is unset")

        // Same key with _seq_j-layer = 1 → fires.
        let on = m.find(.init(trigger: .key(0x28),
                              modifiers: [.lcmd, .lopt],
                              bundleID: nil,
                              state: StateSnapshot(variables: ["_seq_j-layer": 1])))
        XCTAssertEqual(on?.name, "j-layer.1")
    }

    // MARK: - Schema round-trip (sequence is invisible to consumers)

    func testSchemaShowsOnlyExpandedBindings() throws {
        let json = try parseToBindingsJSON("""
        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 1500
          [[sequence.bindings]]
          input = "k"
          action-keys = "return"
        """)
        let bindings = try XCTUnwrap(json["bindings"] as? [[String: Any]])
        XCTAssertEqual(bindings.count, 2,
                       "JSON shows the 2 expanded bindings, no sequence-specific shape")
        // Prefix is set-variable + hold_while_timeout.
        let prefix = bindings[0]
        let action = try XCTUnwrap(prefix["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "set-variable")
        XCTAssertEqual(action["variable"] as? String, "_seq_leader")
        XCTAssertEqual(prefix["hold_while_timeout"] as? Int, 1500)
        // Child carries a condition referencing the same variable.
        let child = bindings[1]
        let cond = try XCTUnwrap(child["condition"] as? [String: Any])
        XCTAssertEqual(cond["variable"] as? String, "_seq_leader")
    }
}
