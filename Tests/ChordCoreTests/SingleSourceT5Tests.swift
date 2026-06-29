import Testing
@testable import ChordCore

/// T5 (issue #52) — single-source-ification invariants. Each test pins a
/// refactor that replaced a duplicated literal / parallel list with one
/// source, so a future drift becomes a test failure (and, for the
/// enum-backed `kindString`, a compile error when an `Action` case is added).
@Suite struct SingleSourceT5Tests {

    private func parseBindings(_ source: String) throws -> [String: Any] {
        try parseToBindingsJSON(source)
    }

    // MARK: item a — the modifier-token table is the single source

    @Test func reservedModifierTokensDerivedFromTable() {
        #expect(InputParser.reservedModifierTokens == Set(InputParser.modifierTokenMasks.keys))
        // Vocabulary is locked: a drift in either side would change this.
        #expect(InputParser.reservedModifierTokens.count == 30)
    }

    @Test func reservedTokensAllParseToTheirMask() throws {
        // Representative spellings, incl. the `hyper` composite and a
        // strict-side token, resolve to the table's mask.
        #expect(try InputParser.parseModifiersOnly("cmd") == .cmd)
        #expect(try InputParser.parseModifiersOnly("⌘") == .cmd)
        #expect(try InputParser.parseModifiersOnly("command") == .cmd)
        #expect(try InputParser.parseModifiersOnly("rctrl") == .rctrl)
        #expect(try InputParser.parseModifiersOnly("hyper") == .hyper)
        // Every reserved token must parse — proves the table and the
        // parser lookup share one source (none reserved-but-unparseable),
        // and that the union matches the table value.
        for (tok, mask) in InputParser.modifierTokenMasks {
            #expect(
                try InputParser.parseModifiersOnly(tok) == mask,
                "token '\(tok)' parsed to the wrong mask")
        }
    }

    // MARK: item b — Action.kindString is the single discriminator

    @Test func actionKindStrings() {
        #expect(Action.keys([], 0).kindString == "keys")
        #expect(Action.shell("x").kindString == "shell")
        #expect(Action.noop.kindString == "noop")
        #expect(Action.setVariable(name: "v", value: 1).kindString == "set-variable")
        #expect(Action.toggleVariable(name: "v").kindString == "toggle-variable")
    }

    @Test func wireSchemaKindIsSourcedFromKindString() throws {
        let json = try parseBindings(
            """
            [[bindings]]
            name = "x"
            input = "f13"
            action-noop = true
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        let action = try #require(bindings.first?["action"] as? [String: Any])
        #expect(action["kind"] as? String == Action.noop.kindString)
    }

    // MARK: item c — Modifiers.sideCategories is the single side table

    @Test func sideCategoriesOrderAndContents() {
        let c = Modifiers.sideCategories
        #expect(c.count == 4)
        #expect(c[0].any == .cmd); #expect(c[0].left == .lcmd); #expect(c[0].right == .rcmd)
        #expect(c[1].any == .opt); #expect(c[1].left == .lopt); #expect(c[1].right == .ropt)
        #expect(c[2].any == .ctrl); #expect(c[2].left == .lctrl); #expect(c[2].right == .rctrl)
        #expect(c[3].any == .shift); #expect(c[3].left == .lshift); #expect(c[3].right == .rshift)
    }

    @Test func modifierSidesResolutionUnchanged() {
        let sides = BindingsSchema.modifierSides([.cmd, .rctrl])
        #expect(sides.cmd == "any")
        #expect(sides.ctrl == "right")
        #expect(sides.opt == "absent")
        #expect(sides.shift == "absent")
        #expect(BindingsSchema.modifierSides([.lcmd, .rcmd]).cmd == "both")
        #expect(BindingsSchema.modifierSides([.lshift]).shift == "left")
    }

    @Test func matchesAndIsStillHeldSemanticsPreserved() {
        let rctrl: Modifiers = [.rctrl]
        let cmd: Modifiers = [.cmd]
        // strict-right ctrl matches right-only, not left-only.
        #expect(rctrl.matches(event: [.rctrl]))
        #expect(!rctrl.matches(event: [.lctrl]))
        // any-side cmd matches either physical side.
        #expect(cmd.matches(event: [.lcmd]))
        #expect(cmd.matches(event: [.rcmd]))
        // isStillHeld is permissive: an extra modifier does not clear it,
        // but losing the held side does.
        #expect(cmd.isStillHeld(in: [.lcmd, .lshift]))
        #expect(!cmd.isStillHeld(in: []))
    }

    // MARK: item d — InputParser.vkeyWildcardNames is the single source

    @Test func vkeyWildcardNames() throws {
        #expect(InputParser.vkeyWildcardNames == ["v-key", "vkey"])
        // The bare wildcard is rejected outside [[fallbacks]] (allowWildcard).
        #expect(throws: (any Error).self) { try InputParser.parse("v-key") }
        #expect(throws: (any Error).self) { try InputParser.parse("vkey") }
        let p = try InputParser.parse("vkey", allowWildcard: true)
        guard case .anyVKey = p.trigger else {
            Issue.record("expected the any-vkey wildcard trigger")
            return
        }
    }

    // MARK: item e — Toml.Row.span threads the source line end-to-end

    @Test func sourceLineThreadedThroughDroppedWarning() throws {
        // The 2nd binding (header on line 6) is missing `input`, so it is
        // dropped; its dropped[] entry must carry that source line — proving
        // the `Toml.Row.span` line is resolved at parse time and threaded
        // through makeBinding into the warning (#148; replaced the old
        // synthetic `__line__` dict key).
        let json = try parseBindings(
            """
            [[bindings]]
            name = "ok"
            input = "f13"
            action-noop = true

            [[bindings]]
            name = "bad"
            action-noop = true
            """)
        let dropped = try #require(json["dropped"] as? [[String: Any]])
        let bad = try #require(dropped.first { ($0["name"] as? String) == "bad" })
        // The accessor threaded a real `__line__` through to the warning.
        let line = try #require(bad["source_line"] as? Int)
        #expect(line > 0)
    }

    // MARK: item f — WireAction defaulted-nil init

    @Test func wireActionDefaultedInit() {
        let w = BindingsSchema.WireAction(kind: "noop")
        #expect(w.kind == "noop")
        #expect(w.raw == nil)
        #expect(w.modifiers == nil)
        #expect(w.key == nil)
        #expect(w.command == nil)
        #expect(w.alias == nil)
        #expect(w.variable == nil)
        #expect(w.value == nil)
    }
}
