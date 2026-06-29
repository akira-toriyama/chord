import Testing
@testable import ChordCore

/// t-0055: optional `[options]` / `[[bindings]]` fields that are *present
/// but of the wrong TOML type* used to be silently skipped — the loader
/// reads them through `?.asBool` / `?.asArray`, which return `nil` on a
/// type miss, leaving the default in place with no warning. These tests
/// pin the additive `field-type-mismatch` warning and, crucially, the
/// no-regression contract: a valid config emits ZERO of them.
@Suite struct FieldTypeMismatchTests {

    private func mismatches(_ r: Config.ParseResult) -> [ConfigWarning] {
        r.warnings.filter { $0.kind == .fieldTypeMismatch }
    }

    // MARK: - [options]

    @Test func optionsPassthroughUnmatchedWrongType() throws {
        let r = try Config.parse(
            """
            [options]
            passthrough-unmatched = "true"
            """)
        // Default preserved (default is `true`) — the bogus value never took.
        #expect(r.config.options.passthroughUnmatched == true)
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("'passthrough-unmatched'"))
        #expect(m[0].message.contains("expected boolean"))
        #expect(m[0].message.contains("got string"))
    }

    @Test func optionsFnAutoArrowsWrongType() throws {
        let r = try Config.parse(
            """
            [options]
            fn-auto-arrows = 1
            """)
        // Default is `true` — preserved on a type miss.
        #expect(r.config.options.fnAutoArrows == true)
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("'fn-auto-arrows'"))
        #expect(m[0].message.contains("got integer"))
    }

    @Test func optionsExcludeAppsNonArray() throws {
        let r = try Config.parse(
            """
            [options]
            exclude-apps = "com.apple.Safari"
            """)
        #expect(r.config.options.excludeApps.isEmpty)
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("'exclude-apps'"))
        #expect(m[0].message.contains("expected array"))
    }

    @Test func optionsExcludeAppsNonStringElements() throws {
        let r = try Config.parse(
            """
            [options]
            exclude-apps = ["com.apple.Safari", 7, true]
            """)
        // The string element still loads; the bad ones are dropped.
        #expect(r.config.options.excludeApps == ["com.apple.Safari"])
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("non-string element"))
        #expect(m[0].message.contains("integer"))
        #expect(m[0].message.contains("boolean"))
    }

    // MARK: - [[bindings]]

    @Test func bindingPassthroughWrongType() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "pt"
            input = "cmd - a"
            action-shell = "echo hi"
            passthrough = "yes"
            """)
        // Binding still loads — only the field is ignored.
        #expect(r.config.bindings.count == 1)
        #expect(r.droppedBindings == 0)
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("passthrough"))
        #expect(m[0].message.contains("expected boolean"))
        #expect(m[0].bindingName == "pt")
    }

    @Test func bindingInputSourceWrongType() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "is"
            input = "cmd - a"
            action-shell = "echo hi"
            input-source = 3
            """)
        #expect(r.config.bindings.count == 1)
        #expect(r.config.bindings[0].inputSource == nil)
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("input-source"))
        #expect(m[0].message.contains("expected array or string"))
    }

    @Test func bindingInputSourceNonStringElements() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "is"
            input = "cmd - a"
            action-shell = "echo hi"
            input-source = ["com.apple.Terminal", 9]
            """)
        #expect(r.config.bindings.count == 1)
        #expect(r.config.bindings[0].inputSource == ["com.apple.Terminal"])
        let m = mismatches(r)
        #expect(m.count == 1)
        #expect(m[0].message.contains("non-string element"))
        #expect(m[0].message.contains("integer"))
    }

    // MARK: - no regression

    /// A valid config exercising every guarded field emits ZERO
    /// field-type-mismatch warnings (the load-time behaviour is unchanged
    /// for correct input).
    @Test func validConfigEmitsNoMismatch() throws {
        let r = try Config.parse(
            """
            [options]
            passthrough-unmatched = true
            exclude-apps = ["com.apple.Safari", "com.apple.Terminal"]
            fn-auto-arrows = false

            [[bindings]]
            name = "a"
            input = "cmd - a"
            action-shell = "echo hi"
            passthrough = true
            input-source = ["com.apple.Terminal"]

            [[bindings]]
            name = "b"
            input = "cmd - b"
            action-shell = "echo bye"
            input-source = "com.apple.Safari"
            """)
        #expect(mismatches(r).isEmpty)
    }

    /// Absent fields (the overwhelmingly common case) never warn.
    @Test func absentFieldsEmitNoMismatch() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "a"
            input = "cmd - a"
            action-keys = "cmd - c"
            """)
        #expect(mismatches(r).isEmpty)
    }
}
