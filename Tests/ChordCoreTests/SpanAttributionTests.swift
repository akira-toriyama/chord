import Testing

@testable import ChordCore

/// t-0030 / chord#159 — per-field span attribution. Warnings point at the
/// offending FIELD (line + column, from `parseWithSpans`' entry index), not
/// just the row's `[[header]]` line, and `sourceTag` renders the column:
/// `(config.toml:N:C)`. Columns are 1-based Unicode scalars; an entry's key
/// span is its key's first character, its value span the value's first
/// character (the opening quote for a string).
struct SpanAttributionTests {

    @Test func malformedInputValuePointsAtValue() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "b1"
            input = "notakey - x"
            action-noop = true
            """)
        let w = try #require(r.warnings.first { $0.kind == .unknownInputToken })
        #expect(
            w.source == TOML.SourceSpan(line: 3, column: 9),
            "want the input VALUE's position, not the header: \(String(describing: w.source))")
        #expect(w.message.contains("(config.toml:3:9)"), w.message.comment)
    }

    @Test func unknownRowKeyPointsAtKey() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "b2"
            input = "cmd - a"
            action-noop = true
            actoin-shell = "echo hi"
            """)
        let w = try #require(r.warnings.first { $0.kind == .unknownKey })
        #expect(w.source == TOML.SourceSpan(line: 5, column: 1))
        #expect(w.message.contains("(config.toml:5:1)"), w.message.comment)
    }

    @Test func optionsTypeMismatchGetsLocation() throws {
        // [options] fields historically carried NO location (plain tables
        // had no span) — the entry index upgrades them to value-precise.
        let r = try Config.parse(
            """
            [options]
            passthrough-unmatched = "yes"
            """)
        let w = try #require(r.warnings.first { $0.kind == .fieldTypeMismatch })
        #expect(w.sourceLine == 2)
        #expect(w.message.contains("(config.toml:2:25)"), w.message.comment)
    }

    @Test func unknownOptionKeyPointsAtKey() throws {
        let r = try Config.parse(
            """
            [options]
            passthroughUnmatched = true
            """)
        let w = try #require(r.warnings.first { $0.kind == .unknownOptionKey })
        #expect(w.sourceLine == 2)
        #expect(w.message.contains("(config.toml:2:1)"), w.message.comment)
    }

    @Test func perAppOverrideErrorPointsAtEntryField() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "t"
            input = "cmd - c"
            action-noop = true

              [[bindings.per-app]]
              bundle-id = "com.x"
              action-keys = "zzz9 + bad"
            """)
        let w = try #require(r.warnings.first { $0.kind == .actionKeysParseError })
        #expect(
            w.sourceLine == 8,
            "want the per-app entry's field line: \(String(describing: w.sourceLine))")
        #expect(w.message.contains("(config.toml:8:17)"), w.message.comment)
    }

    @Test func sequenceChildMissingInputPointsAtChildHeader() throws {
        let r = try Config.parse(
            """
            [[sequence]]
            name = "s"
            prefix = "cmd + ctrl - t"
            timeout-ms = 500

              [[sequence.bindings]]
              action-noop = true
            """)
        let w = try #require(r.warnings.first { $0.kind == .missingInput })
        #expect(w.sourceLine == 6)
        #expect(w.message.contains("(config.toml:6:3)"), w.message.comment)
    }

    @Test func remapMapErrorPointsAtMapEntry() throws {
        // Inline-table interiors are not indexed (the entry is the unit),
        // so a bad map value attributes to the `map` entry itself.
        let r = try Config.parse(
            """
            [[remap]]
            name = "r"
            modifiers = "cmd + opt"
            map = { b = 7 }
            """)
        let w = try #require(r.warnings.first { $0.kind == .remapParseError })
        #expect(w.sourceLine == 4)
        #expect(w.message.contains("(config.toml:4"), w.message.comment)
    }

    @Test func bindingKeepsHeaderAttribution() throws {
        // Binding-level attribution stays the row header (per-field spans
        // are for warnings); the header is line 1 here.
        let r = try Config.parse(
            """
            [[bindings]]
            name = "ok"
            input = "f13"
            action-noop = true
            """)
        let b = try #require(r.config.bindings.first)
        #expect(b.sourceSpan == TOML.SourceSpan(line: 1, column: 1))
        #expect(b.sourceLine == 1)
    }
}

extension String {
    /// `#expect(cond, w.message.comment)` — surface the actual message on failure.
    fileprivate var comment: Comment { Comment(rawValue: self) }
}
