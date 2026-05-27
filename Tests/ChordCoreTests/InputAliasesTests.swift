import XCTest
@testable import ChordCore

/// Coverage for `[input-aliases]` + bare modifier-set references
/// (e.g. `input = "ULTRA_LL - m"` resolving to
/// `rctrl + ralt + rshift - m`).
///
/// Three classes of behaviour:
///   * Load-time validation (`[input-aliases]` table itself)
///   * Parse-time resolution (`input = "…"` token lookup)
///   * Schema output (`chord.bindings.v2` `input_aliases` field)
final class InputAliasesTests: XCTestCase {

    // MARK: - Resolution: alias hits

    func testBareAliasResolvesToModifierMask() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "tab-left"
        input = "ULTRA_LL - c"
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
        input = "ULTRA_LL + cmd - m"
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
        input = "LEFT + RIGHT - a"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertTrue(b.modifiers.contains(.lctrl))
        XCTAssertTrue(b.modifiers.contains(.rctrl))
    }

    func testAliasLookupIsCaseInsensitive() throws {
        // Source uses MIXED case, binding writes lowercased.
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "tab-left"
        input = "ultra_ll - c"
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
        input = "ULTRA_LL - a"
        action-noop = true

        [[bindings]]
        name = "two"
        input = "ULTRA_LL - b"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 2)
        XCTAssertEqual(res.droppedBindings, 0)
    }

    // MARK: - Resolution: alias misses

    func testUndefinedAliasReferenceDropsBindingAsUnknownToken() throws {
        // No [input-aliases] declared; bare `ULTRA_LL` is just an
        // unknown modifier token. Same error class as a typo.
        let res = try Config.parse("""
        [[bindings]]
        name = "missing"
        input = "ULTRA_LL - m"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
        let w = res.warnings.first { $0.kind == .unknownInputToken }
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.message.contains("ultra_ll") == true)
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
        input = "ULTRA_LL - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasNonString }
        XCTAssertNotNil(w)
        // Binding drops because alias didn't load → unknown token.
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
    }

    func testAliasInvalidBodyIsRejected() throws {
        let res = try Config.parse("""
        [input-aliases]
        BAD = "notamod"

        [[bindings]]
        name = "want-alias"
        input = "BAD - m"
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
        input = "EMPTY - m"
        action-noop = true
        """)
        let w = res.warnings.first { $0.kind == .inputAliasInvalidBody }
        XCTAssertNotNil(w)
    }

    func testNestedAliasReferenceIsRejected() throws {
        // Body must contain only built-in modifier tokens — alias
        // bodies aren't recursively resolved (prevents cycles).
        let res = try Config.parse("""
        [input-aliases]
        INNER = "rctrl"
        OUTER = "INNER + ralt"

        [[bindings]]
        name = "uses-outer"
        input = "OUTER - m"
        action-noop = true
        """)
        // OUTER body references INNER which isn't a built-in mod →
        // body parse fails → OUTER not registered.
        let w = res.warnings.first {
            $0.kind == .inputAliasInvalidBody && $0.bindingName == "OUTER"
        }
        XCTAssertNotNil(w)
        // INNER is fine on its own.
        // Binding uses OUTER which didn't register → unknown token →
        // dropped.
        XCTAssertEqual(res.config.bindings.count, 0)
    }

    // MARK: - Schema output

    func testInputAliasesAppearInSchemaDocument() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL   = "rctrl + ralt + rshift"
        MIRACLE_LM = "rctrl + rcmd + rshift"

        [[bindings]]
        name = "one"
        input = "ULTRA_LL - a"
        action-noop = true
        """)
        let doc = Schema.makeDocument(from: res)
        XCTAssertEqual(doc.inputAliases["ULTRA_LL"], "rctrl + ralt + rshift")
        XCTAssertEqual(doc.inputAliases["MIRACLE_LM"], "rctrl + rcmd + rshift")
    }

    // MARK: - Wildcard fallback uses aliases too

    func testFallbackInputUsesAlias() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[fallbacks]]
        name = "undef feedback"
        input = "ULTRA_LL - *"
        action-shell = "afplay foo.wav"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 1)
        let f = res.config.fallbacks[0]
        XCTAssertTrue(f.modifiers.contains(.rctrl))
        XCTAssertTrue(f.modifiers.contains(.ropt))
        XCTAssertTrue(f.modifiers.contains(.rshift))
    }
}
