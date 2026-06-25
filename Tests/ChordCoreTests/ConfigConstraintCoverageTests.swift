import Testing
@testable import ChordCore

/// #138-B: `x-chord-constraints` surfaces the runtime-only rules (the ones
/// Draft-07 cannot express) in editor hover. This guards COMPLETENESS, not text
/// identity with the interpolated `ConfigWarning` messages: every
/// `ConfigWarning.Kind` must be CLASSIFIED — either surfaced via the
/// `runtimeConstraints` catalog, or listed in `notSurfaced` with a reason — so a
/// newly added Kind can't silently escape the catalog. Adding a Kind without
/// classifying it fails `everyKindIsClassified`.
@Suite struct ConfigConstraintCoverageTests {

    /// Kinds intentionally NOT surfaced as binding-hover constraints — each is
    /// either schema-expressible (taplo already squiggles it), a leaf-DSL parse
    /// error (the daemon parser is the authority; no `pattern` per the boundary
    /// decision), or a non-binding/table-level concern.
    static let notSurfaced: Set<ConfigWarning.Kind> = [
        .configNotFound,        // file-level, not a binding rule
        .missingInput,          // schema: `required: ["input"]`
        .missingAction,         // schema: action-* `anyOf`
        .unknownInputToken,     // leaf-DSL parse (daemon authority)
        .actionKeysParseError,  // leaf-DSL parse
        .actionKeysDelayParseError, // schema: integer + exclusiveMinimum 0 (taplo squiggles)
        .actionAliasNonString,  // [action-aliases] value type — schema additionalProperties
        .inputAliasNonString,   // [input-aliases] value type — schema additionalProperties
        .inputAliasInvalidBody, // [input-aliases] body parse — table, not a binding hover
        .conditionParseError,   // leaf parse (when-var)
        .holdWhileParseError,   // leaf parse (hold-while / hold-while-timeout)
        .remapParseError,       // [[remap]] parse — remap table, not a binding
        .perAppParseError,      // [[bindings.per-app]] parse
        .actionAliasCallError,  // @name(args) call parse
        .unknownOptionKey,      // [options] typo — schema additionalProperties:false
        .unknownKey,            // schema additionalProperties:false
        .other,                 // catch-all
    ]

    @Test func everyKindIsClassified() {
        let surfaced = Set(ChordConfigSchema.runtimeConstraints.flatMap(\.kinds))
        let all = Set(ConfigWarning.Kind.allCases)

        // No Kind may be in both buckets.
        #expect(surfaced.isDisjoint(with: Self.notSurfaced),
                "Kind both surfaced and not-surfaced: \(surfaced.intersection(Self.notSurfaced))")
        // Every Kind must be classified (the drift guard).
        let unclassified = all.subtracting(surfaced).subtracting(Self.notSurfaced)
        #expect(unclassified.isEmpty, """
        ConfigWarning.Kind \(unclassified.map(\.rawValue).sorted()) is unclassified — \
        add it to ChordConfigSchema.runtimeConstraints (surface in editor hover) \
        or to ConfigConstraintCoverageTests.notSurfaced (with a reason).
        """)
    }

    @Test func catalogIsWellFormed() {
        #expect(!ChordConfigSchema.runtimeConstraints.isEmpty)
        for c in ChordConfigSchema.runtimeConstraints {
            #expect(!c.kinds.isEmpty, "constraint has no Kind: \(c.text)")
            #expect(!c.text.isEmpty, "constraint has empty text")
        }
    }
}
