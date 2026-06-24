import Foundation
import Testing
@testable import ChordCore

/// Deterministic lockstep guard for the `chord config --show / --validate
/// --json` wire contract. Builds a document that exercises every
/// "younger" wire feature — `passthrough` / `repeat` / `input_source` /
/// `toggle-variable` action / multi-var `kind:"all"` condition / `vkey`
/// trigger — through the *real* ChordCore emit path, then validates the
/// emitted JSON against the committed `docs/schema/chord.bindings.v3.json`
/// with a small Foundation-only structural checker (NO external
/// JSON-Schema library).
///
/// Why this exists: #45/#46/#47 shipped new wire fields without updating
/// the published schema, so the emitter's own output failed its own
/// contract under strict (`additionalProperties:false`) validation. The
/// lockstep was honor-system (a doc comment in Schema.swift). This test
/// makes the drift fatal: add a wire field and forget the schema, and CI
/// dies right here.
///
/// The checker enforces exactly the JSON-Schema subset the contract leans
/// on: `$ref` resolution, `oneOf` (exactly-one matching branch),
/// `additionalProperties:false` (emitted keys ⊆ declared properties — the
/// check that catches a forgotten field), `required`, and `const`/`enum`.
/// Value formats and numeric bounds are intentionally NOT enforced — this
/// is a key/shape conformance guard, matching the ledger's "全キー/kind を
/// 照合" scope. `ConfigSchemaDriftTests` is the on-disk-read precedent.
@Suite struct WireSchemaValidationTests {

    /// A single config whose emitted document touches every wire shape the
    /// published schema must describe. Kept to one feature per binding so
    /// no row is over-constrained (and a dropped row trips the presence
    /// asserts below rather than silently shrinking coverage).
    private static let kitchenSink = """
    [v-key-aliases]
    TU_LL_C = 0x26

    [[bindings]]
    name = "wire-shell-passthrough"
    input = "cmd - x"
    action-shell = "echo hi"
    passthrough = true
    repeat = "ignore"
    input-source = ["com.apple.keylayout.US", "!com.apple.inputmethod.Kotoeri.*"]

    [[bindings]]
    name = "wire-toggle"
    input = "cmd - y"
    action-toggle-var = "wm"

    [[bindings]]
    name = "wire-multigate"
    input = "cmd - z"
    when-vars = { a = 1, b = 2 }
    action-noop = true

    [[bindings]]
    name = "wire-vkey"
    input = "TU_LL_C"
    action-noop = true
    """

    // MARK: - the lockstep test

    @Test func emittedWireDocumentConformsToPublishedSchema() throws {
        // 1. Emit through the real wire path (parse → makeDocument →
        //    encodeJSON → JSONSerialization), the same chain every other
        //    wire-shape test uses.
        let doc = try parseToBindingsJSON(Self.kitchenSink)

        // 2. Guard: the document must actually carry every younger feature,
        //    so the conformance check below can't pass vacuously if the
        //    emitter silently stops producing one of them.
        try assertCoversYoungerFeatures(doc)

        // 3. Validate the whole document against the committed schema.
        let schema = try loadPublishedSchema()
        let validator = StructuralSchemaValidator(root: schema)
        do {
            try validator.validate(node: doc, schema: schema, path: "$")
        } catch let v as StructuralSchemaValidator.Violation {
            Issue.record("""
            Emitted wire JSON violates docs/schema/chord.bindings.v3.json — \
            the emitter shipped a field the published schema does not \
            describe (the #45/#46/#47 drift class). \
            \(v.path): \(v.reason)
            """)
        }
    }

    // MARK: - feature-presence guard

    /// Asserts the emitted document contains each wire shape the schema
    /// fix is about. A failure here means the *emitter* regressed (stopped
    /// producing the feature), which would otherwise let the conformance
    /// check pass without testing anything.
    private func assertCoversYoungerFeatures(_ doc: [String: Any]) throws {
        let bindings = try #require(doc["bindings"] as? [[String: Any]],
                                    "no bindings[] in emitted document")
        let byName = Dictionary(
            uniqueKeysWithValues: bindings.compactMap { b -> (String, [String: Any])? in
                (b["name"] as? String).map { ($0, b) }
            })

        // passthrough + repeat + input_source on one binding object.
        let shell = try #require(byName["wire-shell-passthrough"],
                                 "passthrough binding was dropped")
        #expect(shell["passthrough"] as? Bool == true)
        #expect(shell["repeat"] as? String == "ignore")
        #expect(shell["input_source"] as? [String] ==
                ["com.apple.keylayout.US", "!com.apple.inputmethod.Kotoeri.*"])

        // action kind "toggle-variable".
        let toggle = try #require(byName["wire-toggle"],
                                  "toggle binding was dropped")
        let toggleAction = try #require(toggle["action"] as? [String: Any])
        #expect(toggleAction["kind"] as? String == "toggle-variable")

        // condition kind "all" with two nested conditions.
        let gate = try #require(byName["wire-multigate"],
                                "multi-gate binding was dropped")
        let cond = try #require(gate["condition"] as? [String: Any])
        #expect(cond["kind"] as? String == "all")
        #expect((cond["conditions"] as? [[String: Any]])?.count == 2)

        // trigger kind "vkey".
        let vkey = try #require(byName["wire-vkey"], "vkey binding was dropped")
        let trigger = try #require(
            (vkey["input"] as? [String: Any])?["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "vkey")

        // The whole config must parse clean — a stray warning would add a
        // dropped[] row and muddy the conformance walk.
        #expect((doc["dropped"] as? [Any])?.count == 0,
                "kitchen-sink config produced unexpected warnings")
    }

    // MARK: - schema loading

    /// Reads the committed wire schema from the repo (not a bundled
    /// resource — same `#filePath`-relative walk as ConfigSchemaDriftTests).
    private func loadPublishedSchema() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ChordCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("docs/schema/chord.bindings.v3.json")
        let data = try Data(contentsOf: url)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "docs/schema/chord.bindings.v3.json is not a JSON object")
    }
}

/// Minimal structural validator for the JSON-Schema subset the chord wire
/// contract uses. Foundation-only by design (the ledger forbids pulling a
/// full JSON-Schema dependency into a stdlib/Foundation-only project).
///
/// Enforced: `$ref` (local `#/$defs/*`), `oneOf` (exactly one branch must
/// validate), object `required`, object `additionalProperties:false`
/// (every emitted key must be a declared property — the forgotten-field
/// catch), `const`, `enum`, and recursion through `properties` / `items`.
/// Deliberately ignores numeric bounds, `format`, and scalar `type` —
/// this checks shape and discriminators, not value validity.
struct StructuralSchemaValidator {
    struct Violation: Error {
        let path: String
        let reason: String
    }

    let root: [String: Any]
    private var defs: [String: Any] { root["$defs"] as? [String: Any] ?? [:] }

    func validate(node: Any, schema: [String: Any], path: String) throws {
        // $ref — resolve and validate against the target def. Sibling
        // keywords (e.g. `description`) on a $ref node are non-constraining
        // for our subset, so we ignore them.
        if let ref = schema["$ref"] as? String {
            try validate(node: node, schema: try resolve(ref, at: path), path: path)
            return
        }

        // oneOf — exactly one branch must validate.
        if let branches = schema["oneOf"] as? [[String: Any]] {
            try validateOneOf(node: node, branches: branches, path: path)
            return
        }

        // const / enum — leaf discriminators (always strings in this schema).
        if let c = schema["const"] {
            guard stringsEqual(node, c) else {
                throw Violation(path: path,
                                reason: "const mismatch: expected \(c), got \(node)")
            }
            return
        }
        if let e = schema["enum"] as? [Any] {
            let allowed = e.compactMap { $0 as? String }
            guard let s = node as? String, allowed.contains(s) else {
                throw Violation(path: path,
                                reason: "enum mismatch: \(node) not in \(allowed)")
            }
            return
        }

        // object — required + additionalProperties + recurse into properties.
        if isObjectSchema(schema) {
            try validateObject(node: node, schema: schema, path: path)
            return
        }

        // array — recurse into items.
        if isArraySchema(schema) {
            try validateArray(node: node, schema: schema, path: path)
            return
        }

        // scalar (string / integer / boolean / number) — shape-only guard,
        // value validity is out of scope.
    }

    // MARK: -

    private func validateOneOf(node: Any, branches: [[String: Any]],
                               path: String) throws {
        var matched = 0
        var reasons: [String] = []
        for (i, branch) in branches.enumerated() {
            do {
                try validate(node: node, schema: branch, path: "\(path)|oneOf[\(i)]")
                matched += 1
            } catch let v as Violation {
                reasons.append("  branch[\(i)]: \(v.reason)")
            }
        }
        if matched == 1 { return }
        if matched == 0 {
            throw Violation(
                path: path,
                reason: "matched no oneOf branch:\n" + reasons.joined(separator: "\n"))
        }
        throw Violation(path: path,
                        reason: "ambiguous: matched \(matched) oneOf branches")
    }

    private func validateObject(node: Any, schema: [String: Any],
                                path: String) throws {
        guard let obj = node as? [String: Any] else {
            throw Violation(path: path, reason: "expected object, got \(type(of: node))")
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]

        if let required = schema["required"] as? [Any] {
            for case let key as String in required where obj[key] == nil {
                throw Violation(path: path, reason: "missing required property '\(key)'")
            }
        }

        // additionalProperties:false ⇒ every emitted key must be declared.
        // This is the check that fails when the emitter ships a field the
        // schema forgot.
        if (schema["additionalProperties"] as? Bool) == false {
            for key in obj.keys where properties[key] == nil {
                throw Violation(
                    path: "\(path).\(key)",
                    reason: "property not declared in schema "
                        + "(additionalProperties:false)")
            }
        }

        for (key, value) in obj {
            if let sub = properties[key] as? [String: Any] {
                try validate(node: value, schema: sub, path: "\(path).\(key)")
            }
        }
    }

    private func validateArray(node: Any, schema: [String: Any],
                               path: String) throws {
        guard let arr = node as? [Any] else {
            throw Violation(path: path, reason: "expected array, got \(type(of: node))")
        }
        guard let items = schema["items"] as? [String: Any] else { return }
        for (i, element) in arr.enumerated() {
            try validate(node: element, schema: items, path: "\(path)[\(i)]")
        }
    }

    private func resolve(_ ref: String, at path: String) throws -> [String: Any] {
        let prefix = "#/$defs/"
        guard ref.hasPrefix(prefix) else {
            throw Violation(path: path, reason: "unsupported $ref '\(ref)'")
        }
        let name = String(ref.dropFirst(prefix.count))
        guard let def = defs[name] as? [String: Any] else {
            throw Violation(path: path, reason: "unresolved $ref '\(ref)'")
        }
        return def
    }

    private func isObjectSchema(_ schema: [String: Any]) -> Bool {
        if (schema["type"] as? String) == "object" { return true }
        return schema["properties"] != nil
            || schema["required"] != nil
            || schema["additionalProperties"] != nil
    }

    private func isArraySchema(_ schema: [String: Any]) -> Bool {
        (schema["type"] as? String) == "array" || schema["items"] != nil
    }

    /// String-only const compare (every `const` in the wire schema is a
    /// discriminator string). NSNumber/bool consts aren't used here.
    private func stringsEqual(_ node: Any, _ expected: Any) -> Bool {
        guard let a = node as? String, let b = expected as? String else { return false }
        return a == b
    }
}
