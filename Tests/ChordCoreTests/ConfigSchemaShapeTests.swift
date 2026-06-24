import Foundation
import Testing
@testable import ChordCore

/// Structural assertions on the emitted config.toml INPUT schema — guards
/// against silent gaps (a missing action key) and enum drift from the parser,
/// beyond the byte-level drift guard.
@Suite struct ConfigSchemaShapeTests {
    private func emitted() throws -> [String: Any] {
        let data = Data(ChordConfigSchema.jsonSchema.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bindingItem(_ root: [String: Any]) throws -> [String: Any] {
        let props = try #require(root["properties"] as? [String: Any])
        let bindings = try #require(props["bindings"] as? [String: Any])
        return try #require(bindings["items"] as? [String: Any])
    }

    @Test func topLevelIsStrictWithAllSections() throws {
        let root = try emitted()
        #expect(root["$schema"] as? String == "http://json-schema.org/draft-07/schema#")
        #expect(root["additionalProperties"] as? Bool == false)
        let props = try #require(root["properties"] as? [String: Any])
        #expect(Set(props.keys) ==
                       ["options", "action-aliases", "input-aliases",
                        "v-key-aliases", "bindings", "fallbacks",
                        "sequence", "remap"])
    }

    /// Every action-* union member the parser reads must appear in the binding
    /// schema — a missing one is a completion gap.
    @Test func bindingHasEveryActionKey() throws {
        let item = try bindingItem(try emitted())
        let props = try #require(item["properties"] as? [String: Any])
        #expect(item["additionalProperties"] as? Bool == false)
        for key in ChordConfigSchema.actionUnionFields().map(\.key) {
            #expect(props[key] != nil, "binding schema missing action key \(key)")
        }
        // on-up mirror + gate + lifecycle + scope present too.
        for key in ["action-shell-on-up", "when-var", "when-vars",
                    "hold-while", "hold-while-timeout", "apps", "repeat", "per-app"] {
            #expect(props[key] != nil, "binding schema missing \(key)")
        }
    }

    /// The `repeat` enum is sourced from RepeatStrategy — assert no drift.
    @Test func repeatEnumMatchesModel() throws {
        let item = try bindingItem(try emitted())
        let props = try #require(item["properties"] as? [String: Any])
        let repeatField = try #require(props["repeat"] as? [String: Any])
        #expect(repeatField["enum"] as? [String] ==
                       RepeatStrategy.allCases.map(\.rawValue))
    }

    /// action-* is required via an `anyOf` clause (≥1), NOT a `oneOf` — so the
    /// legal action-shell + action-keys pair is never rejected.
    @Test func actionUnionUsesAnyOfNotOneOf() throws {
        let item = try bindingItem(try emitted())
        let allOf = try #require(item["allOf"] as? [[String: Any]])
        let actionKeys = Set(ChordConfigSchema.actionUnionFields().map(\.key))
        let anyOfClause = allOf.first { clause in
            guard let anyOf = clause["anyOf"] as? [[String: Any]] else { return false }
            let req = anyOf.compactMap { ($0["required"] as? [String])?.first }
            return Set(req) == actionKeys
        }
        #expect(anyOfClause != nil, "action union should be an anyOf(≥1), not oneOf")
    }

    /// descriptor key sets are non-empty and unique per binding-like context.
    @Test func bindingKeySetsAreSane() {
        #expect(ChordConfigSchema.bindingShape().keySet.contains("input"))
        #expect(ChordConfigSchema.fallbackShape().keySet.contains("inputs"))
        #expect(ChordConfigSchema.sequenceShape().keySet.contains("prefix"))
        #expect(ChordConfigSchema.remapShape().keySet.contains("map"))
        #expect(!ChordConfigSchema.perAppShape().keySet.contains("per-app"))
    }

    /// #52-bounded: `rejected` fields (action-toggle-var-on-up /
    /// action-hold-var-on-up) live in the keySet (so the parser's
    /// unknown-key check recognises them and doesn't mis-report a typo),
    /// but are OMITTED from the emitted schema (so additionalProperties:false
    /// keeps rejecting them — and the committed schema stays byte-identical).
    @Test func rejectedKeysAreInKeySetButNotInSchema() throws {
        let keySet = ChordConfigSchema.bindingShape().keySet
        #expect(keySet.contains("action-toggle-var-on-up"))
        #expect(keySet.contains("action-hold-var-on-up"))
        let props = try #require(
            try bindingItem(try emitted())["properties"] as? [String: Any])
        #expect(props["action-toggle-var-on-up"] == nil, "rejected key must not be schema-valid")
        #expect(props["action-hold-var-on-up"] == nil, "rejected key must not be schema-valid")
    }
}
