import Testing
@testable import ChordCore

/// Coverage for `[action-aliases]` + `@name` expansion (PR4).
/// Resolution is strict: undefined `@name` drops the binding with a
/// warning carrying the source line + the undefined alias name.
@Suite struct AliasTests {

    @Test func aliasExpansionInActionShell() throws {
        let res = try Config.parse("""
        [action-aliases]
        rift_focus_next = "rift-cli execute window next"

        [[bindings]]
        name = "rift focus next"
        input = "ctrl + alt + shift - f"
        action-shell = "@rift_focus_next"
        """)
        #expect(res.config.bindings.count == 1)
        #expect(res.droppedBindings == 0)
        #expect(res.warnings.count == 0)
        #expect(res.config.actionAliases["rift_focus_next"] ==
                       "rift-cli execute window next")
        switch res.config.bindings[0].action {
        case .shell(let body):
            #expect(body == "rift-cli execute window next")
        default:
            Issue.record("expected expanded shell action")
        }
    }

    @Test func undefinedAliasDropsBindingWithWarning() throws {
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
        #expect(res.config.bindings.count == 1)
        #expect(res.config.bindings[0].name == "uses defined")
        #expect(res.droppedBindings == 1)
        // The canon-specified warning format: binding name +
        // (config.toml:LINE) + the alias name + "binding dropped".
        let w = res.warnings.first { $0.kind == .undefinedActionAlias }
        #expect(w != nil)
        if let warning = w {
            #expect(warning.bindingName == "uses undefined")
            #expect(warning.message.contains("'uses undefined'"),
                          "want binding name in warning: \(warning.message)")
            #expect(warning.message.contains("@no_such_alias"),
                          "want alias name in warning: \(warning.message)")
            #expect(warning.message.contains("binding dropped"),
                          "want explicit outcome in warning: \(warning.message)")
            #expect(warning.message.contains("config.toml:"),
                          "want source line tag: \(warning.message)")
            #expect(warning.sourceLine != nil,
                            "structured sourceLine should be populated")
        }
    }

    @Test func aliasOnlyAppliesToActionShell() throws {
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
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings == 1)
        // The drop reason is InputParser's unknown-token, NOT the
        // alias resolver. Make sure no "undefined alias" warning
        // leaks through that path.
        #expect(!res.warnings.contains { $0.kind == .undefinedActionAlias })
    }

    @Test func literalAtSignPassesThrough() throws {
        // `@something with space` is reserved for a future
        // `@name arg` syntax; for now it's treated as a literal
        // command string (the user wrote it; we don't second-guess).
        let res = try Config.parse("""
        [[bindings]]
        name = "literal at-sign"
        input = "f13"
        action-shell = "@something with arg"
        """)
        #expect(res.config.bindings.count == 1)
        switch res.config.bindings[0].action {
        case .shell(let body):
            #expect(body == "@something with arg")
        default:
            Issue.record("expected literal shell action")
        }
    }

    @Test func nonStringAliasValueIgnored() throws {
        let res = try Config.parse("""
        [action-aliases]
        good = "echo yes"
        bad = 42
        """)
        #expect(res.config.actionAliases == ["good": "echo yes"])
        #expect(res.warnings.contains {
            $0.kind == .actionAliasNonString && $0.message.contains("'bad'")
        })
    }
}
