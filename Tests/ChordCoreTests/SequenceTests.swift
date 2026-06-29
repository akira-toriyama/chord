import Testing
@testable import ChordCore

/// `[[sequence]]` is **syntactic sugar over v2 state-var**.
/// The Matcher / Controller see only the expanded bindings; runtime
/// behaviour is covered by the existing v2 state-var tests
/// ([StateTests](StateTests.swift)). These tests pin the
/// **expansion contract**: shape, ordering, validation, error paths.
@Suite struct SequenceTests {

    // MARK: - TOML nested array-of-tables

    @Test func nestedArrayOfTablesPreservesParentRows() throws {
        // Bug regression: the previous TOML.swift assumed `[[a.b]]`
        // navigated through a `.table` parent and lost data when the
        // parent was already an `.arrayOfTables` (`[[a]]`).
        let v = try TOML.parse(
            """
            [[sequence]]
            name = "outer"

              [[sequence.bindings]]
              input = "k"

              [[sequence.bindings]]
              input = "l"
            """)
        let rows = v["sequence"]?.asArrayOfTables ?? []
        #expect(rows.count == 1)
        #expect(rows[0]["name"]?.asString == "outer")
        let children = rows[0]["bindings"]?.asArrayOfTables ?? []
        #expect(children.count == 2)
        #expect(children[0]["input"]?.asString == "k")
        #expect(children[1]["input"]?.asString == "l")
    }

    @Test func multipleSequencesEachKeepTheirChildren() throws {
        let v = try TOML.parse(
            """
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
        #expect(rows.count == 2)
        #expect(rows[0]["bindings"]?.asArrayOfTables?.count == 1)
        #expect(rows[1]["bindings"]?.asArrayOfTables?.count == 2)
    }

    // MARK: - Basic expansion

    @Test func sequenceExpandsToPrefixPlusChildren() throws {
        let res = try Config.parse(
            """
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
        #expect(
            res.config.bindings.count == 3,
            "1 sequence with 2 children → 3 expanded bindings")
        #expect(res.droppedBindings == 0)

        // Prefix binding (position 0).
        let prefix = res.config.bindings[0]
        #expect(prefix.name == "j-layer [enter]")
        if case .setVariable(let n, let v) = prefix.action {
            #expect(n == "_seq_j-layer")
            #expect(v == 1)
        } else {
            Issue.record("expected setVariable, got \(prefix.action)")
        }
        #expect(prefix.holdWhileTimeoutMs == 1500)
        #expect(
            prefix.holdWhile == nil,
            "sequence prefix uses timeout, not modifier-bound hold")
        #expect(
            prefix.condition == nil,
            "prefix is unconditional — entering the sequence")

        // First child (position 1).
        let c1 = res.config.bindings[1]
        #expect(c1.name == "j-layer.1")
        #expect(c1.condition == .variable(name: "_seq_j-layer", equals: 1))
        if case .keys(_, let kc) = c1.action {
            #expect(kc == 0x24, "return = 0x24")
        } else {
            Issue.record("expected keys action, got \(c1.action)")
        }
        #expect(
            c1.modifiers == [.cmd, .opt],
            "child inherits prefix modset")

        // Second child (position 2).
        let c2 = res.config.bindings[2]
        #expect(c2.name == "j-layer.2")
        #expect(c2.condition == .variable(name: "_seq_j-layer", equals: 1))
    }

    @Test func childInputUsesPrefixModsetVerbatim() throws {
        // Modset string is preserved as-written (no canonicalisation),
        // so the alias form stays the alias form for downstream
        // schema / config --show output.
        let res = try Config.parse(
            """
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
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 2)
        // Child input should round-trip through the synthesized
        // "$ULTRA_LL - k" string.
        #expect(res.config.bindings[1].inputRaw == "$ULTRA_LL - k")
        #expect(res.config.bindings[1].modifiers == [.rctrl, .ropt, .rshift])
    }

    @Test func childInheritsActionShellAndApps() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "x"
            prefix = "cmd + opt - x"
            timeout-ms = 500

              [[sequence.bindings]]
              input = "y"
              action-shell = "echo hi"
              apps = ["com.apple.Safari"]
            """)
        #expect(res.droppedBindings == 0)
        let child = res.config.bindings[1]
        if case .shell(let body) = child.action {
            #expect(body == "echo hi")
        } else {
            Issue.record("expected shell action, got \(child.action)")
        }
        #expect(child.apps == ["com.apple.Safari"])
    }

    // MARK: - Ordering vs regular [[bindings]]

    @Test func sequencesAppearBeforeRegularBindings() throws {
        let res = try Config.parse(
            """
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
        #expect(
            res.config.bindings.count == 4,
            "2 regular + 2 sequence-expanded")
        // Sequence-expanded come first (so prefix wins on collision).
        #expect(res.config.bindings[0].name == "leader [enter]")
        #expect(res.config.bindings[1].name == "leader.1")
        #expect(res.config.bindings[2].name == "regular-1")
        #expect(res.config.bindings[3].name == "regular-2")
    }

    // MARK: - Prefix collision detection

    @Test func prefixCollisionDropsRegularBinding() throws {
        let res = try Config.parse(
            """
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
        #expect(
            res.droppedBindings == 1,
            "regular binding dropped due to prefix collision")
        #expect(
            res.config.bindings.count == 2,
            "only the 2 expanded sequence bindings remain")
        #expect(
            res.warnings.contains { $0.kind == .sequenceParseError },
            "collision should emit sequenceParseError")
    }

    @Test func regularBindingWithDifferentModsDoesNotCollide() throws {
        let res = try Config.parse(
            """
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
        #expect(
            res.droppedBindings == 0,
            "cmd-j and cmd+opt-j are distinct")
        #expect(res.config.bindings.count == 3)
    }

    // MARK: - Validation: missing / malformed fields

    @Test func missingPrefixDropsSequence() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "broken"
            timeout-ms = 500

              [[sequence.bindings]]
              input = "k"
              action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    @Test func missingTimeoutMsDropsSequence() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "broken"
            prefix = "cmd - j"

              [[sequence.bindings]]
              input = "k"
              action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    @Test func zeroTimeoutMsDropsSequence() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "broken"
            prefix = "cmd - j"
            timeout-ms = 0

              [[sequence.bindings]]
              input = "k"
              action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    @Test func prefixWithoutModifierDropsSequence() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "broken"
            prefix = "f13"
            timeout-ms = 500

              [[sequence.bindings]]
              input = "k"
              action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    @Test func emptyChildrenDropsSequence() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "broken"
            prefix = "cmd - j"
            timeout-ms = 500
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .sequenceParseError })
    }

    @Test func childMissingInputIsDroppedButSiblingsSurvive() throws {
        let res = try Config.parse(
            """
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
        #expect(res.config.bindings.count == 2)
        #expect(res.droppedBindings == 1)
        #expect(res.warnings.contains { $0.kind == .missingInput })
    }

    // MARK: - Validation: name / nesting

    @Test func duplicateSequenceNameDropsSecond() throws {
        let res = try Config.parse(
            """
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
        #expect(res.config.bindings.count == 2)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .sequenceParseError && $0.message.contains("duplicate")
            })
    }

    @Test func nestedSequenceIsRejected() throws {
        // Nested [[sequence.sequence]] would parse with the new
        // nested-AoT TOML support but is explicitly out of scope.
        let res = try Config.parse(
            """
            [[sequence]]
            name = "outer"
            prefix = "cmd + opt - j"
            timeout-ms = 500

              [[sequence.sequence]]
              name = "inner"
              prefix = "cmd - x"
              timeout-ms = 200
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .sequenceParseError && $0.message.contains("nested")
            })
    }

    @Test func sequenceNameUnderscorePrefixIsRejected() throws {
        let res = try Config.parse(
            """
            [[sequence]]
            name = "_seq_internal"
            prefix = "cmd + opt - j"
            timeout-ms = 500
              [[sequence.bindings]]
              input = "k"
              action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .sequenceParseError && $0.message.contains("'_seq_'")
            })
    }

    // MARK: - Reserved variable namespace (`_seq_*`)

    @Test func userBindingCannotWriteToReservedVarNamespace() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "intruder"
            input = "cmd - x"
            action-set-var = "_seq_intruder"
            """)
        #expect(
            res.config.bindings.count == 0,
            "user-defined _seq_* var must be rejected")
        #expect(
            res.warnings.contains {
                $0.kind == .actionSetParseError && $0.message.contains("_seq_")
            })
    }

    @Test func userBindingCanWriteToNonReservedVar() throws {
        // Regression guard: only the `_seq_` prefix is reserved.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "ok"
            input = "cmd - x"
            action-set-var = "my-var"
            """)
        #expect(res.config.bindings.count == 1)
    }

    // MARK: - Matcher behavior (end-to-end through Matcher)

    @Test func prefixFiresWithoutAnyVariable() throws {
        let res = try Config.parse(
            """
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
        let prefix = m.find(
            .init(
                trigger: .key(0x26),  // 'j'
                modifiers: [.lcmd, .lopt],
                bundleID: nil,
                state: StateSnapshot()))
        #expect(prefix != nil)
        #expect(prefix?.name == "j-layer [enter]")
    }

    @Test func childFiresOnlyWhenSequenceVarIsSet() throws {
        let res = try Config.parse(
            """
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
        let off = m.find(
            .init(
                trigger: .key(0x28),  // 'k'
                modifiers: [.lcmd, .lopt],
                bundleID: nil,
                state: StateSnapshot()))
        #expect(off == nil, "child should not fire when var is unset")

        // Same key with _seq_j-layer = 1 → fires.
        let on = m.find(
            .init(
                trigger: .key(0x28),
                modifiers: [.lcmd, .lopt],
                bundleID: nil,
                state: StateSnapshot(variables: ["_seq_j-layer": 1])))
        #expect(on?.name == "j-layer.1")
    }

    // MARK: - Schema round-trip (sequence is invisible to consumers)

    @Test func schemaShowsOnlyExpandedBindings() throws {
        let json = try parseToBindingsJSON(
            """
            [[sequence]]
            name = "leader"
            prefix = "cmd + opt - j"
            timeout-ms = 1500
              [[sequence.bindings]]
              input = "k"
              action-keys = "return"
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        #expect(
            bindings.count == 2,
            "JSON shows the 2 expanded bindings, no sequence-specific shape")
        // Prefix is set-variable + hold_while_timeout.
        let prefix = bindings[0]
        let action = try #require(prefix["action"] as? [String: Any])
        #expect(action["kind"] as? String == "set-variable")
        #expect(action["variable"] as? String == "_seq_leader")
        #expect(prefix["hold_while_timeout"] as? Int == 1500)
        // Child carries a condition referencing the same variable.
        let child = bindings[1]
        let cond = try #require(child["condition"] as? [String: Any])
        #expect(cond["variable"] as? String == "_seq_leader")
    }
}
