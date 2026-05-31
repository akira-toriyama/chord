import XCTest
@testable import ChordCore

/// chord 0.8.0+: `[[remap]]` is a 1-to-1 `modifiers + key → action-keys`
/// table form. Each map entry expands to a single `.keys` binding at
/// parse time. Pure sugar — Matcher / Controller see only the
/// expanded bindings.
final class RemapTableTests: XCTestCase {

    // MARK: - TOML inline-table value parsing (parser dependency)

    func testInlineTableParsesAsTableValue() throws {
        let v = try TOML.parse("""
        [[remap]]
        map = { b = "left", f = "right" }
        """)
        let rows = v["remap"]?.asArrayOfTables ?? []
        XCTAssertEqual(rows.count, 1)
        let map = rows[0]["map"]?.asTable
        XCTAssertEqual(map?["b"]?.asString, "left")
        XCTAssertEqual(map?["f"]?.asString, "right")
    }

    func testInlineTableHandlesQuotedKeys() throws {
        // Per-app branching (issue #12) will lean on this — bundle
        // IDs are dotted strings and need to be writable as quoted keys.
        let v = try TOML.parse("""
        [bindings.per-app]
        "com.google.Chrome" = "x"
        """)
        let pa = v["bindings"]?.asTable?["per-app"]?.asTable
        XCTAssertEqual(pa?["com.google.Chrome"]?.asString, "x")
    }

    // MARK: - Basic expansion

    func testRemapExpandsToOneBindingPerMapEntry() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "emacs-readline"
        modifiers = "ctrl"
        map = { b = "left", f = "right", p = "up", n = "down" }
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 4,
                       "4 map entries → 4 expanded bindings")

        // Deterministic ordering: sorted by map key.
        let names = res.config.bindings.map(\.name)
        XCTAssertEqual(names, [
            "emacs-readline.b",
            "emacs-readline.f",
            "emacs-readline.n",
            "emacs-readline.p",
        ])

        // Each expanded binding is an action-keys, ctrl modset, correct keycode.
        let byName = Dictionary(uniqueKeysWithValues:
            res.config.bindings.map { ($0.name, $0) })
        if case .keys(let mods, let kc) = byName["emacs-readline.b"]?.action {
            XCTAssertEqual(mods, [])
            XCTAssertEqual(kc, 0x7B)   // arrow_left
        } else { XCTFail("expected .keys") }
        XCTAssertEqual(byName["emacs-readline.b"]?.modifiers, [.ctrl])
        XCTAssertEqual(byName["emacs-readline.b"]?.inputRaw, "ctrl - b")
    }

    func testRemapResolvesInputAlias() throws {
        // `modifiers = "$ULTRA_LL"` should resolve via [input-aliases].
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[remap]]
        name = "ultra-emacs"
        modifiers = "$ULTRA_LL"
        map = { b = "left" }
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.config.bindings[0].modifiers,
                       [.rctrl, .ropt, .rshift])
    }

    func testRemapInheritsApps() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "term-only"
        modifiers = "ctrl"
        map = { b = "left", f = "right" }
        apps = ["com.apple.Terminal"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        for b in res.config.bindings {
            XCTAssertEqual(b.apps, ["com.apple.Terminal"])
        }
    }

    // MARK: - Ordering vs regular [[bindings]]

    func testRegularBindingWinsOverRemapEntryOnCollision() throws {
        // Regular `[[bindings]]` appear BEFORE remap expansions, so
        // first-match-wins lets a specific binding override a remap
        // entry without dropping it.
        let res = try Config.parse("""
        [[bindings]]
        name = "specific ctrl-b"
        input = "ctrl - b"
        action-shell = "echo override"

        [[remap]]
        name = "emacs"
        modifiers = "ctrl"
        map = { b = "left", f = "right" }
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        // Order: regular ctrl-b (override), remap.b, remap.f.
        XCTAssertEqual(res.config.bindings.map(\.name), [
            "specific ctrl-b",
            "emacs.b",
            "emacs.f",
        ])
        // Matcher hits the regular one first.
        let m = Matcher(bindings: res.config.bindings)
        let hit = m.find(.init(trigger: .key(0x0B),    // 'b'
                               modifiers: [.lctrl],
                               bundleID: nil))
        XCTAssertEqual(hit?.name, "specific ctrl-b")
    }

    // MARK: - Validation: error paths

    func testMissingModifiersDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        map = { b = "left" }
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("missing 'modifiers'")
        })
    }

    func testEmptyModifiersDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        modifiers = ""
        map = { b = "left" }
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .remapParseError })
    }

    func testMissingMapDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        modifiers = "ctrl"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("missing 'map'")
        })
    }

    func testNonTableMapDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        modifiers = "ctrl"
        map = "not a table"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("inline table")
        })
    }

    func testEmptyMapDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        modifiers = "ctrl"
        map = {}
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("at least one entry")
        })
    }

    func testNonStringMapValueOnlyDropsThatEntry() throws {
        // Other map entries should still expand normally.
        let res = try Config.parse("""
        [[remap]]
        name = "partial"
        modifiers = "ctrl"
        map = { b = "left", f = 42 }
        """)
        XCTAssertEqual(res.config.bindings.count, 1,
                       "the string entry expands; the int entry drops")
        XCTAssertEqual(res.droppedBindings, 1)
        XCTAssertEqual(res.config.bindings[0].name, "partial.b")
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("map['f']")
        })
    }

    func testUndefinedInputAliasInModifiersDropsRemap() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "broken"
        modifiers = "$NOPE"
        map = { b = "left" }
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .remapParseError &&
            $0.message.contains("$NOPE")
        })
    }

    // MARK: - End-to-end via Matcher

    func testExpandedRemapMatchesAtMatcher() throws {
        let res = try Config.parse("""
        [[remap]]
        name = "emacs"
        modifiers = "ctrl"
        map = { b = "left", h = "backspace" }
        """)
        let m = Matcher(bindings: res.config.bindings)
        let b = m.find(.init(trigger: .key(0x0B),      // 'b'
                             modifiers: [.lctrl],
                             bundleID: nil))
        XCTAssertEqual(b?.name, "emacs.b")
        if case .keys(_, let kc) = b?.action {
            XCTAssertEqual(kc, 0x7B)  // arrow_left
        } else { XCTFail("expected .keys") }

        let h = m.find(.init(trigger: .key(0x04),      // 'h'
                             modifiers: [.lctrl],
                             bundleID: nil))
        XCTAssertEqual(h?.name, "emacs.h")
    }
}
