import Foundation
import Testing
@testable import ChordCore

/// Coverage for chord.bindings.v3 wire format (PR2).
@Suite struct SchemaTests {

    private func parseAndEncode(_ source: String) throws -> [String: Any] {
        try parseToBindingsJSON(source)
    }

    @Test func schemaIdentifierAndTopLevelShape() throws {
        let json = try parseAndEncode(
            """
            [[bindings]]
            name = "x"
            input = "f13"
            action-noop = true
            """)
        #expect(json["schema"] as? String == "chord.bindings.v3")
        #expect(json["generated_at"] != nil)
        #expect(json["options"] != nil)
        #expect(json["action_aliases"] != nil)
        #expect(json["bindings"] != nil)
        #expect(json["fallbacks"] != nil)
        #expect(json["dropped"] != nil)
    }

    /// #52-bounded: an unknown binding key surfaces in dropped[] with the
    /// stable kind "unknown-key" — and the binding still loads (lenient).
    @Test func unknownKeySurfacesInDropped() throws {
        let json = try parseAndEncode(
            """
            [[bindings]]
            name = "typo"
            input = "f13"
            action-noop = true
            bogus-key = 1
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        #expect(bindings.count == 1, "binding still loads")
        let dropped = try #require(json["dropped"] as? [[String: Any]])
        let unknown = dropped.filter { $0["kind"] as? String == "unknown-key" }
        #expect(unknown.count == 1)
        #expect(unknown[0]["section"] as? String == "[[bindings]]")
        #expect((unknown[0]["message"] as? String ?? "").contains("bogus-key"))
    }

    @Test func keyBindingShape() throws {
        let json = try parseAndEncode(
            """
            [[bindings]]
            name = "screenshot"
            input = "cmd + shift - 4"
            action-keys = "cmd + shift - 4"
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        #expect(bindings.count == 1)
        let b = bindings[0]
        #expect(b["name"] as? String == "screenshot")
        #expect(b["index"] as? Int == 0)
        #expect(b["source_line"] != nil)
        let input = try #require(b["input"] as? [String: Any])
        #expect(input["raw"] as? String == "cmd + shift - 4")
        #expect(input["fn"] as? Bool == false)
        let mods = try #require(input["modifiers"] as? [String])
        #expect(mods == ["cmd", "shift"])
        let sides = try #require(input["modifier_sides"] as? [String: String])
        #expect(sides["cmd"] == "any")
        #expect(sides["shift"] == "any")
        #expect(sides["opt"] == "absent")
        #expect(sides["ctrl"] == "absent")
        let trigger = try #require(input["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "key")
        #expect(trigger["name"] as? String == "4")
        #expect(trigger["keycode"] as? Int == 0x15)
        let action = try #require(b["action"] as? [String: Any])
        #expect(action["kind"] as? String == "keys")
        #expect(action["raw"] as? String == "cmd + shift - 4")
    }

    @Test func rightSideOnlyEmitsAbsentForOthers() throws {
        let json = try parseAndEncode(
            """
            [[bindings]]
            name = "ultra"
            input = "rctrl + ralt + rshift - c"
            action-noop = true
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        let b = bindings[0]
        let input = try #require(b["input"] as? [String: Any])
        let sides = try #require(input["modifier_sides"] as? [String: String])
        #expect(sides["ctrl"] == "right")
        #expect(sides["opt"] == "right")
        #expect(sides["shift"] == "right")
        #expect(sides["cmd"] == "absent")
    }

    @Test func anyKeyTrigger() throws {
        let json = try parseAndEncode(
            """
            [[fallbacks]]
            name = "any"
            input = "rctrl - *"
            action-shell = "true"
            """)
        let fallbacks = try #require(json["fallbacks"] as? [[String: Any]])
        let fb = fallbacks[0]
        let input = try #require(fb["input"] as? [String: Any])
        let trigger = try #require(input["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "anyKey")
        // Per chord.bindings.v3 schema: for the `anyKey` trigger
        // branch, `name` and `keycode` are absent (chord's
        // JSONEncoder omits nil-Optional fields). Consumers
        // treating absent and explicit-null equivalently (jq's
        // `.name` returns null for both) don't care which.
        #expect(trigger["name"] ?? nil == nil)
        #expect(trigger["keycode"] ?? nil == nil)
    }

    @Test func appsNullVsEmpty() throws {
        let json = try parseAndEncode(
            """
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
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        // Unscoped binding omits `apps`; scoped binding emits the
        // array. Test the contract: unscoped → absent, scoped →
        // present-array.
        #expect(bindings[0]["apps"] ?? nil == nil)
        #expect(bindings[1]["apps"] as? [String] == ["com.example.app"])
    }

    @Test func shellWithAliasExposesBothCommandAndAlias() throws {
        let json = try parseAndEncode(
            """
            [action-aliases]
            say_hi = "echo hi"

            [[bindings]]
            name = "aliased"
            input = "f13"
            action-shell = "@say_hi"
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        let b = bindings[0]
        let action = try #require(b["action"] as? [String: Any])
        #expect(action["kind"] as? String == "shell")
        #expect(action["command"] as? String == "echo hi")
        #expect(action["alias"] as? String == "say_hi")
        #expect(action["raw"] as? String == "@say_hi")
    }

    @Test func droppedCarriesStructuredKindAndLine() throws {
        let json = try parseAndEncode(
            """
            [[bindings]]
            name = "bad"
            input = "ctlr - a"
            action-shell = "true"
            """)
        let dropped = try #require(json["dropped"] as? [[String: Any]])
        #expect(dropped.count == 1)
        let d = dropped[0]
        #expect(d["kind"] as? String == "unknown-input-token")
        #expect(d["name"] as? String == "bad")
        #expect(d["section"] as? String == "[[bindings]]")
        #expect(d["source_line"] != nil)
    }

    // MARK: - validation block

    @Test func validationBlockAbsentWhenNotRequested() throws {
        let json = try parseToBindingsJSON(
            "[[bindings]]\nname=\"x\"\ninput=\"f13\"\naction-noop=true")
        #expect(json["validation"] ?? nil == nil)
    }

    @Test func validationBlockLenientPass() throws {
        // Lenient mode: a dropped binding doesn't fail (ok=true)
        let res = try Config.parse(
            """
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
        #expect(doc.validation != nil)
        #expect(doc.validation?.ok == true)
        #expect(doc.validation?.strict == false)
        #expect(doc.validation?.droppedCount == 1)
        #expect(doc.validation?.warningCount == 1)
        #expect(doc.validation?.parsedCounts.bindings == 1)
    }

    @Test func validationBlockStrictFails() throws {
        // Strict mode: any warning or drop → ok=false
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "ctlr - a"
            action-noop = true
            """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: true)
        #expect(doc.validation?.ok == false)
        #expect(doc.validation?.strict == true)
        #expect(doc.validation?.droppedCount == 1)
    }

    @Test func validationBlockStrictCleanPasses() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "ok"
            input = "f13"
            action-noop = true
            """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: true)
        #expect(doc.validation?.ok == true)
        #expect(doc.validation?.strict == true)
        #expect(doc.validation?.droppedCount == 0)
        #expect(doc.validation?.warningCount == 0)
    }

    @Test func validationUndefinedAliasCounted() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "needs alias"
            input = "f13"
            action-shell = "@nope"
            """)
        let doc = BindingsSchema.makeDocument(from: res, validationStrict: false)
        #expect(doc.validation?.undefinedActionAliases == 1)
    }

    @Test func stableSortedKeys() throws {
        // JSONEncoder uses .sortedKeys → top-level keys appear in
        // alphabetical order. Stable diffs / golden tests rely on
        // this; pin it.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "x"
            input = "f13"
            action-noop = true
            """)
        let data = try BindingsSchema.encodeJSON(
            BindingsSchema.makeDocument(from: res))
        let str = String(data: data, encoding: .utf8) ?? ""
        // "action_aliases" should come before "bindings" before "dropped".
        let iA = str.range(of: "\"action_aliases\"")!.lowerBound
        let iB = str.range(of: "\"bindings\"")!.lowerBound
        let iD = str.range(of: "\"dropped\"")!.lowerBound
        #expect(iA < iB)
        #expect(iB < iD)
    }
}
