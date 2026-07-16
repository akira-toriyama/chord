// StructuralCheck.swift — #52-bounded: the parser's descriptor-driven
// unknown-key validation for the array-of-tables sections.
//
// The SAME ChordConfigSchema descriptor that emits the config.toml JSON
// Schema (#78, SchemaEmit.swift) is the single source of the key inventory
// here, so the editor-completion schema and the parser's structural check
// can never drift: a key added to a shape's `fields` lands in both. Only
// the *structure* (which keys a section accepts) is descriptor-driven; the
// hand-written leaf DSL parsing (InputParser / ActionParser / alias
// resolution) is untouched (#52's full parser-unification stays iceboxed).
//
// [options] is validated inline in Config.parse against optionsShape().keySet
// (kind .unknownOptionKey, preserved). Open string maps ([action-aliases] /
// [input-aliases]) accept any key by design and are not checked here.

import Foundation
import ConfigSchema

public extension ChordConfigSchema {

    /// Unknown-key warnings for the whole document: a typo'd top-level
    /// SECTION header, plus an unknown key inside every `arrayOfTables`
    /// section (and its nested tables). Lenient: an unknown key/section is
    /// reported but never drops a sibling row — the warning rides
    /// `ParseResult.warnings`, and `--strict` turns it into a hard exit 1
    /// like every other warning.
    static func unknownKeyWarnings(spanned: TOML.SpannedTree) -> [ConfigWarning] {
        let root = spanned.tree
        var out: [ConfigWarning] = []
        // Top level: a key that isn't a known section name is a mistyped
        // header (`[[bindigs]]`, `[optoins]`) — or, rarely, a stray
        // top-level scalar (`foo = 1`). TOML can't distinguish a typo'd
        // table from a real one, so it loads as something nothing reads and
        // the rows it "contained" silently vanish — and `--validate
        // --strict` passed, even though the editor JSON schema flags the
        // same typo. Warn so the CLI is at least as strict. The label
        // mirrors the syntax the user wrote (`[[x]]` / `[x]` / `x`); the
        // location comes from the span index (`[[x]]` first element / `[x]`
        // header / the stray entry's key).
        let knownSections = Set(sections.map(\.name))
        let knownList = knownSections.sorted().joined(separator: ", ")
        for (key, value) in root.sorted(by: { $0.key < $1.key })
        where !knownSections.contains(key) {
            let span: TOML.SourceSpan?
            let label: String
            let noun: String
            switch value {
            case .arrayOfTables(let rows):
                span = rows.first?.span; label = "[[\(key)]]"; noun = "section"
            case .table:
                span = spanned.headerSpans[[.key(key)]]; label = "[\(key)]"; noun = "section"
            default:
                span = spanned.entrySpans[[.key(key)]]?.key; label = "'\(key)'"; noun = "key"
            }
            out.append(
                ConfigWarning(
                    kind: .unknownKey,
                    message: "\(label)\(Config.sourceTag(span)): "
                        + "unknown top-level \(noun) — ignored "
                        + "(known: \(knownList))",
                    source: span))
        }
        for section in sections {
            guard case .arrayOfTables(let shape) = section.kind,
                case .arrayOfTables(let rows)? = root[section.name]
            else { continue }
            for (i, row) in rows.enumerated() {
                checkRow(
                    row, shape: shape, path: section.name,
                    prefix: [.key(section.name), .index(i)],
                    in: spanned, into: &out)
            }
        }
        return out
    }

    /// Validate one row against `shape.keySet`, then recurse into the
    /// shape's nested array-of-tables (per-app / sequence.bindings). `path`
    /// is the dotted TOML section path, rendered as `[[path]]` in messages;
    /// `prefix` is the same address in the span index's path terms.
    private static func checkRow(
        _ row: TOML.Row,
        shape: ObjectShape,
        path: String,
        prefix: [TOML.PathSegment],
        in spanned: TOML.SpannedTree,
        into out: inout [ConfigWarning]
    ) {
        let known = shape.keySet
        // A per-app row identifies by bundle-id rather than name.
        let name = row["name"]?.asString ?? row["bundle-id"]?.asString
        let who = name.map { " '\($0)'" } ?? ""
        // Sorted for deterministic warning order (TOML tables are unordered).
        for key in row.fields.keys.sorted() where !known.contains(key) {
            // An unknown key points at ITSELF (its key span); a dotted key
            // the direct lookup misses falls back to the row header.
            let span = spanned.entrySpans[prefix + [.key(key)]]?.key ?? row.span
            out.append(
                ConfigWarning(
                    kind: .unknownKey,
                    message: "[[\(path)]]\(who)\(Config.sourceTag(span)): "
                        + "unknown key '\(key)' — ignored",
                    source: span,
                    bindingName: name))
        }
        for nested in shape.nested {
            guard case .arrayOfTables(let subRows)? = row[nested.key] else { continue }
            for (i, sub) in subRows.enumerated() {
                checkRow(
                    sub, shape: nested.item,
                    path: "\(path).\(nested.key)",
                    prefix: prefix + [.key(nested.key), .index(i)],
                    in: spanned, into: &out)
            }
        }
    }
}
