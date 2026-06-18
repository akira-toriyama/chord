import XCTest
@testable import ChordCore

/// T5 (issue #52) — single-source-ification invariants. Each test pins a
/// refactor that replaced a duplicated literal / parallel list with one
/// source, so a future drift becomes a test failure (and, for the
/// enum-backed `kindString`, a compile error when an `Action` case is added).
final class SingleSourceT5Tests: XCTestCase {

    private func parseBindings(_ source: String) throws -> [String: Any] {
        let res = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: item a — the modifier-token table is the single source

    func testReservedModifierTokensDerivedFromTable() {
        XCTAssertEqual(InputParser.reservedModifierTokens,
                       Set(InputParser.modifierTokenMasks.keys))
        // Vocabulary is locked: a drift in either side would change this.
        XCTAssertEqual(InputParser.reservedModifierTokens.count, 30)
    }

    func testReservedTokensAllParseToTheirMask() throws {
        // Representative spellings, incl. the `hyper` composite and a
        // strict-side token, resolve to the table's mask.
        XCTAssertEqual(try InputParser.parseModifiersOnly("cmd"), .cmd)
        XCTAssertEqual(try InputParser.parseModifiersOnly("⌘"), .cmd)
        XCTAssertEqual(try InputParser.parseModifiersOnly("command"), .cmd)
        XCTAssertEqual(try InputParser.parseModifiersOnly("rctrl"), .rctrl)
        XCTAssertEqual(try InputParser.parseModifiersOnly("hyper"), .hyper)
        // Every reserved token must parse — proves the table and the
        // parser lookup share one source (none reserved-but-unparseable),
        // and that the union matches the table value.
        for (tok, mask) in InputParser.modifierTokenMasks {
            XCTAssertEqual(try InputParser.parseModifiersOnly(tok), mask,
                           "token '\(tok)' parsed to the wrong mask")
        }
    }

    // MARK: item b — Action.kindString is the single discriminator

    func testActionKindStrings() {
        XCTAssertEqual(Action.keys([], 0).kindString, "keys")
        XCTAssertEqual(Action.shell("x").kindString, "shell")
        XCTAssertEqual(Action.noop.kindString, "noop")
        XCTAssertEqual(Action.setVariable(name: "v", value: 1).kindString,
                       "set-variable")
        XCTAssertEqual(Action.toggleVariable(name: "v").kindString,
                       "toggle-variable")
    }

    func testWireSchemaKindIsSourcedFromKindString() throws {
        let json = try parseBindings("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let bindings = try XCTUnwrap(json["bindings"] as? [[String: Any]])
        let action = try XCTUnwrap(bindings.first?["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, Action.noop.kindString)
    }

    // MARK: item c — Modifiers.sideCategories is the single side table

    func testSideCategoriesOrderAndContents() {
        let c = Modifiers.sideCategories
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c[0].any, .cmd);   XCTAssertEqual(c[0].left, .lcmd);   XCTAssertEqual(c[0].right, .rcmd)
        XCTAssertEqual(c[1].any, .opt);   XCTAssertEqual(c[1].left, .lopt);   XCTAssertEqual(c[1].right, .ropt)
        XCTAssertEqual(c[2].any, .ctrl);  XCTAssertEqual(c[2].left, .lctrl);  XCTAssertEqual(c[2].right, .rctrl)
        XCTAssertEqual(c[3].any, .shift); XCTAssertEqual(c[3].left, .lshift); XCTAssertEqual(c[3].right, .rshift)
    }

    func testModifierSidesResolutionUnchanged() {
        let sides = BindingsSchema.modifierSides([.cmd, .rctrl])
        XCTAssertEqual(sides.cmd, "any")
        XCTAssertEqual(sides.ctrl, "right")
        XCTAssertEqual(sides.opt, "absent")
        XCTAssertEqual(sides.shift, "absent")
        XCTAssertEqual(BindingsSchema.modifierSides([.lcmd, .rcmd]).cmd, "both")
        XCTAssertEqual(BindingsSchema.modifierSides([.lshift]).shift, "left")
    }

    func testMatchesAndIsStillHeldSemanticsPreserved() {
        let rctrl: Modifiers = [.rctrl]
        let cmd: Modifiers = [.cmd]
        // strict-right ctrl matches right-only, not left-only.
        XCTAssertTrue(rctrl.matches(event: [.rctrl]))
        XCTAssertFalse(rctrl.matches(event: [.lctrl]))
        // any-side cmd matches either physical side.
        XCTAssertTrue(cmd.matches(event: [.lcmd]))
        XCTAssertTrue(cmd.matches(event: [.rcmd]))
        // isStillHeld is permissive: an extra modifier does not clear it,
        // but losing the held side does.
        XCTAssertTrue(cmd.isStillHeld(in: [.lcmd, .lshift]))
        XCTAssertFalse(cmd.isStillHeld(in: []))
    }

    // MARK: item d — InputParser.vkeyWildcardNames is the single source

    func testVkeyWildcardNames() throws {
        XCTAssertEqual(InputParser.vkeyWildcardNames, ["v-key", "vkey"])
        // The bare wildcard is rejected outside [[fallbacks]] (allowWildcard).
        XCTAssertThrowsError(try InputParser.parse("v-key"))
        XCTAssertThrowsError(try InputParser.parse("vkey"))
        let p = try InputParser.parse("vkey", allowWildcard: true)
        guard case .anyVKey = p.trigger else {
            return XCTFail("expected the any-vkey wildcard trigger")
        }
    }

    // MARK: item e — Dictionary.sourceLine threads the synthetic line key

    func testSourceLineThreadedThroughDroppedWarning() throws {
        // The 2nd binding (header on line 6) is missing `input`, so it is
        // dropped; its dropped[] entry must carry that source line — proving
        // the shared `row.sourceLine` accessor reads `__line__` correctly.
        let json = try parseBindings("""
        [[bindings]]
        name = "ok"
        input = "f13"
        action-noop = true

        [[bindings]]
        name = "bad"
        action-noop = true
        """)
        let dropped = try XCTUnwrap(json["dropped"] as? [[String: Any]])
        let bad = try XCTUnwrap(dropped.first { ($0["name"] as? String) == "bad" })
        // The accessor threaded a real `__line__` through to the warning.
        let line = try XCTUnwrap(bad["source_line"] as? Int)
        XCTAssertGreaterThan(line, 0)
    }

    // MARK: item f — WireAction defaulted-nil init

    func testWireActionDefaultedInit() {
        let w = BindingsSchema.WireAction(kind: "noop")
        XCTAssertEqual(w.kind, "noop")
        XCTAssertNil(w.raw)
        XCTAssertNil(w.modifiers)
        XCTAssertNil(w.key)
        XCTAssertNil(w.command)
        XCTAssertNil(w.alias)
        XCTAssertNil(w.variable)
        XCTAssertNil(w.value)
    }
}
