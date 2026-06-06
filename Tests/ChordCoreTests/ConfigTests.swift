import XCTest
@testable import ChordCore

final class ConfigTests: XCTestCase {
    func testParsesAllActionShapes() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        exclude-apps = ["com.apple.dt.Xcode"]

        [[bindings]]
        name = "launch terminal"
        input = "f13"
        action-shell = "open -a Terminal"

        [[bindings]]
        name = "screenshot"
        input = "mouse.side1"
        action-keys = "cmd + shift - 4"

        [[bindings]]
        name = "block caps"
        input = "caps_lock"
        action-noop = true
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.config.bindings.count, 3)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.options.excludeApps,
                       ["com.apple.dt.Xcode"])

        switch r.config.bindings[0].action {
        case .shell(let s): XCTAssertEqual(s, "open -a Terminal")
        default: XCTFail("expected shell action")
        }
        switch r.config.bindings[1].action {
        case .keys(let mods, let code):
            XCTAssertEqual(mods, [.cmd, .shift])
            XCTAssertEqual(code, 0x15)
        default: XCTFail("expected keys action")
        }
        XCTAssertEqual(r.config.bindings[2].action, .noop)
    }

    func testBadBindingDoesNotBreakOthers() throws {
        let source = """
        [[bindings]]
        name = "bad"
        input = "no-such-key"
        action-shell = "true"

        [[bindings]]
        name = "good"
        input = "f14"
        action-shell = "true"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 1)
        XCTAssertEqual(r.config.bindings.count, 1)
        XCTAssertEqual(r.config.bindings[0].name, "good")
    }

    func testShellPlusKeysCombineOnDown() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree --loading=2000"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.bindings.count, 1)
        let b = r.config.bindings[0]
        // Shell becomes the primary (it fires first on down)…
        switch b.action {
        case .shell(let s):
            XCTAssertEqual(s, "facet --view=tree --loading=2000")
        default: XCTFail("expected shell primary action")
        }
        // …and the keys land in extraDownActions (posted right after).
        XCTAssertEqual(b.extraDownActions.count, 1)
        switch b.extraDownActions.first {
        case .keys(let mods, let code):
            XCTAssertEqual(mods, [.ctrl])
            XCTAssertEqual(code, 0x7C)
        default: XCTFail("expected a chained keys action")
        }
    }

    func testShellPlusBadKeysDropsBinding() throws {
        let source = """
        [[bindings]]
        name = "broken combo"
        input = "ctrl - right"
        action-shell = "true"
        action-keys = "no-such-key"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 1)
        XCTAssertEqual(r.config.bindings.count, 0)
    }

    func testExtraActionsSurfaceInWireSchema() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: r)
        let extra = doc.bindings[0].extraActions
        XCTAssertEqual(extra?.count, 1)
        XCTAssertEqual(extra?.first?.kind, "keys")
        XCTAssertEqual(extra?.first?.key?.keycode, 0x7C)
    }

    // MARK: - silent-drop fixes (analysis report items 2A / 2B)

    /// `[options]` typos used to be silent — the binding parser
    /// only checks the keys it knows about, so a camelCase typo
    /// (`passthroughUnmatched`) or an invented key looked exactly
    /// like "it worked but had no effect". Warn on every unknown
    /// key so `--validate --strict` catches it in CI.
    func testUnknownOptionKeyWarns() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        passthroughUnmatched = false
        bogus-option = "what"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.config.options.passthroughUnmatched, true,
                       "the kebab-case key still wins")
        let kinds = r.warnings.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .unknownOptionKey }.count, 2)
        // The kebab-case key is NOT flagged as unknown.
        XCTAssertFalse(r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'passthrough-unmatched'")
        })
        // The two known-bad keys ARE flagged.
        XCTAssertTrue(r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'passthroughUnmatched'")
        })
        XCTAssertTrue(r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'bogus-option'")
        })
    }

    /// Two user-named bindings sharing a name still load (chord
    /// doesn't enforce uniqueness — the order-based first-match-wins
    /// matcher copes), but `--list --json` consumers and the
    /// `--reload --dry-run` name-keyed diff can't tell them apart.
    /// Surface the ambiguity as a warning so it doesn't silently
    /// degrade the introspection tooling.
    func testDuplicateBindingNameWarns() throws {
        let source = """
        [[bindings]]
        name = "twin"
        input = "f13"
        action-noop = true

        [[bindings]]
        name = "twin"
        input = "f14"
        action-noop = true
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.config.bindings.count, 2,
                       "both still load — uniqueness is not enforced")
        let dups = r.warnings.filter { $0.kind == .duplicateBindingName }
        XCTAssertEqual(dups.count, 1)
        XCTAssertEqual(dups.first?.bindingName, "twin")
    }

    /// Synthetic `binding-N` names from makeBinding's index fallback
    /// (rows with no explicit `name`) are exempt — they're unique by
    /// construction, and warning on them would produce false positives.
    func testSyntheticBindingNamesExemptFromDuplicateCheck() throws {
        let source = """
        [[bindings]]
        input = "f13"
        action-noop = true

        [[bindings]]
        input = "f14"
        action-noop = true

        [[bindings]]
        input = "f15"
        action-noop = true
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.config.bindings.count, 3)
        XCTAssertFalse(r.warnings.contains { $0.kind == .duplicateBindingName })
    }
}
