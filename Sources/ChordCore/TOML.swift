// chord's hand-rolled TOML *subset* parser used to live here (434 lines).
// In atelier Phase 1.6 it folded into sill's pure `Toml` module — it was
// the feature SUPERSET reference the shared parser was modelled on, so the
// shared `Toml.parse` is the SAME nested, strict skin chord always used:
//   • dotted keys (`a.b.c = …`) collapse to nested `.table`s,
//   • `[section]` / `[[array-of-tables]]` headers, including nested
//     `[[a.b]]` (`a[last].b`),
//   • a synthetic `__line__` (`Toml.lineKey`) seeded into every `[[X]]`
//     row so a warning can name the source line,
//   • throw `Toml.ParseError` on the first malformed header / missing `=`
//     / unrecognised scalar.
// sill adds (as a strict superset chord's old parser would have rejected):
// multi-line arrays, `0x…` hex ints, and escape-aware comment/quote
// walking — none of which any chord config relied on the ABSENCE of.
//
// The `TOML` typealias keeps every `TOML.Value` / `TOML.parse` /
// `TOML.ParseError` / `TOML.lineKey` reference across ChordCore (and the
// `@testable` tests) unchanged. `@_exported` re-exports the module so
// those references resolve without a per-file `import Toml`.
//
// One accessor change rippled out from the consolidation: sill's
// `Toml.Value.asInt` returns a native `Int` (the flat consumers' field
// width), not chord's old `Int64`. Every chord call site already wrapped
// the result in `Int(…)`, so the narrowing is a lossless no-op on 64-bit;
// the raw `Int64` is still available as `asInt64` if ever needed.

@_exported import Toml

public typealias TOML = Toml

extension Dictionary where Key == String, Value == TOML.Value {
    /// The 1-based source-file line for this `[[X]]` row, read from the
    /// synthetic `__line__` key ([TOML.lineKey]) the parser seeds into
    /// every array-of-tables row; `nil` when absent. The single reader
    /// for the `row[TOML.lineKey]?.asInt` sites across `Config*` —
    /// `asInt` is already a native `Int`, so no `Int(…)` width cast
    /// (the old `Int64`-era `.map { Int($0) }` was a dead no-op).
    var sourceLine: Int? { self[TOML.lineKey]?.asInt }
}
