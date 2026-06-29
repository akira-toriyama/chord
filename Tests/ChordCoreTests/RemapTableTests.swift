import Testing
@testable import ChordCore

/// chord 0.8.0+: `[[remap]]` is a 1-to-1 `modifiers + key → action-keys`
/// table form. Each map entry expands to a single `.keys` binding at
/// parse time. Pure sugar — Matcher / Controller see only the
/// expanded bindings.
@Suite struct RemapTableTests {

    // MARK: - TOML inline-table value parsing (parser dependency)

    @Test func inlineTableParsesAsTableValue() throws {
        let v = try TOML.parse(
            """
            [[remap]]
            map = { b = "left", f = "right" }
            """)
        let rows = v["remap"]?.asArrayOfTables ?? []
        #expect(rows.count == 1)
        let map = rows[0]["map"]?.asTable
        #expect(map?["b"]?.asString == "left")
        #expect(map?["f"]?.asString == "right")
    }

    @Test func inlineTableHandlesQuotedKeys() throws {
        // Inline-table keys may be quoted — needed when the key is
        // a dotted bundle ID (used by per-app #12).
        let v = try TOML.parse(
            """
            [[remap]]
            map = { "b" = "left", 'f' = "right" }
            """)
        let map = v["remap"]?.asArrayOfTables?[0]["map"]?.asTable
        #expect(map?["b"]?.asString == "left")
        #expect(map?["f"]?.asString == "right")
    }

    // MARK: - Basic expansion

    @Test func remapExpandsToOneBindingPerMapEntry() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "emacs-readline"
            modifiers = "ctrl"
            map = { b = "left", f = "right", p = "up", n = "down" }
            """)
        #expect(res.droppedBindings == 0)
        #expect(
            res.config.bindings.count == 4,
            "4 map entries → 4 expanded bindings")

        // Deterministic ordering: sorted by map key.
        let names = res.config.bindings.map(\.name)
        #expect(
            names == [
                "emacs-readline.b",
                "emacs-readline.f",
                "emacs-readline.n",
                "emacs-readline.p"
            ])

        // Each expanded binding is an action-keys, ctrl modset, correct keycode.
        let byName = Dictionary(
            uniqueKeysWithValues:
                res.config.bindings.map { ($0.name, $0) })
        if case .keys(let mods, let kc) = byName["emacs-readline.b"]?.action {
            #expect(mods == [])
            #expect(kc == 0x7B)  // arrow_left
        } else {
            Issue.record("expected .keys")
        }
        #expect(byName["emacs-readline.b"]?.modifiers == [.ctrl])
        #expect(byName["emacs-readline.b"]?.inputRaw == "ctrl - b")
    }

    @Test func remapResolvesInputAlias() throws {
        // `modifiers = "$ULTRA_LL"` should resolve via [input-aliases].
        let res = try Config.parse(
            """
            [input-aliases]
            ULTRA_LL = "rctrl + ralt + rshift"

            [[remap]]
            name = "ultra-emacs"
            modifiers = "$ULTRA_LL"
            map = { b = "left" }
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 1)
        #expect(res.config.bindings[0].modifiers == [.rctrl, .ropt, .rshift])
    }

    @Test func remapInheritsApps() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "term-only"
            modifiers = "ctrl"
            map = { b = "left", f = "right" }
            apps = ["com.apple.Terminal"]
            """)
        #expect(res.droppedBindings == 0)
        for b in res.config.bindings {
            #expect(b.apps == ["com.apple.Terminal"])
        }
    }

    // MARK: - Ordering vs regular [[bindings]]

    @Test func regularBindingWinsOverRemapEntryOnCollision() throws {
        // Regular `[[bindings]]` appear BEFORE remap expansions, so
        // first-match-wins lets a specific binding override a remap
        // entry without dropping it.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "specific ctrl-b"
            input = "ctrl - b"
            action-shell = "echo override"

            [[remap]]
            name = "emacs"
            modifiers = "ctrl"
            map = { b = "left", f = "right" }
            """)
        #expect(res.droppedBindings == 0)
        // Order: regular ctrl-b (override), remap.b, remap.f.
        #expect(
            res.config.bindings.map(\.name) == [
                "specific ctrl-b",
                "emacs.b",
                "emacs.f"
            ])
        // Matcher hits the regular one first.
        let m = Matcher(bindings: res.config.bindings)
        let hit = m.find(
            .init(
                trigger: .key(0x0B),  // 'b'
                modifiers: [.lctrl],
                bundleID: nil))
        #expect(hit?.name == "specific ctrl-b")
    }

    // MARK: - Validation: error paths

    @Test func missingModifiersDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            map = { b = "left" }
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("missing 'modifiers'")
            })
    }

    @Test func emptyModifiersDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            modifiers = ""
            map = { b = "left" }
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .remapParseError })
    }

    @Test func missingMapDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            modifiers = "ctrl"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("missing 'map'")
            })
    }

    @Test func nonTableMapDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            modifiers = "ctrl"
            map = "not a table"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("inline table")
            })
    }

    @Test func emptyMapDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            modifiers = "ctrl"
            map = {}
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("at least one entry")
            })
    }

    @Test func nonStringMapValueOnlyDropsThatEntry() throws {
        // Other map entries should still expand normally.
        let res = try Config.parse(
            """
            [[remap]]
            name = "partial"
            modifiers = "ctrl"
            map = { b = "left", f = 42 }
            """)
        #expect(
            res.config.bindings.count == 1,
            "the string entry expands; the int entry drops")
        #expect(res.droppedBindings == 1)
        #expect(res.config.bindings[0].name == "partial.b")
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("map['f']")
            })
    }

    @Test func undefinedInputAliasInModifiersDropsRemap() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "broken"
            modifiers = "$NOPE"
            map = { b = "left" }
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .remapParseError && $0.message.contains("$NOPE")
            })
    }

    // MARK: - End-to-end via Matcher

    @Test func expandedRemapMatchesAtMatcher() throws {
        let res = try Config.parse(
            """
            [[remap]]
            name = "emacs"
            modifiers = "ctrl"
            map = { b = "left", h = "backspace" }
            """)
        let m = Matcher(bindings: res.config.bindings)
        let b = m.find(
            .init(
                trigger: .key(0x0B),  // 'b'
                modifiers: [.lctrl],
                bundleID: nil))
        #expect(b?.name == "emacs.b")
        if case .keys(_, let kc) = b?.action {
            #expect(kc == 0x7B)  // arrow_left
        } else {
            Issue.record("expected .keys")
        }

        let h = m.find(
            .init(
                trigger: .key(0x04),  // 'h'
                modifiers: [.lctrl],
                bundleID: nil))
        #expect(h?.name == "emacs.h")
    }
}
