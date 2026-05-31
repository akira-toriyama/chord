import XCTest
@testable import ChordCore

/// chord 0.9.0+: per-binding `repeat = fire-each | ignore | passthrough`
/// controls how the binding reacts to macOS typematic autorepeat
/// events. Default `.fireEach` preserves pre-0.9.0 behaviour
/// (every repeat invokes the action).
final class AutorepeatTests: XCTestCase {

    // MARK: - Parse

    func testRepeatDefaultsToFireEach() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo"
        """)
        XCTAssertEqual(res.config.bindings[0].repeatStrategy, .fireEach)
    }

    func testParseAllThreeStrategies() throws {
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
            XCTAssertEqual(res.config.bindings[0].repeatStrategy, expected,
                           "repeat=\"\(raw)\" should parse to \(expected)")
        }
    }

    func testInvalidRepeatStrategyDropsBinding() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - x"
        action-shell = "echo"
        repeat = "yolo"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.message.contains("yolo")
        })
    }

    // MARK: - Event flow / autorepeat flag

    func testInputEventCarriesIsRepeat() {
        // Constructor exposes the new field with default false.
        let plain = InputEvent(trigger: .key(0x00), modifiers: [],
                               frontmostBundleID: nil)
        XCTAssertFalse(plain.isRepeat)

        let rep = InputEvent(trigger: .key(0x00), modifiers: [],
                             frontmostBundleID: nil,
                             kind: .down,
                             isSynthetic: false,
                             isRepeat: true)
        XCTAssertTrue(rep.isRepeat)
    }

    // MARK: - Schema round-trip

    func testSchemaOmitsRepeatWhenDefault() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-shell = "echo"
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        XCTAssertNil(b["repeat"],
                     "default fire-each is omitted from JSON")
    }

    func testSchemaEmitsRepeatWhenSet() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "noisy"
        input = "cmd - x"
        action-shell = "echo"
        repeat = "ignore"
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let b = (json["bindings"] as! [[String: Any]])[0]
        XCTAssertEqual(b["repeat"] as? String, "ignore")
    }
}
