import Testing
@testable import ChordCore

/// Coverage for `[input-aliases]` + `$name` references
/// (e.g. `input = "$ULTRA_LL - m"` resolving to
/// `rctrl + ralt + rshift - m`).
///
/// The `$` prefix is the explicit signal that the token is a
/// user-defined modifier-set alias — parallels `@name` for
/// shell-action `[action-aliases]`. Bare references (without `$`) are
/// NOT resolved against `[input-aliases]` — they fail as
/// `unknown-input-token`, same as a plain modifier typo.
///
/// Three classes of behaviour:
///   * Load-time validation (`[input-aliases]` table itself)
///   * Parse-time resolution (`$name` token lookup)
///   * Schema output (`chord.bindings.v3` `input_aliases` field)
@Suite struct InputAliasesTests {

    // MARK: - Resolution: alias hits

    @Test func dollarPrefixedAliasResolvesToModifierMask() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "tab-left"
        input = "$ULTRA_LL - c"
        action-keys = "ctrl + shift - tab"
        """)
        #expect(res.config.bindings.count == 1)
        #expect(res.droppedBindings == 0)
        #expect(res.warnings.count == 0)
        let b = res.config.bindings[0]
        #expect(b.modifiers.contains(.rctrl))
        #expect(b.modifiers.contains(.ropt))
        #expect(b.modifiers.contains(.rshift))
    }

    @Test func aliasMixedWithBuiltinModifier() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "ultra + cmd"
        input = "$ULTRA_LL + cmd - m"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        #expect(b.modifiers.contains(.rctrl))
        #expect(b.modifiers.contains(.ropt))
        #expect(b.modifiers.contains(.rshift))
        #expect(b.modifiers.contains(.cmd))
    }

    @Test func twoAliasesUnion() throws {
        let res = try Config.parse("""
        [input-aliases]
        LEFT  = "lctrl"
        RIGHT = "rctrl"

        [[bindings]]
        name = "both-ctrls"
        input = "$LEFT + $RIGHT - a"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        #expect(b.modifiers.contains(.lctrl))
        #expect(b.modifiers.contains(.rctrl))
    }

    @Test func aliasLookupIsCaseInsensitive() throws {
        // Source declares with uppercase, binding references in
        // lowercase. Both resolve to the same entry.
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "tab-left"
        input = "$ultra_ll - c"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 1)
        #expect(res.droppedBindings == 0)
    }

    @Test func aliasSharedAcrossMultipleBindings() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "one"
        input = "$ULTRA_LL - a"
        action-noop = true

        [[bindings]]
        name = "two"
        input = "$ULTRA_LL - b"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 2)
        #expect(res.droppedBindings == 0)
    }

    // MARK: - Resolution: alias misses

    @Test func bareReferenceFallsThroughAsUnknownToken() throws {
        // Bare `ULTRA_LL` (no `$` prefix) is treated as a plain
        // modifier token — and since it isn't a built-in, it fails
        // as unknown-input-token. The `$` sigil is required to
        // request alias resolution.
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "bare reference"
        input = "ULTRA_LL - m"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings == 1)
        let w = res.warnings.first { $0.kind == .unknownInputToken }
        #expect(w != nil)
        #expect(w?.message.contains("ultra_ll") == true)
    }

    @Test func undefinedDollarReferenceDropsBindingWithSpecificKind() throws {
        // `$FOO_BAR` with no matching entry in `[input-aliases]`
        // emits `undefined-input-alias` (distinct from
        // `unknown-input-token` for bare typos) so consumers can
        // tell "you forgot to declare this alias" apart from
        // "you mistyped a modifier name".
        let res = try Config.parse("""
        [[bindings]]
        name = "undefined alias"
        input = "$FOO_BAR - x"
        action-noop = true
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings == 1)
        let w = res.warnings.first { $0.kind == .undefinedInputAlias }
        #expect(w != nil)
        #expect(w?.message.contains("$foo_bar") == true,
                "want alias name with `$` prefix in error: \(w?.message ?? "")")
    }

    // MARK: - Load validation

    @Test func aliasNameShadowsModifierIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        cmd = "ctrl + shift"

        [[bindings]]
        name = "should-not-shadow"
        input = "cmd - a"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasShadowsModifier }
        #expect(w != nil)
        #expect(w?.message.contains("'cmd'") == true)
        // The binding still loads (cmd is the built-in modifier).
        #expect(res.config.bindings.count == 1)
        let b = res.config.bindings[0]
        #expect(b.modifiers.contains(.cmd))
        #expect(!b.modifiers.contains(.ctrl))
        #expect(!b.modifiers.contains(.shift))
    }

    @Test func aliasNonStringValueIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = 42

        [[bindings]]
        name = "want-alias"
        input = "$ULTRA_LL - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasNonString }
        #expect(w != nil)
        // Binding drops because alias didn't load → undefined-input-alias.
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings == 1)
        #expect(
            res.warnings.first { $0.kind == .undefinedInputAlias } != nil)
    }

    @Test func aliasInvalidBodyIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        BAD = "notamod"

        [[bindings]]
        name = "want-alias"
        input = "$BAD - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasInvalidBody }
        #expect(w != nil)
        #expect(res.config.bindings.count == 0)
    }

    @Test func aliasEmptyBodyIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        EMPTY = ""

        [[bindings]]
        name = "want-alias"
        input = "$EMPTY - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasInvalidBody }
        #expect(w != nil)
    }

    @Test func nestedAliasReferenceIsRejected() throws {
        // Body must contain only built-in modifier tokens — alias
        // bodies aren't recursively resolved (prevents cycles).
        // `$INNER` inside OUTER's body fails because the load-time
        // body parser uses `parseModifiersOnly` with an empty alias
        // map.
        let res = try Config.parse("""
        [input-aliases]
        INNER = "rctrl"
        OUTER = "$INNER + ralt"

        [[bindings]]
        name = "uses-outer"
        input = "$OUTER - m"
        action-noop = true
        """)
        let w = res.warnings.first {
            $0.kind == .inputAliasInvalidBody && $0.bindingName == "OUTER"
        }
        #expect(w != nil)
        // INNER is fine on its own. OUTER didn't register, so the
        // binding using $OUTER drops as undefinedInputAlias.
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.first { $0.kind == .undefinedInputAlias } != nil)
    }

    // MARK: - Schema output

    @Test func inputAliasesAppearInSchemaDocument() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL   = "rctrl + ralt + rshift"
        MIRACLE_LM = "rctrl + rcmd + rshift"

        [[bindings]]
        name = "one"
        input = "$ULTRA_LL - a"
        action-noop = true
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        #expect(doc.inputAliases["ULTRA_LL"] == "rctrl + ralt + rshift")
        #expect(doc.inputAliases["MIRACLE_LM"] == "rctrl + rcmd + rshift")
    }

    // MARK: - Wildcard fallback uses actionAliases too

    @Test func fallbackInputUsesAlias() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[fallbacks]]
        name = "undef feedback"
        input = "$ULTRA_LL - *"
        action-shell = "afplay foo.wav"
        """)
        #expect(res.config.fallbacks.count == 1)
        let f = res.config.fallbacks[0]
        #expect(f.modifiers.contains(.rctrl))
        #expect(f.modifiers.contains(.ropt))
        #expect(f.modifiers.contains(.rshift))
    }
}
