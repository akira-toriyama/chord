import XCTest
@testable import ChordCore

/// chord 0.9.0+: `[action-aliases]` values may contain `{{1}}` `{{2}}`
/// placeholders, and bindings can call them as `@name(arg1, arg2, …)`.
/// The substitution is literal — the user is responsible for quoting
/// in the alias body (e.g. `afplay "{{1}}.wav"`).
final class ActionAliasArgsTests: XCTestCase {

    // MARK: - Basic substitution

    func testCallWithSingleArgSubstitutes() throws {
        let res = try Config.parse("""
        [action-aliases]
        play = 'afplay "$HOME/sounds/{{1}}.wav"'

        [[bindings]]
        name = "play undef"
        input = "cmd - x"
        action-shell = '@play("undefined")'
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .shell(let body) = b.action {
            XCTAssertEqual(body, "afplay \"$HOME/sounds/undefined.wav\"")
        } else { XCTFail("expected .shell") }
        // aliasName is recorded for --list --json round-trip.
        XCTAssertEqual(b.aliasName, "play")
    }

    func testCallWithMultipleArgs() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}} {{3}}'

        [[bindings]]
        name = "say three"
        input = "cmd - x"
        action-shell = '@say("hello", "kind", "world")'
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "echo hello kind world")
        } else { XCTFail("expected .shell") }
    }

    func testBareArgsAndQuotedArgsBothWork() throws {
        // `@name(unquoted, "quoted")` — both styles legal.
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}}'

        [[bindings]]
        name = "mix"
        input = "cmd - x"
        action-shell = '@say(plain, "with space")'
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "echo plain with space")
        } else { XCTFail("expected .shell") }
    }

    func testQuotedArgPreservesCommas() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}}'

        [[bindings]]
        name = "with-comma"
        input = "cmd - x"
        action-shell = '@say("a, b")'
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "echo a, b")
        } else { XCTFail("expected .shell") }
    }

    func testEmptyParensCallOnUnparameterizedAliasWorks() throws {
        // `@name()` against an alias with no {{N}} is just like `@name`.
        let res = try Config.parse("""
        [action-aliases]
        beep = 'afplay /System/Library/Sounds/Pop.aiff'

        [[bindings]]
        name = "beep-call"
        input = "cmd - x"
        action-shell = '@beep()'
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "afplay /System/Library/Sounds/Pop.aiff")
        } else { XCTFail("expected .shell") }
    }

    // MARK: - Backwards compatibility (bare @name)

    func testBareAliasStillWorks() throws {
        // Existing v0.6 / v0.7 syntax: bare `@name` with no parens.
        let res = try Config.parse("""
        [action-aliases]
        beep = 'afplay beep.wav'

        [[bindings]]
        name = "beep"
        input = "cmd - x"
        action-shell = "@beep"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "afplay beep.wav")
        } else { XCTFail("expected .shell") }
    }

    // MARK: - Error paths

    func testBareCallOnTemplatedAliasIsRejected() throws {
        // Alias body has {{1}} but the user called bare → reject.
        let res = try Config.parse("""
        [action-aliases]
        play = 'afplay "{{1}}.wav"'

        [[bindings]]
        name = "missing-args"
        input = "cmd - x"
        action-shell = "@play"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionAliasCallError &&
            $0.message.contains("{{1}}")
        })
    }

    func testTooFewArgsIsRejected() throws {
        let res = try Config.parse("""
        [action-aliases]
        say = 'echo {{1}} {{2}} {{3}}'

        [[bindings]]
        name = "short"
        input = "cmd - x"
        action-shell = '@say("a", "b")'
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionAliasCallError &&
            $0.message.contains("{{3}}")
        })
    }

    func testUndefinedAliasInCallFormIsRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "undef-call"
        input = "cmd - x"
        action-shell = '@missing("a")'
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .undefinedActionAlias &&
            $0.message.contains("@missing")
        })
    }

    func testUnclosedParensFallsThroughToLiteral() throws {
        // `@name(typo` (no closing paren) is treated as a literal
        // shell command rather than an error — protects users with
        // unusual shell syntax that happens to start with `@`.
        let res = try Config.parse("""
        [[bindings]]
        name = "literal"
        input = "cmd - x"
        action-shell = "@play(unclosed"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        // aliasName is nil because we fell through to literal.
        XCTAssertNil(res.config.bindings[0].aliasName)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "@play(unclosed")
        } else { XCTFail("expected .shell") }
    }

    // MARK: - Extras the substitution doesn't break

    func testExtraArgsBeyondPlaceholdersAreSilentlyDropped() throws {
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
        XCTAssertEqual(res.droppedBindings, 0)
        if case .shell(let body) = res.config.bindings[0].action {
            XCTAssertEqual(body, "echo hello")
        } else { XCTFail("expected .shell") }
    }
}
