import Testing
@testable import ChordCore

/// chord 0.9.0+: per-binding `repeat = fire-each | ignore | passthrough`
/// controls how the binding reacts to macOS typematic autorepeat
/// events. Default `.fireEach` preserves pre-0.9.0 behaviour
/// (every repeat invokes the action).
@Suite struct AutorepeatTests {

    // MARK: - Parse

    @Test func repeatDefaultsToFireEach() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo"
        """)
        #expect(res.config.bindings[0].repeatStrategy == .fireEach)
    }

    @Test func parseAllThreeStrategies() throws {
        let cases: [(String, RepeatStrategy)] = [
            ("fire-each", .fireEach),
            ("ignore", .ignore),
            ("passthrough", .passthrough),
        ]
        for (raw, expected) in cases {
            let res = try Config.parse("""
            [[bindings]]
            name = "r"
            input = "cmd - x"
            action-shell = "echo"
            repeat = "\(raw)"
            """)
            #expect(res.config.bindings[0].repeatStrategy == expected,
                    "repeat=\"\(raw)\" should parse to \(expected)")
        }
    }

    @Test func invalidRepeatStrategyDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-shell = "echo"
        repeat = "yolo"
        """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains {
            $0.message.contains("yolo")
        })
    }

    // MARK: - Event flow / autorepeat flag

    @Test func inputEventCarriesIsRepeat() {
        // Constructor exposes the new field with default false.
        let plain = InputEvent(trigger: .key(0x00), modifiers: [],
                               frontmostBundleID: nil)
        #expect(!plain.isRepeat)

        let rep = InputEvent(trigger: .key(0x00), modifiers: [],
                             frontmostBundleID: nil,
                             kind: .down,
                             isSynthetic: false,
                             isRepeat: true)
        #expect(rep.isRepeat)
    }

    // MARK: - Schema round-trip

    @Test func schemaOmitsRepeatWhenDefault() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo"
        """)
        #expect(b["repeat"] == nil,
                "default fire-each is omitted from JSON")
    }

    @Test func schemaEmitsRepeatWhenSet() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "noisy"
        input = "cmd - x"
        action-shell = "echo"
        repeat = "ignore"
        """)
        #expect(b["repeat"] as? String == "ignore")
    }
}
