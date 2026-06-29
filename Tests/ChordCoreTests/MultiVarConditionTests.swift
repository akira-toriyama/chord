import Testing
@testable import ChordCore

/// chord 0.9.0+: `when-vars = { a = 1, b = 2 }` inline-table form
/// gates a binding on the AND of N variable-equality predicates.
/// Single-entry tables collapse to the existing `.variable`
/// Condition shape; multi-entry tables emit `.conjunction([...])`.
@Suite struct MultiVarConditionTests {

    // MARK: - Parse

    @Test func whenVarsTwoEntriesProducesConjunction() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "multi-gated"
            input = "cmd - x"
            when-vars = { jlayer = 1, sub = 2 }
            action-noop = true
            """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .conjunction(let parts) = b.condition {
            #expect(parts.count == 2)
            // Sorted by key: jlayer first, sub second.
            #expect(parts[0] == .variable(name: "jlayer", equals: 1))
            #expect(parts[1] == .variable(name: "sub", equals: 2))
        } else {
            Issue.record("expected .conjunction")
        }
    }

    @Test func whenVarsSingleEntryCollapsesToVariable() throws {
        // 1-element table is semantically identical to the v2
        // `when-var` shape — collapse so consumers see one form.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "single"
            input = "cmd - x"
            when-vars = { jlayer = 1 }
            action-noop = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings[0].condition == .variable(name: "jlayer", equals: 1))
    }

    @Test func whenVarStillWorks() throws {
        // Regression: classic when-var / when-var-value path unchanged.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "v2-style"
            input = "cmd - x"
            when-var = "jlayer"
            when-var-value = 2
            action-noop = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings[0].condition == .variable(name: "jlayer", equals: 2))
    }

    // MARK: - Validation

    @Test func whenVarAndWhenVarsMutuallyExclusive() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "both"
            input = "cmd - x"
            when-var = "a"
            when-vars = { b = 1 }
            action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .conditionParseError && $0.message.contains("mutually exclusive")
            })
    }

    @Test func emptyWhenVarsRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "empty"
            input = "cmd - x"
            when-vars = {}
            action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .conditionParseError && $0.message.contains("at least one")
            })
    }

    @Test func nonIntegerValueRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad-value"
            input = "cmd - x"
            when-vars = { a = "string" }
            action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .conditionParseError && $0.message.contains("integer")
            })
    }

    @Test func nonTableValueRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad-shape"
            input = "cmd - x"
            when-vars = "not a table"
            action-noop = true
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .conditionParseError && $0.message.contains("inline table")
            })
    }

    // MARK: - Matcher semantics

    @Test func conjunctionFiresOnlyWhenAllPartsHold() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "multi-gate"
            input = "cmd - x"
            when-vars = { a = 1, b = 2 }
            action-noop = true
            """)
        let m = Matcher(bindings: res.config.bindings)

        // Neither var set → no fire.
        let none = m.find(
            .init(
                trigger: .key(0x07),  // 'x'
                modifiers: [.lcmd],
                bundleID: nil,
                state: StateSnapshot()))
        #expect(none == nil)

        // Only a → no fire.
        let onlyA = m.find(
            .init(
                trigger: .key(0x07),
                modifiers: [.lcmd],
                bundleID: nil,
                state: StateSnapshot(variables: ["a": 1])))
        #expect(onlyA == nil)

        // Both set with correct values → fire.
        let both = m.find(
            .init(
                trigger: .key(0x07),
                modifiers: [.lcmd],
                bundleID: nil,
                state: StateSnapshot(variables: ["a": 1, "b": 2])))
        #expect(both?.name == "multi-gate")

        // b set to wrong value → no fire.
        let wrong = m.find(
            .init(
                trigger: .key(0x07),
                modifiers: [.lcmd],
                bundleID: nil,
                state: StateSnapshot(variables: ["a": 1, "b": 3])))
        #expect(wrong == nil)
    }

    // MARK: - Schema

    @Test func schemaEmitsConjunctionAsAllKind() throws {
        let b = try firstBinding(
            """
            [[bindings]]
            name = "multi"
            input = "cmd - x"
            when-vars = { a = 1, b = 2 }
            action-noop = true
            """)
        let cond = try #require(b["condition"] as? [String: Any])
        #expect(cond["kind"] as? String == "all")
        let nested = try #require(cond["conditions"] as? [[String: Any]])
        #expect(nested.count == 2)
        #expect(nested[0]["kind"] as? String == "variable")
        #expect(nested[0]["variable"] as? String == "a")
        #expect(nested[0]["equals"] as? Int == 1)
        #expect(nested[1]["variable"] as? String == "b")
        #expect(nested[1]["equals"] as? Int == 2)
    }

    @Test func schemaSingleEntryEmitsAsVariable() throws {
        // 1-entry table collapses, so JSON still uses kind="variable".
        let b = try firstBinding(
            """
            [[bindings]]
            name = "single"
            input = "cmd - x"
            when-vars = { a = 1 }
            action-noop = true
            """)
        let cond = try #require(b["condition"] as? [String: Any])
        #expect(cond["kind"] as? String == "variable")
        #expect(cond["variable"] as? String == "a")
    }
}
