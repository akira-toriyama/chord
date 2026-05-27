import XCTest
@testable import ChordCore

/// Coverage for `[action-aliases]` + `@name` expansion (PR4).
/// Resolution is strict: undefined `@name` drops the binding with a
/// warning carrying the source line + the undefined alias name.
final class AliasTests: XCTestCase {

    func testAliasExpansionInActionShell() throws {
        let res = try Config.parse("""
        [action-aliases]
        rift_focus_next = "rift-cli execute window next"

        [[bindings]]
        name = "rift focus next"
        input = "ctrl + alt + shift - f"
        action-shell = "@rift_focus_next"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.warnings.count, 0)
        XCTAssertEqual(res.config.actionAliases["rift_focus_next"],
                       "rift-cli execute window next")
        switch res.config.bindings[0].action {
        case .shell(let body):
            XCTAssertEqual(body, "rift-cli execute window next")
        default:
            XCTFail("expected expanded shell action")
        }
    }

    func testUndefinedAliasDropsBindingWithWarning() throws {
        let res = try Config.parse("""
        [action-aliases]
        defined_one = "echo yes"

        [[bindings]]
        name = "uses defined"
        input = "f13"
        action-shell = "@defined_one"

        [[bindings]]
        name = "uses undefined"
        input = "f14"
        action-shell = "@no_such_alias"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.config.bindings[0].name, "uses defined")
        XCTAssertEqual(res.droppedBindings, 1)
        // The canon-specified warning format: binding name +
        // (config.toml:LINE) + the alias name + "binding dropped".
        let w = res.warnings.first { $0.kind == .undefinedActionAlias }
        XCTAssertNotNil(w)
        if let warning = w {
            XCTAssertEqual(warning.bindingName, "uses undefined")
            XCTAssertTrue(warning.message.contains("'uses undefined'"),
                          "want binding name in warning: \(warning.message)")
            XCTAssertTrue(warning.message.contains("@no_such_alias"),
                          "want alias name in warning: \(warning.message)")
            XCTAssertTrue(warning.message.contains("binding dropped"),
                          "want explicit outcome in warning: \(warning.message)")
            XCTAssertTrue(warning.message.contains("config.toml:"),
                          "want source line tag: \(warning.message)")
            XCTAssertNotNil(warning.sourceLine,
                            "structured sourceLine should be populated")
        }
    }

    func testAliasOnlyAppliesToActionShell() throws {
        // `action-keys` is parsed by InputParser; `@name` would be
        // an unknown token and drop the binding via a different path.
        // We expect NO alias expansion to happen for action-keys.
        let res = try Config.parse("""
        [action-aliases]
        x = "left"

        [[bindings]]
        name = "no alias for keys"
        input = "f13"
        action-keys = "@x"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertEqual(res.droppedBindings, 1)
        // The drop reason is InputParser's unknown-token, NOT the
        // alias resolver. Make sure no "undefined alias" warning
        // leaks through that path.
        XCTAssertFalse(res.warnings.contains { $0.kind == .undefinedActionAlias })
    }

    func testLiteralAtSignPassesThrough() throws {
        // `@something with space` is reserved for a future
        // `@name arg` syntax; for now it's treated as a literal
        // command string (the user wrote it; we don't second-guess).
        let res = try Config.parse("""
        [[bindings]]
        name = "literal at-sign"
        input = "f13"
        action-shell = "@something with arg"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        switch res.config.bindings[0].action {
        case .shell(let body):
            XCTAssertEqual(body, "@something with arg")
        default:
            XCTFail("expected literal shell action")
        }
    }

    func testNonStringAliasValueIgnored() throws {
        let res = try Config.parse("""
        [action-aliases]
        good = "echo yes"
        bad = 42
        """)
        XCTAssertEqual(res.config.actionAliases, ["good": "echo yes"])
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionAliasNonString && $0.message.contains("'bad'")
        })
    }
}
