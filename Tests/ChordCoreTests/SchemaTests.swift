import XCTest
@testable import ChordCore

/// Coverage for chord.bindings.v1 wire format (PR2).
final class SchemaTests: XCTestCase {

    private func parseAndEncode(_ source: String) throws -> [String: Any] {
        let res = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json
    }

    func testSchemaIdentifierAndTopLevelShape() throws {
        let json = try parseAndEncode("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        XCTAssertEqual(json["schema"] as? String, "chord.bindings.v1")
        XCTAssertNotNil(json["generated_at"])
        XCTAssertNotNil(json["options"])
        XCTAssertNotNil(json["aliases"])
        XCTAssertNotNil(json["bindings"])
        XCTAssertNotNil(json["fallbacks"])
        XCTAssertNotNil(json["dropped"])
    }

    func testKeyBindingShape() throws {
        let json = try parseAndEncode("""
        [[bindings]]
        name = "screenshot"
        input = "cmd + shift - 4"
        action-keys = "cmd + shift - 4"
        """)
        let bindings = json["bindings"] as! [[String: Any]]
        XCTAssertEqual(bindings.count, 1)
        let b = bindings[0]
        XCTAssertEqual(b["name"] as? String, "screenshot")
        XCTAssertEqual(b["index"] as? Int, 0)
        XCTAssertNotNil(b["source_line"])
        let input = b["input"] as! [String: Any]
        XCTAssertEqual(input["raw"] as? String, "cmd + shift - 4")
        XCTAssertEqual(input["fn"] as? Bool, false)
        let mods = input["modifiers"] as! [String]
        XCTAssertEqual(mods, ["cmd", "shift"])
        let sides = input["modifier_sides"] as! [String: String]
        XCTAssertEqual(sides["cmd"],  "any")
        XCTAssertEqual(sides["shift"], "any")
        XCTAssertEqual(sides["opt"],  "absent")
        XCTAssertEqual(sides["ctrl"], "absent")
        let trigger = input["trigger"] as! [String: Any]
        XCTAssertEqual(trigger["kind"] as? String, "key")
        XCTAssertEqual(trigger["name"] as? String, "4")
        XCTAssertEqual(trigger["keycode"] as? Int, 0x15)
        let action = b["action"] as! [String: Any]
        XCTAssertEqual(action["kind"] as? String, "keys")
        XCTAssertEqual(action["raw"] as? String, "cmd + shift - 4")
    }

    func testRightSideOnlyEmitsAbsentForOthers() throws {
        let json = try parseAndEncode("""
        [[bindings]]
        name = "ultra"
        input = "rctrl + ralt + rshift - c"
        action-noop = true
        """)
        let b = (json["bindings"] as! [[String: Any]])[0]
        let sides = ((b["input"] as! [String: Any])["modifier_sides"]) as! [String: String]
        XCTAssertEqual(sides["ctrl"],  "right")
        XCTAssertEqual(sides["opt"],   "right")
        XCTAssertEqual(sides["shift"], "right")
        XCTAssertEqual(sides["cmd"],   "absent")
    }

    func testAnyKeyTrigger() throws {
        let json = try parseAndEncode("""
        [[fallbacks]]
        name = "any"
        input = "rctrl - *"
        action-shell = "true"
        """)
        let fb = (json["fallbacks"] as! [[String: Any]])[0]
        let trigger = ((fb["input"] as! [String: Any])["trigger"]) as! [String: Any]
        XCTAssertEqual(trigger["kind"] as? String, "anyKey")
        // Per chord.bindings.v1 schema: for the `anyKey` trigger
        // branch, `name` and `keycode` are absent (chord's
        // JSONEncoder omits nil-Optional fields). Consumers
        // treating absent and explicit-null equivalently (jq's
        // `.name` returns null for both) don't care which.
        XCTAssertNil(trigger["name"] ?? nil)
        XCTAssertNil(trigger["keycode"] ?? nil)
    }

    func testAppsNullVsEmpty() throws {
        let json = try parseAndEncode("""
        [[bindings]]
        name = "unscoped"
        input = "f13"
        action-noop = true

        [[bindings]]
        name = "scoped"
        input = "f14"
        apps = ["com.example.app"]
        action-noop = true
        """)
        let bindings = json["bindings"] as! [[String: Any]]
        // Unscoped binding omits `apps`; scoped binding emits the
        // array. Test the contract: unscoped → absent, scoped →
        // present-array.
        XCTAssertNil(bindings[0]["apps"] ?? nil)
        XCTAssertEqual(bindings[1]["apps"] as? [String], ["com.example.app"])
    }

    func testShellWithAliasExposesBothCommandAndAlias() throws {
        let json = try parseAndEncode("""
        [aliases]
        say_hi = "echo hi"

        [[bindings]]
        name = "aliased"
        input = "f13"
        action-shell = "@say_hi"
        """)
        let b = (json["bindings"] as! [[String: Any]])[0]
        let action = b["action"] as! [String: Any]
        XCTAssertEqual(action["kind"] as? String, "shell")
        XCTAssertEqual(action["command"] as? String, "echo hi")
        XCTAssertEqual(action["alias"] as? String, "say_hi")
        XCTAssertEqual(action["raw"] as? String, "@say_hi")
    }

    func testDroppedCarriesStructuredKindAndLine() throws {
        let json = try parseAndEncode("""
        [[bindings]]
        name = "bad"
        input = "ctlr - a"
        action-shell = "true"
        """)
        let dropped = json["dropped"] as! [[String: Any]]
        XCTAssertEqual(dropped.count, 1)
        let d = dropped[0]
        XCTAssertEqual(d["kind"] as? String, "unknown-input-token")
        XCTAssertEqual(d["name"] as? String, "bad")
        XCTAssertEqual(d["section"] as? String, "[[bindings]]")
        XCTAssertNotNil(d["source_line"])
    }

    // MARK: - validation block

    func testValidationBlockAbsentWhenNotRequested() throws {
        let res = try Config.parse("[[bindings]]\nname=\"x\"\ninput=\"f13\"\naction-noop=true")
        let doc = BindingsSchema.makeDocument(from: res)  // no validation
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["validation"] ?? nil)
    }

    func testValidationBlockLenientPass() throws {
        // Lenient mode: a dropped binding doesn't fail (ok=true)
        let res = try Config.parse("""
        [[bindings]]
        name = "ok"
        input = "f13"
        action-noop = true

        [[bindings]]
        name = "bad"
        input = "ctlr - a"
        action-noop = true
        """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: false)
        XCTAssertNotNil(doc.validation)
        XCTAssertEqual(doc.validation?.ok, true)
        XCTAssertEqual(doc.validation?.strict, false)
        XCTAssertEqual(doc.validation?.droppedCount, 1)
        XCTAssertEqual(doc.validation?.warningCount, 1)
        XCTAssertEqual(doc.validation?.parsedCounts.bindings, 1)
    }

    func testValidationBlockStrictFails() throws {
        // Strict mode: any warning or drop → ok=false
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "ctlr - a"
        action-noop = true
        """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: true)
        XCTAssertEqual(doc.validation?.ok, false)
        XCTAssertEqual(doc.validation?.strict, true)
        XCTAssertEqual(doc.validation?.droppedCount, 1)
    }

    func testValidationBlockStrictCleanPasses() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "ok"
        input = "f13"
        action-noop = true
        """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: true)
        XCTAssertEqual(doc.validation?.ok, true)
        XCTAssertEqual(doc.validation?.strict, true)
        XCTAssertEqual(doc.validation?.droppedCount, 0)
        XCTAssertEqual(doc.validation?.warningCount, 0)
    }

    func testValidationUndefinedAliasCounted() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "needs alias"
        input = "f13"
        action-shell = "@nope"
        """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: false)
        XCTAssertEqual(doc.validation?.undefinedAliases, 1)
    }

    func testStableSortedKeys() throws {
        // JSONEncoder uses .sortedKeys → top-level keys appear in
        // alphabetical order. Stable diffs / golden tests rely on
        // this; pin it.
        let res = try Config.parse("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let data = try BindingsSchema.encodeJSON(
            BindingsSchema.makeDocument(from: res))
        let str = String(data: data, encoding: .utf8) ?? ""
        // "aliases" should come before "bindings" before "dropped".
        let iA = str.range(of: "\"aliases\"")!.lowerBound
        let iB = str.range(of: "\"bindings\"")!.lowerBound
        let iD = str.range(of: "\"dropped\"")!.lowerBound
        XCTAssertLessThan(iA, iB)
        XCTAssertLessThan(iB, iD)
    }
}
