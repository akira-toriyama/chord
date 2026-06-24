import Testing
@testable import ChordCore

/// Guards the reload-diff against silently dropping a binding dimension.
///
/// The failure mode (C2): a WireBinding field is added but not wired into
/// `BindingsSchema.semanticallyEqual` (→ `daemon --reload --dry-run`
/// reports "no change" on an edit) or the diff renderer (→ a bare
/// `~ <name>` with no reason). This test reflects WireBinding's stored
/// properties and forces every one to be classified as either
/// compared-by-equality or intentionally-ignored. Add a field and this
/// test fails until you also touch semanticallyEqual + ReloadDiffPrinter.
@Suite struct WireBindingDiffCoverageTests {

    /// A representative binding built through the real wire path.
    private func sampleBinding() throws -> BindingsSchema.WireBinding {
        let res = try Config.parse("""
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """)
        return try #require(BindingsSchema.makeDocument(from: res).bindings.first)
    }

    /// Fields semanticallyEqual deliberately IGNORES — cosmetic / ordering
    /// metadata that must NOT make a binding look changed.
    private let ignored: Set<String> = ["index", "sourceLine"]

    /// Fields semanticallyEqual MUST compare (and the renderer must be able
    /// to show). Keep in lockstep with `BindingsSchema.semanticallyEqual`
    /// and `ChordApp.renderDiffBucket`.
    private let compared: Set<String> = [
        "name", "input", "apps", "action", "condition", "holdWhile",
        "holdWhileTimeoutMs", "actionOnUp", "extraActions",
        "passthrough", "repeatStrategy", "inputSource",
    ]

    @Test func everyStoredPropertyIsClassified() throws {
        let labels = Mirror(reflecting: try sampleBinding())
            .children.compactMap(\.label)
        // Extracted to a `let` so the macro expansion doesn't tip the
        // type-checker into an "unable to type-check in reasonable time".
        let classified = Set(labels) == ignored.union(compared)
        #expect(
            classified,
            "WireBinding stored properties drifted from the diff's coverage. A new field must be classified: add it to `compared` AND to BindingsSchema.semanticallyEqual AND to ReloadDiffPrinter.renderDiffBucket — or to `ignored` if it is cosmetic.")
        // Sanity: reflection saw the full set (no Optional-flattening etc.).
        #expect(labels.count == ignored.count + compared.count)
    }
}
