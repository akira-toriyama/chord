// Config+Spans.swift — t-0030 / chord#159: per-field span resolution.
//
// `Toml.parseWithSpans` reports every surviving assignment's key/value
// location in a side index keyed by tree path. This file is the bridge
// between that index and the row-shaped world the config parsers live
// in: a `RowSpans` view resolves "field name → location" for ONE row
// (or one plain `[table]`), with the row header as the fallback for
// fields that have no source bytes (synthesized desugar fields, absent
// fields, dotted keys the direct lookup misses).

import Foundation

extension Config {

    /// Per-row view of `parseWithSpans`' location index: the row's
    /// `[[header]]` span plus each top-level field's key/value spans.
    /// Lookups fall back to the header so warnings about a field the
    /// index can't place still attribute to the row.
    struct RowSpans: Sendable {
        var header: TOML.SourceSpan?
        var fields: [String: TOML.EntrySpans]

        static let none = RowSpans(header: nil, fields: [:])

        /// The field's key position — unknown-key and
        /// conflicting-field warnings point here.
        func key(_ field: String) -> TOML.SourceSpan? {
            fields[field]?.key ?? header
        }

        /// The field's value position — malformed-value warnings
        /// point here.
        func value(_ field: String) -> TOML.SourceSpan? {
            fields[field]?.value ?? header
        }
    }

    /// Resolve the per-field spans for one array-of-tables `row`
    /// living at `prefix` (e.g. `[.key("bindings"), .index(0)]`).
    static func rowSpans(
        _ row: TOML.Row,
        at prefix: [TOML.PathSegment],
        in spanned: TOML.SpannedTree
    ) -> RowSpans {
        var fields: [String: TOML.EntrySpans] = [:]
        for f in row.fields.keys {
            if let es = spanned.entrySpans[prefix + [.key(f)]] {
                fields[f] = es
            }
        }
        return RowSpans(
            header: row.span ?? spanned.headerSpans[prefix],
            fields: fields)
    }

    /// Same resolution for a plain `[table]` section (`[options]`,
    /// the alias maps): header from the header index, fields by key.
    static func tableSpans(
        keys: some Sequence<String>,
        at prefix: [TOML.PathSegment],
        in spanned: TOML.SpannedTree
    ) -> RowSpans {
        var fields: [String: TOML.EntrySpans] = [:]
        for f in keys {
            if let es = spanned.entrySpans[prefix + [.key(f)]] {
                fields[f] = es
            }
        }
        return RowSpans(
            header: spanned.headerSpans[prefix],
            fields: fields)
    }
}
