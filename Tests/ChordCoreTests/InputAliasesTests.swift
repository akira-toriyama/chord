import XCTest
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
final class InputAliasesTests: XCTestCase {

    // MARK: - Resolution: alias hits

    func testDollarPrefixedAliasResolvesToModifierMask() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "tab-left"
        input = "$ULTRA_LL - c"
        action-keys = "ctrl + shift - tab"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.warnings.count, 0)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.modifiers.contains(.rctrl))
        XCTAssertTrue(b.modifiers.contains(.ropt))
        XCTAssertTrue(b.modifiers.contains(.rshift))
    }

    func testAliasMixedWithBuiltinModifier() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "ultra + cmd"
        input = "$ULTRA_LL + cmd - m"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.modifiers.contains(.rctrl))
        XCTAssertTrue(b.modifiers.contains(.ropt))
        XCTAssertTrue(b.modifiers.contains(.rshift))
        XCTAssertTrue(b.modifiers.contains(.cmd))
    }

    func testTwoAliasesUnion() throws {
        let res = try Config.parse("""
        [input-aliases]
        LEFT  = "lctrl"
        RIGHT = "rctrl"

        [[bindings]]
        name = "both-ctrls"
        input = "$LEFT + $RIGHT - a"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.modifiers.contains(.lctrl))
        XCTAssertTrue(b.modifiers.contains(.rctrl))
    }

    func testAliasLookupIsCaseInsensitive() throws {
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
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.droppedBindings, 0)
    }

    func testAliasSharedAcrossMultipleBindings() throws {
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
        XCTAssertEqual(res.config.bindings.count, 2)
        XCTAssertEqual(res.droppedBindings, 0)
    }

    // MARK: - Resolution: alias misses

    func testBareReferenceFallsThroughAsUnknownToken() throws {
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
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
        let w = res.warnings.first { $0.kind == .unknownInputToken }
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.message.contains("ultra_ll") == true)
    }

    func testUndefinedDollarReferenceDropsBindingWithSpecificKind() throws {
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
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
        let w = res.warnings.first { $0.kind == .undefinedInputAlias }
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.message.contains("$foo_bar") == true,
                      "want alias name with `$` prefix in error: \(w?.message ?? "")")
    }

    // MARK: - Load validation

    func testAliasNameShadowsModifierIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        cmd = "ctrl + shift"

        [[bindings]]
        name = "should-not-shadow"
        input = "cmd - a"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasShadowsModifier }
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.message.contains("'cmd'") == true)
        // The binding still loads (cmd is the built-in modifier).
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.modifiers.contains(.cmd))
        XCTAssertFalse(b.modifiers.contains(.ctrl))
        XCTAssertFalse(b.modifiers.contains(.shift))
    }

    func testAliasNonStringValueIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = 42

        [[bindings]]
        name = "want-alias"
        input = "$ULTRA_LL - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasNonString }
        XCTAssertNotNil(w)
        // Binding drops because alias didn't load → undefined-input-alias.
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
        XCTAssertNotNil(
            res.warnings.first { $0.kind == .undefinedInputAlias })
    }

    func testAliasInvalidBodyIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        BAD = "notamod"

        [[bindings]]
        name = "want-alias"
        input = "$BAD - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasInvalidBody }
        XCTAssertNotNil(w)
        XCTAssertEqual(res.config.bindings.count, 0)
    }

    func testAliasEmptyBodyIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        EMPTY = ""

        [[bindings]]
        name = "want-alias"
        input = "$EMPTY - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasInvalidBody }
        XCTAssertNotNil(w)
    }

    func testNestedAliasReferenceIsRejected() throws {
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
        XCTAssertNotNil(w)
        // INNER is fine on its own. OUTER didn't register, so the
        // binding using $OUTER drops as undefinedInputAlias.
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertNotNil(
            res.warnings.first { $0.kind == .undefinedInputAlias })
    }

    // MARK: - Schema output

    func testInputAliasesAppearInSchemaDocument() throws {
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
        XCTAssertEqual(doc.inputAliases["ULTRA_LL"], "rctrl + ralt + rshift")
        XCTAssertEqual(doc.inputAliases["MIRACLE_LM"], "rctrl + rcmd + rshift")
    }

    // MARK: - Wildcard fallback uses actionAliases too

    func testFallbackInputUsesAlias() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[fallbacks]]
        name = "undef feedback"
        input = "$ULTRA_LL - *"
        action-shell = "afplay foo.wav"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 1)
        let f = res.config.fallbacks[0]
        XCTAssertTrue(f.modifiers.contains(.rctrl))
        XCTAssertTrue(f.modifiers.contains(.ropt))
        XCTAssertTrue(f.modifiers.contains(.rshift))
    }
}
