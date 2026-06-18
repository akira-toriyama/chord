import XCTest
@testable import ChordCore

/// Shared round-trip helpers for the wire-shape tests (T6 / issue #52
/// follow-up). The `parse → makeDocument → encodeJSON → jsonObject`
/// chain was copied inline across ~14 tests, each re-deriving the
/// `[String: Any]` via `as!`; this centralises it on one canonical,
/// `XCTUnwrap`-guarded path so a shape mismatch fails at a `file:line`
/// instead of aborting the process.
///
/// NOT a home for the genuinely different round-trips —
/// `DiffTests` (reload-diff document), `QuerySchemaTests` (query
/// schema), and `ConfigSchemaShapeTests` (config schema) target other
/// schemas and keep their own helpers.
extension XCTestCase {
    /// `source` → bindings schema document → top-level JSON object.
    /// `validationStrict` mirrors [BindingsSchema.makeDocument]
    /// (`nil` = the emitter's default, matching the bare
    /// `makeDocument(from:)` call the inline copies used).
    func parseToBindingsJSON(
        _ source: String,
        validationStrict: Bool? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let res = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: res,
                                              validationStrict: validationStrict)
        let data = try BindingsSchema.encodeJSON(doc)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "bindings JSON was not a top-level object",
            file: file, line: line)
    }

    /// The first entry of the emitted `bindings` array — the common
    /// single-binding wire-shape assertion target.
    func firstBinding(
        _ source: String,
        validationStrict: Bool? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let json = try parseToBindingsJSON(source,
                                           validationStrict: validationStrict,
                                           file: file, line: line)
        let bindings = try XCTUnwrap(json["bindings"] as? [[String: Any]],
                                     "no bindings[] in emitted JSON",
                                     file: file, line: line)
        return try XCTUnwrap(bindings.first,
                             "bindings[] was empty", file: file, line: line)
    }
}
