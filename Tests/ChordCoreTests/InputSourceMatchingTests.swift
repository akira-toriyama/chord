import Testing
@testable import ChordCore

/// chord 0.9.0+: `input-source = "..."` gates a binding on the macOS
/// current keyboard input source id. Glob semantics mirror `apps`
/// (allow / `!`-deny / `*` wildcard).
@Suite struct InputSourceMatchingTests {

    // MARK: - Parse

    @Test func inputSourceArrayParses() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "us-only"
        input = "cmd - x"
        action-noop = true
        input-source = ["com.apple.keylayout.US"]
        """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings[0].inputSource ==
                       ["com.apple.keylayout.US"])
    }

    @Test func inputSourceStringIsSugarForOneArray() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        action-noop = true
        input-source = "com.apple.keylayout.US"
        """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings[0].inputSource ==
                       ["com.apple.keylayout.US"])
    }

    @Test func emptyOrWildcardCollapsesToNil() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "anywhere"
        input = "cmd - x"
        action-noop = true
        input-source = ["*"]
        """)
        #expect(res.config.bindings[0].inputSource == nil)
    }

    // MARK: - Matcher semantics (allow / deny / glob)

    @Test func allowlistMatchesExactID() {
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["com.apple.keylayout.US"])
        let m = Matcher(bindings: [b])
        // Matching source → fires.
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd],
                               bundleID: nil,
                               inputSourceID: "com.apple.keylayout.US"))
        #expect(hit != nil)
        // Different source → miss.
        let miss = m.find(.init(trigger: .key(0x07),
                                modifiers: [.lcmd],
                                bundleID: nil,
                                inputSourceID:
                                    "com.apple.inputmethod.Kotoeri.Japanese"))
        #expect(miss == nil)
    }

    @Test func denyPrefixExcludes() {
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["!com.apple.inputmethod.Kotoeri.*"])
        let m = Matcher(bindings: [b])
        // Not Japanese IME → fires (deny-only list passes when no
        // exclusion hits).
        let usHit = m.find(.init(trigger: .key(0x07),
                                 modifiers: [.lcmd],
                                 bundleID: nil,
                                 inputSourceID: "com.apple.keylayout.US"))
        #expect(usHit != nil)
        // Japanese IME → excluded.
        let jaMiss = m.find(.init(trigger: .key(0x07),
                                  modifiers: [.lcmd],
                                  bundleID: nil,
                                  inputSourceID:
                                      "com.apple.inputmethod.Kotoeri.Japanese"))
        #expect(jaMiss == nil)
    }

    @Test func globWildcardWorks() {
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["com.apple.inputmethod.Kotoeri.*"])
        let m = Matcher(bindings: [b])
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd],
                               bundleID: nil,
                               inputSourceID:
                                   "com.apple.inputmethod.Kotoeri.Japanese"))
        #expect(hit != nil)
    }

    @Test func unknownInputSourceDropsAllowOnlyBinding() {
        // When `inputSource` is set and the event has no source id
        // (tracker pre-start), the allowlist check fails closed.
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["com.apple.keylayout.US"])
        let m = Matcher(bindings: [b])
        let miss = m.find(.init(trigger: .key(0x07),
                                modifiers: [.lcmd],
                                bundleID: nil,
                                inputSourceID: nil))
        #expect(miss == nil)
    }

    @Test func bindingWithoutInputSourceIgnoresEvent() {
        // Regression: a binding without `input-source` still fires
        // regardless of the event's source id.
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop)
        let m = Matcher(bindings: [b])
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd],
                               bundleID: nil,
                               inputSourceID:
                                   "com.apple.inputmethod.Kotoeri.Japanese"))
        #expect(hit != nil)
    }

    // MARK: - Schema

    @Test func schemaEmitsInputSource() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "us"
        input = "cmd - x"
        action-noop = true
        input-source = ["com.apple.keylayout.US", "!com.apple.inputmethod.Kotoeri.*"]
        """)
        let src = try #require(b["input_source"] as? [String])
        #expect(src == ["com.apple.keylayout.US",
                             "!com.apple.inputmethod.Kotoeri.*"])
    }

    @Test func schemaOmitsInputSourceWhenAbsent() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-noop = true
        """)
        #expect(b["input_source"] == nil)
    }
}
