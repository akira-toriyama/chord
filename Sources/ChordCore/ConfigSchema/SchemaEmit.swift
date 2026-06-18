// SchemaEmit.swift — lower the ChordConfigSchema descriptor to a Draft-07
// JSON Schema string for taplo editor completion (`chord config --emit-schema`).
//
// Deterministic: built with `JSONSerialization [.sortedKeys, .prettyPrinted]`
// so a freshly emitted string is byte-stable across runs/platforms — the CI
// drift guard (committed config.schema.json == emitted) relies on this.
//
// This is the config.toml INPUT schema. It is NOT chord.bindings.v3.json
// (the parse-OUTPUT wire format in Schema.swift / docs/schema/).

import Foundation

public extension ChordConfigSchema {
    /// The emitted Draft-07 JSON Schema for config.toml (no trailing newline,
    /// matching the sibling apps' `--emit-schema`).
    static var jsonSchema: String {
        var root: [String: Any] = [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "$comment": "chord config.toml INPUT schema (editor completion). "
                + "Regenerate: `chord config --emit-schema > config.schema.json`. "
                + "NOT chord.bindings.v3.json (the parse-OUTPUT wire format).",
            "title": title,
            "type": "object",
            "additionalProperties": false,
        ]
        var props: [String: Any] = [:]
        for section in sections {
            props[section.name] = emitSection(section)
        }
        root["properties"] = props
        return serialize(root)
    }

    // MARK: - lowering

    private static func emitSection(_ s: SchemaSection) -> [String: Any] {
        switch s.kind {
        case .table(let shape):
            return emitObject(shape, sectionDoc: s.doc)
        case .openStringMap(let valueDoc):
            return [
                "type": "object",
                "description": s.doc,
                "additionalProperties": ["type": "string", "description": valueDoc],
            ]
        case .openIntMap(let valueDoc, let min, let max):
            return [
                "type": "object",
                "description": s.doc,
                "additionalProperties": ["type": "integer", "description": valueDoc,
                                         "minimum": min, "maximum": max],
            ]
        case .arrayOfTables(let shape):
            return [
                "type": "array",
                "description": s.doc,
                "items": emitObject(shape, sectionDoc: shape.doc),
            ]
        }
    }

    private static func emitObject(_ shape: ObjectShape, sectionDoc: String) -> [String: Any] {
        var obj: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
        ]
        if !sectionDoc.isEmpty { obj["description"] = sectionDoc }

        var props: [String: Any] = [:]
        // `rejected` fields are parser-recognised-to-reject, not schema-valid;
        // omit them so `additionalProperties: false` keeps rejecting them.
        for f in shape.fields where !f.rejected { props[f.key] = emitField(f) }
        for n in shape.nested {
            var arr: [String: Any] = ["type": "array", "items": emitObject(n.item, sectionDoc: n.item.doc)]
            if n.nonEmpty { arr["minItems"] = 1 }
            props[n.key] = arr
        }
        obj["properties"] = props

        if !shape.required.isEmpty { obj["required"] = shape.required }

        // dependency rules → Draft-07 `dependencies`
        var deps: [String: Any] = [:]
        for rule in shape.exclusions {
            if case .dependency(let key, let needs) = rule { deps[key] = [needs] }
        }
        if !deps.isEmpty { obj["dependencies"] = deps }

        // anyOf / oneOf / not rules → `allOf` of small clauses
        var allOf: [[String: Any]] = []
        for rule in shape.exclusions {
            switch rule {
            case .anyOfRequired(let keys):
                allOf.append(["anyOf": keys.map { ["required": [$0]] }])
            case .oneOfRequired(let keys):
                allOf.append(["oneOf": keys.map { ["required": [$0]] }])
            case .forbidsTogether(let keys):
                allOf.append(["not": ["required": keys]])
            case .dependency:
                break // handled above
            }
        }
        if !allOf.isEmpty { obj["allOf"] = allOf }

        return obj
    }

    private static func emitField(_ f: SchemaField) -> [String: Any] {
        var out: [String: Any] = [:]
        switch f.shape {
        case .string:
            out["type"] = "string"
        case .integer:
            out["type"] = "integer"
        case .boolean:
            out["type"] = "boolean"
        case .stringOrStringArray:
            out["oneOf"] = [["type": "string"], ["type": "array", "items": ["type": "string"]]]
        case .stringArray:
            out["type"] = "array"
            out["items"] = ["type": "string"]
        case .constTrue:
            out["const"] = true
        case .intMap:
            out["type"] = "object"
            out["additionalProperties"] = ["type": "integer"]
            out["minProperties"] = 1
        case .stringMap:
            out["type"] = "object"
            out["additionalProperties"] = ["type": "string"]
        }
        if let e = f.enumDomain { out["enum"] = e }
        if let d = f.defaultBool { out["default"] = d }
        if let d = f.defaultInt { out["default"] = d }
        if let m = f.exclusiveMinimum { out["exclusiveMinimum"] = m }
        if !f.doc.isEmpty { out["description"] = f.doc }
        if let ex = f.examples { out["examples"] = ex }
        return out
    }

    private static func serialize(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
