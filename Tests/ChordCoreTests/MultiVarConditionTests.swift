import XCTest
@testable import ChordCore

/// chord 0.9.0+: `when-vars = { a = 1, b = 2 }` inline-table form
/// gates a binding on the AND of N variable-equality predicates.
/// Single-entry tables collapse to the existing `.variable`
/// Condition shape; multi-entry tables emit `.conjunction([...])`.
final class MultiVarConditionTests: XCTestCase {

    // MARK: - Parse

    func testWhenVarsTwoEntriesProducesConjunction() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "multi-gated"
        input = "cmd - x"
        when-vars = { jlayer = 1, sub = 2 }
        action-noop = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .conjunction(let parts) = b.condition {
            XCTAssertEqual(parts.count, 2)
            // Sorted by key: jlayer first, sub second.
            XCTAssertEqual(parts[0], .variable(name: "jlayer", equals: 1))
            XCTAssertEqual(parts[1], .variable(name: "sub", equals: 2))
        } else { XCTFail("expected .conjunction") }
    }

    func testWhenVarsSingleEntryCollapsesToVariable() throws {
        // 1-element table is semantically identical to the v2
        // `when-var` shape — collapse so consumers see one form.
        let res = try Config.parse("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        when-vars = { jlayer = 1 }
        action-noop = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings[0].condition,
                       .variable(name: "jlayer", equals: 1))
    }

    func testWhenVarStillWorks() throws {
        // Regression: classic when-var / when-var-value path unchanged.
        let res = try Config.parse("""
        [[bindings]]
        name = "v2-style"
        input = "cmd - x"
        when-var = "jlayer"
        when-var-value = 2
        action-noop = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings[0].condition,
                       .variable(name: "jlayer", equals: 2))
    }

    // MARK: - Validation

    func testWhenVarAndWhenVarsMutuallyExclusive() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "both"
        input = "cmd - x"
        when-var = "a"
        when-vars = { b = 1 }
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .conditionParseError &&
            $0.message.contains("mutually exclusive")
        })
    }

    func testEmptyWhenVarsRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "empty"
        input = "cmd - x"
        when-vars = {}
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .conditionParseError &&
            $0.message.contains("at least one")
        })
    }

    func testNonIntegerValueRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-value"
        input = "cmd - x"
        when-vars = { a = "string" }
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .conditionParseError &&
            $0.message.contains("integer")
        })
    }

    func testNonTableValueRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad-shape"
        input = "cmd - x"
        when-vars = "not a table"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .conditionParseError &&
            $0.message.contains("inline table")
        })
    }

    // MARK: - Matcher semantics

    func testConjunctionFiresOnlyWhenAllPartsHold() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "multi-gate"
        input = "cmd - x"
        when-vars = { a = 1, b = 2 }
        action-noop = true
        """)
        let m = Matcher(bindings: res.config.bindings)

        // Neither var set → no fire.
        let none = m.find(.init(trigger: .key(0x07),     // 'x'
                                modifiers: [.lcmd],
                                bundleID: nil,
                                state: StateSnapshot()))
        XCTAssertNil(none)

        // Only a → no fire.
        let onlyA = m.find(.init(trigger: .key(0x07),
                                 modifiers: [.lcmd],
                                 bundleID: nil,
                                 state: StateSnapshot(variables: ["a": 1])))
        XCTAssertNil(onlyA)

        // Both set with correct values → fire.
        let both = m.find(.init(trigger: .key(0x07),
                                modifiers: [.lcmd],
                                bundleID: nil,
                                state: StateSnapshot(variables: ["a": 1, "b": 2])))
        XCTAssertEqual(both?.name, "multi-gate")

        // b set to wrong value → no fire.
        let wrong = m.find(.init(trigger: .key(0x07),
                                 modifiers: [.lcmd],
                                 bundleID: nil,
                                 state: StateSnapshot(variables: ["a": 1, "b": 3])))
        XCTAssertNil(wrong)
    }

    // MARK: - Schema

    func testSchemaEmitsConjunctionAsAllKind() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "multi"
        input = "cmd - x"
        when-vars = { a = 1, b = 2 }
        action-noop = true
        """)
        let cond = try XCTUnwrap(b["condition"] as? [String: Any])
        XCTAssertEqual(cond["kind"] as? String, "all")
        let nested = try XCTUnwrap(cond["conditions"] as? [[String: Any]])
        XCTAssertEqual(nested.count, 2)
        XCTAssertEqual(nested[0]["kind"] as? String, "variable")
        XCTAssertEqual(nested[0]["variable"] as? String, "a")
        XCTAssertEqual(nested[0]["equals"] as? Int, 1)
        XCTAssertEqual(nested[1]["variable"] as? String, "b")
        XCTAssertEqual(nested[1]["equals"] as? Int, 2)
    }

    func testSchemaSingleEntryEmitsAsVariable() throws {
        // 1-entry table collapses, so JSON still uses kind="variable".
        let b = try firstBinding("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        when-vars = { a = 1 }
        action-noop = true
        """)
        let cond = try XCTUnwrap(b["condition"] as? [String: Any])
        XCTAssertEqual(cond["kind"] as? String, "variable")
        XCTAssertEqual(cond["variable"] as? String, "a")
    }
}
