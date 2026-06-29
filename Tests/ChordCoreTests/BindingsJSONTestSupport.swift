import Foundation
import Testing
@testable import ChordCore

/// Shared round-trip helpers for the wire-shape tests (T6 / issue #52
/// follow-up). The `parse → makeDocument → encodeJSON → jsonObject`
/// chain was copied inline across ~14 tests, each re-deriving the
/// `[String: Any]` via `as!`; this centralises it on one canonical,
/// `#require`-guarded path so a shape mismatch fails with a clear
/// message instead of aborting the process.
///
/// Was an `extension XCTestCase`; under Swift Testing there is no
/// `XCTestCase` base, so these are free functions — any `@Suite` can
/// call them unqualified. (Swift Testing's `#_sourceLocation()` macro
/// is framework-internal — not callable from user code — so we don't
/// forward the caller's location; the `#require` failure points at this
/// file, and the message identifies which shape assertion tripped.)
///
/// NOT a home for the genuinely different round-trips —
/// `DiffTests` (reload-diff document), `QuerySchemaTests` (query
/// schema), and `ConfigSchemaShapeTests` (config schema) target other
/// schemas and keep their own helpers.

/// `source` → bindings schema document → top-level JSON object.
/// `validationStrict` mirrors [BindingsSchema.makeDocument]
/// (`nil` = the emitter's default, matching the bare
/// `makeDocument(from:)` call the inline copies used).
func parseToBindingsJSON(
    _ source: String,
    validationStrict: Bool? = nil
) throws -> [String: Any] {
    let res = try Config.parse(source)
    let doc = BindingsSchema.makeDocument(
        from: res,
        validationStrict: validationStrict)
    let data = try BindingsSchema.encodeJSON(doc)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any],
        "bindings JSON was not a top-level object")
}

/// The first entry of the emitted `bindings` array — the common
/// single-binding wire-shape assertion target.
func firstBinding(
    _ source: String,
    validationStrict: Bool? = nil
) throws -> [String: Any] {
    let json = try parseToBindingsJSON(source, validationStrict: validationStrict)
    let bindings = try #require(
        json["bindings"] as? [[String: Any]],
        "no bindings[] in emitted JSON")
    return try #require(bindings.first, "bindings[] was empty")
}
