import Testing
@testable import ChordCore

/// chord 0.9.0+: `[action-aliases]` values may contain `{{1}}` `{{2}}`
/// placeholders, and bindings can call them as `@name(arg1, arg2, …)`.
/// The substitution is literal — the user is responsible for quoting
/// in the alias body (e.g. `afplay "{{1}}.wav"`).
@Suite struct ActionAliasArgsTests {

    // MARK: - Basic substitution

    @Test func callWithSingleArgSubstitutes() throws {
        let res = try Config.parse("""
        [action-aliases]
        play = 'afplay "$HOME/sounds/{{1}}.wav"'

        [[bindings]]
        name = "play undef"
        input = "cmd - x"
        action-shell = '@play("undefined")'
        """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .shell(let body) = b.action {
            #expect(body == "afplay \"$HOME/sounds/undefined.wav\"")
        } else { Issue.record("expected .shell") }
        // aliasName is recorded for config --show --json round-trip.
        #expect(b.aliasName == "play")
    }

    @Test func callWithMultipleArgs() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}} {{3}}'

        [[bindings]]
        name = "say three"
        input = "cmd - x"
        action-shell = '@say("hello", "kind", "world")'
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "echo hello kind world")
        } else { Issue.record("expected .shell") }
    }

    @Test func bareArgsAndQuotedArgsBothWork() throws {
        // `@name(unquoted, "quoted")` — both styles legal.
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}}'

        [[bindings]]
        name = "mix"
        input = "cmd - x"
        action-shell = '@say(plain, "with space")'
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "echo plain with space")
        } else { Issue.record("expected .shell") }
    }

    @Test func quotedArgPreservesCommas() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}}'

        [[bindings]]
        name = "with-comma"
        input = "cmd - x"
        action-shell = '@say("a, b")'
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "echo a, b")
        } else { Issue.record("expected .shell") }
    }

    @Test func emptyParensCallOnUnparameterizedAliasWorks() throws {
        // `@name()` against an alias with no {{N}} is just like `@name`.
        let res = try Config.parse("""
        [action-aliases]
        beep = 'afplay /System/Library/Sounds/Pop.aiff'

        [[bindings]]
        name = "beep-call"
        input = "cmd - x"
        action-shell = '@beep()'
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "afplay /System/Library/Sounds/Pop.aiff")
        } else { Issue.record("expected .shell") }
    }

    // MARK: - Backwards compatibility (bare @name)

    @Test func bareAliasStillWorks() throws {
        // Existing v0.6 / v0.7 syntax: bare `@name` with no parens.
        let res = try Config.parse("""
        [action-aliases]
        beep = 'afplay beep.wav'

        [[bindings]]
        name = "beep"
        input = "cmd - x"
        action-shell = "@beep"
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "afplay beep.wav")
        } else { Issue.record("expected .shell") }
    }

    // MARK: - Error paths

    @Test func bareCallOnTemplatedAliasIsRejected() throws {
        // Alias body has {{1}} but the user called bare → reject.
        let res = try Config.parse("""
        [action-aliases]
        play = 'afplay "{{1}}.wav"'

        [[bindings]]
        name = "missing-args"
        input = "cmd - x"
        action-shell = "@play"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionAliasCallError &&
            $0.message.contains("{{1}}")
        })
    }

    @Test func tooFewArgsIsRejected() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}} {{3}}'

        [[bindings]]
        name = "short"
        input = "cmd - x"
        action-shell = '@say("a", "b")'
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .actionAliasCallError &&
            $0.message.contains("{{3}}")
        })
    }

    @Test func undefinedAliasInCallFormIsRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "undef-call"
        input = "cmd - x"
        action-shell = '@missing("a")'
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.kind == .undefinedActionAlias &&
            $0.message.contains("@missing")
        })
    }

    @Test func unclosedParensFallsThroughToLiteral() throws {
        // `@name(typo` (no closing paren) is treated as a literal
        // shell command rather than an error — protects users with
        // unusual shell syntax that happens to start with `@`.
        let res = try Config.parse("""
        [[bindings]]
        name = "literal"
        input = "cmd - x"
        action-shell = "@play(unclosed"
        """)
        #expect(res.droppedBindings == 0)
        // aliasName is nil because we fell through to literal.
        #expect(res.config.bindings[0].aliasName == nil)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "@play(unclosed")
        } else { Issue.record("expected .shell") }
    }

    // MARK: - Extras the substitution doesn't break

    @Test func extraArgsBeyondPlaceholdersAreSilentlyDropped() throws {
        // `@name(a, b)` with body using only {{1}} — `b` is unused.
        // Not an error (lets users be defensive about future args).
        let res = try Config.parse("""
        [action-aliases]
        only-one = 'echo {{1}}'

        [[bindings]]
        name = "extras"
        input = "cmd - x"
        action-shell = '@only-one("hello", "unused")'
        """)
        #expect(res.droppedBindings == 0)
        if case .shell(let body) = res.config.bindings[0].action {
            #expect(body == "echo hello")
        } else { Issue.record("expected .shell") }
    }
}
