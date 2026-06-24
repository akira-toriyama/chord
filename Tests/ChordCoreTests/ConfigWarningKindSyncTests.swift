import Foundation
import Testing
@testable import ChordCore

/// Compiled-enum guard that `ConfigWarning.Kind`'s raw values stay in lockstep
/// with the two on-disk copies that consumers read:
///   - `docs/schema/chord.bindings.v3.json` — `$defs.dropped.properties.kind.enum`
///     (the OUTPUT wire contract; renaming a value is a schema MAJOR bump)
///   - `docs/glossary.md` — the `### ConfigWarning.Kind` table
///
/// `Kind` is `String, CaseIterable`, so `allCases` is the authority here —
/// sturdier than `scripts/check-warning-kind-sync.sh`'s source grep. Both ship
/// (#138-A): the script fails fast pre-build with no toolchain; this test
/// cross-checks via the real enum so a case the grep misses still trips.
///
/// NOT to be confused with `ConfigSchemaDriftTests`, which guards the INPUT
/// `config.schema.json` against `ChordConfigSchema.jsonSchema`.
@Suite struct ConfigWarningKindSyncTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ChordCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private var enumKinds: Set<String> {
        Set(ConfigWarning.Kind.allCases.map(\.rawValue))
    }

    @Test func wireSchemaKindEnumMatchesEnum() throws {
        let url = repoRoot().appendingPathComponent("docs/schema/chord.bindings.v3.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let enumValues = (((obj?["$defs"] as? [String: Any])?["dropped"] as? [String: Any])?["properties"]
            as? [String: Any])?["kind"] as? [String: Any]
        let wire = Set(try #require(enumValues?["enum"] as? [String],
                                    "could not read $defs.dropped.properties.kind.enum from chord.bindings.v3.json"))
        #expect(wire == enumKinds, """
        chord.bindings.v3.json dropped.kind enum drifted from ConfigWarning.Kind — \
        missing from schema: \(enumKinds.subtracting(wire).sorted()); \
        extra in schema: \(wire.subtracting(enumKinds).sorted()). \
        A rename is a schema MAJOR bump.
        """)
    }

    @Test func glossaryTableMatchesEnum() throws {
        let url = repoRoot().appendingPathComponent("docs/glossary.md")
        let md = try String(contentsOf: url, encoding: .utf8)

        let heading = try #require(md.range(of: "### `ConfigWarning.Kind`"),
                                   "could not find ### `ConfigWarning.Kind` in glossary.md")
        let rest = md[heading.upperBound...]
        let end = rest.range(of: "\n---")?.lowerBound
            ?? rest.range(of: "\n## ")?.lowerBound
            ?? rest.endIndex
        let section = rest[..<end]

        let pattern = try Regex(#"`"([^"]+)"`"#)
        let gloss = Set(section.matches(of: pattern).map { String($0[1].substring ?? "") })
        #expect(gloss == enumKinds, """
        glossary.md ### ConfigWarning.Kind table drifted from ConfigWarning.Kind — \
        missing from glossary: \(enumKinds.subtracting(gloss).sorted()); \
        extra in glossary: \(gloss.subtracting(enumKinds).sorted()).
        """)
    }
}
