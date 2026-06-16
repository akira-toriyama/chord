import XCTest
@testable import ChordCore

/// Structural assertions on the emitted config.toml INPUT schema — guards
/// against silent gaps (a missing action key) and enum drift from the parser,
/// beyond the byte-level drift guard.
final class ConfigSchemaShapeTests: XCTestCase {
    private func emitted() throws -> [String: Any] {
        let data = Data(ChordConfigSchema.jsonSchema.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bindingItem(_ root: [String: Any]) throws -> [String: Any] {
        let props = try XCTUnwrap(root["properties"] as? [String: Any])
        let bindings = try XCTUnwrap(props["bindings"] as? [String: Any])
        return try XCTUnwrap(bindings["items"] as? [String: Any])
    }

    func testTopLevelIsStrictWithAllSections() throws {
        let root = try emitted()
        XCTAssertEqual(root["$schema"] as? String, "http://json-schema.org/draft-07/schema#")
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        let props = try XCTUnwrap(root["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys),
                       ["options", "action-aliases", "input-aliases",
                        "bindings", "fallbacks", "sequence", "remap"])
    }

    /// Every action-* union member the parser reads must appear in the binding
    /// schema — a missing one is a completion gap.
    func testBindingHasEveryActionKey() throws {
        let item = try bindingItem(try emitted())
        let props = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        for key in ChordConfigSchema.actionUnionFields().map(\.key) {
            XCTAssertNotNil(props[key], "binding schema missing action key \(key)")
        }
        // on-up mirror + gate + lifecycle + scope present too.
        for key in ["action-shell-on-up", "when-var", "when-vars",
                    "hold-while", "hold-while-timeout", "apps", "repeat", "per-app"] {
            XCTAssertNotNil(props[key], "binding schema missing \(key)")
        }
    }

    /// The `repeat` enum is sourced from RepeatStrategy — assert no drift.
    func testRepeatEnumMatchesModel() throws {
        let item = try bindingItem(try emitted())
        let props = try XCTUnwrap(item["properties"] as? [String: Any])
        let repeatField = try XCTUnwrap(props["repeat"] as? [String: Any])
        XCTAssertEqual(repeatField["enum"] as? [String],
                       RepeatStrategy.allCases.map(\.rawValue))
    }

    /// action-* is required via an `anyOf` clause (≥1), NOT a `oneOf` — so the
    /// legal action-shell + action-keys pair is never rejected.
    func testActionUnionUsesAnyOfNotOneOf() throws {
        let item = try bindingItem(try emitted())
        let allOf = try XCTUnwrap(item["allOf"] as? [[String: Any]])
        let actionKeys = Set(ChordConfigSchema.actionUnionFields().map(\.key))
        let anyOfClause = allOf.first { clause in
            guard let anyOf = clause["anyOf"] as? [[String: Any]] else { return false }
            let req = anyOf.compactMap { ($0["required"] as? [String])?.first }
            return Set(req) == actionKeys
        }
        XCTAssertNotNil(anyOfClause, "action union should be an anyOf(≥1), not oneOf")
    }

    /// descriptor key sets are non-empty and unique per binding-like context.
    func testBindingKeySetsAreSane() {
        XCTAssertTrue(ChordConfigSchema.bindingShape().keySet.contains("input"))
        XCTAssertTrue(ChordConfigSchema.fallbackShape().keySet.contains("inputs"))
        XCTAssertTrue(ChordConfigSchema.sequenceShape().keySet.contains("prefix"))
        XCTAssertTrue(ChordConfigSchema.remapShape().keySet.contains("map"))
        XCTAssertFalse(ChordConfigSchema.perAppShape().keySet.contains("per-app"))
    }
}
