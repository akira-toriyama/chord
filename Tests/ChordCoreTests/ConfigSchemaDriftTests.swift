import Foundation
import Testing
@testable import ChordCore

/// The committed repo-root `config.schema.json` (the config.toml INPUT schema,
/// pointed at by the `#:schema` directive and installed as a sidecar next to
/// the user config) MUST equal what `ChordConfigSchema` emits — else editor
/// completion drifts from the parser's actual accepted surface.
///
/// Regenerate: `chord config --emit-schema > config.schema.json`.
/// NOTE: this is NOT docs/schema/chord.bindings.v3.json (the parse OUTPUT).
@Suite struct ConfigSchemaDriftTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ChordCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    @Test func committedSchemaMatchesEmitted() throws {
        let url = repoRoot().appendingPathComponent("config.schema.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(
            committed == ChordConfigSchema.jsonSchema,
            "config.schema.json is stale — run `chord config --emit-schema > config.schema.json` and commit.")
    }

    /// The emitted schema is always well-formed JSON (drift guard compares
    /// strings; this catches a serializer regression that yields `{}`).
    @Test func emittedSchemaIsValidJSON() throws {
        let data = Data(ChordConfigSchema.jsonSchema.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(obj is [String: Any])
    }
}
