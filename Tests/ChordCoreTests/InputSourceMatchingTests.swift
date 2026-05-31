import XCTest
@testable import ChordCore

/// chord 0.9.0+: `input-source = "..."` gates a binding on the macOS
/// current keyboard input source id. Glob semantics mirror `apps`
/// (allow / `!`-deny / `*` wildcard).
final class InputSourceMatchingTests: XCTestCase {

    // MARK: - Parse

    func testInputSourceArrayParses() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "us-only"
        input = "cmd - x"
        action-noop = true
        input-source = ["com.apple.keylayout.US"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings[0].inputSource,
                       ["com.apple.keylayout.US"])
    }

    func testInputSourceStringIsSugarForOneArray() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "single"
        input = "cmd - x"
        action-noop = true
        input-source = "com.apple.keylayout.US"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings[0].inputSource,
                       ["com.apple.keylayout.US"])
    }

    func testEmptyOrWildcardCollapsesToNil() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "anywhere"
        input = "cmd - x"
        action-noop = true
        input-source = ["*"]
        """)
        XCTAssertNil(res.config.bindings[0].inputSource)
    }

    // MARK: - Matcher semantics (allow / deny / glob)

    func testAllowlistMatchesExactID() {
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["com.apple.keylayout.US"])
        let m = Matcher(bindings: [b])
        // Matching source → fires.
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd],
                               bundleID: nil,
                               inputSourceID: "com.apple.keylayout.US"))
        XCTAssertNotNil(hit)
        // Different source → miss.
        let miss = m.find(.init(trigger: .key(0x07),
                                modifiers: [.lcmd],
                                bundleID: nil,
                                inputSourceID:
                                    "com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertNil(miss)
    }

    func testDenyPrefixExcludes() {
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
        XCTAssertNotNil(usHit)
        // Japanese IME → excluded.
        let jaMiss = m.find(.init(trigger: .key(0x07),
                                  modifiers: [.lcmd],
                                  bundleID: nil,
                                  inputSourceID:
                                      "com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertNil(jaMiss)
    }

    func testGlobWildcardWorks() {
        let b = Binding(name: "t", trigger: .key(0x07),
                        modifiers: [.cmd], apps: nil, action: .noop,
                        inputSource: ["com.apple.inputmethod.Kotoeri.*"])
        let m = Matcher(bindings: [b])
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd],
                               bundleID: nil,
                               inputSourceID:
                                   "com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertNotNil(hit)
    }

    func testUnknownInputSourceDropsAllowOnlyBinding() {
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
        XCTAssertNil(miss)
    }

    func testBindingWithoutInputSourceIgnoresEvent() {
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
        XCTAssertNotNil(hit)
    }

    // MARK: - Schema

    func testSchemaEmitsInputSource() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "us"
        input = "cmd - x"
        action-noop = true
        input-source = ["com.apple.keylayout.US", "!com.apple.inputmethod.Kotoeri.*"]
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        let src = b["input_source"] as! [String]
        XCTAssertEqual(src, ["com.apple.keylayout.US",
                             "!com.apple.inputmethod.Kotoeri.*"])
    }

    func testSchemaOmitsInputSourceWhenAbsent() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-noop = true
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        XCTAssertNil(b["input_source"])
    }
}
