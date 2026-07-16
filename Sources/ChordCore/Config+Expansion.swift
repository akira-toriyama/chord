import Foundation

/// Row expansion sugar — per-app + fallback inputs[].
///
/// Both turn a single TOML row into multiple synthesised rows that
/// the main parse loop threads through `Config.makeBinding`. Same
/// extraction rationale as the Sequence / Remap parsers (issue #51).
extension Config {

    /// Outcome of inspecting a single row for sugar that fans out
    /// into multiple synthesised rows. Used by both `[[fallbacks]]
    /// inputs[]` (chord 0.8.0+) and `[[bindings]] [[bindings.per-app]]`
    /// (chord 0.8.0+).
    enum RowExpansion {
        /// Use the row as-is (no sugar field present), with its
        /// resolved per-field spans.
        case single([String: TOML.Value], spans: RowSpans)
        /// Expand into N rows, each paired with its resolved spans.
        /// Caller threads each through makeBinding as `(fields, spans)`.
        case many([(row: [String: TOML.Value], spans: RowSpans)])
        /// Validation failed (mutually exclusive fields, empty list,
        /// non-string member, etc.). Warning already appended; caller
        /// counts the drop.
        case invalid
    }

    /// Per-binding `[[bindings.per-app]]` sub-rows expand a single
    /// `[[bindings]]` declaration into one binding per OS, each
    /// scoped via `apps = [bundle-id]`. The per-app entry's
    /// action-* / when-var / hold-while fields override the base
    /// row's same fields; base-row fields not present in the entry
    /// are inherited.
    ///
    /// Wire shape (issue #12):
    /// ```toml
    /// [[bindings]]
    /// name = "tab-left"
    /// input = "$ULTRA_LL - c"
    ///
    ///   [[bindings.per-app]]
    ///   bundle-id = "com.google.Chrome"
    ///   action-keys = "ctrl + shift - tab"
    ///
    ///   [[bindings.per-app]]
    ///   bundle-id = "com.microsoft.VSCode"
    ///   action-keys = "cmd + shift - ["
    /// ```
    ///
    /// Constraints:
    ///   * `apps` and `per-app` are mutually exclusive (the per-app
    ///     entry's `bundle-id` becomes the binding's `apps`)
    ///   * `bundle-id` is required on each per-app entry
    ///   * empty `per-app` array drops the whole binding
    static func expandBindingPerApp(
        _ row: TOML.Row,
        at prefix: [TOML.PathSegment],
        in spanned: TOML.SpannedTree,
        warnings: inout [ConfigWarning]
    ) -> RowExpansion {
        let baseSpans = rowSpans(row, at: prefix, in: spanned)
        guard let perApp = row["per-app"]?.asArrayOfTables else {
            return .single(row.fields, spans: baseSpans)
        }
        let baseName = row["name"]?.asString
        let displayName = baseName ?? "[[bindings]] entry"

        if row["apps"] != nil {
            let span = baseSpans.key("apps")
            warnings.append(
                ConfigWarning(
                    kind: .perAppParseError,
                    message:
                        "[[bindings]] '\(displayName)'\(sourceTag(span)): "
                        + "'apps' and 'per-app' are mutually exclusive — "
                        + "per-app entries provide their own bundle id",
                    source: span, bindingName: baseName))
            return .invalid
        }
        if perApp.isEmpty {
            let span = baseSpans.header
            warnings.append(
                ConfigWarning(
                    kind: .perAppParseError,
                    message:
                        "[[bindings]] '\(displayName)'\(sourceTag(span)): "
                        + "per-app must contain at least one [[bindings.per-app]] entry",
                    source: span, bindingName: baseName))
            return .invalid
        }

        // Field names whose per-app override layers onto the base.
        // Everything binding-shape (input / when-var / hold-while /
        // action-* / on-up variants) is layerable; metadata (`name`)
        // and the per-app identity key (`bundle-id`, which becomes
        // `apps`) are not. #52-bounded: this set is DERIVED from the
        // descriptor's perAppShape (the same single source that drives
        // the unknown-key check + the schema), so a key added to the
        // shape lands here too — it can't go stale. `rejected` fields
        // (the invalid `*-on-up` forms) are excluded.
        let layerableKeys = Set(
            ChordConfigSchema.perAppShape().fields
                .filter { !$0.rejected && $0.key != "bundle-id" }
                .map(\.key))

        var out: [(row: [String: TOML.Value], spans: RowSpans)] = []
        for (ei, entry) in perApp.enumerated() {
            // Attribute each expansion to the per-app entry when present
            // (so warnings point at the override row), otherwise inherit
            // the base row's location — and layer the entry's FIELD spans
            // over the base's exactly like the fields themselves layer.
            let entryPrefix = prefix + [.key("per-app"), .index(ei)]
            let entrySpans = rowSpans(entry, at: entryPrefix, in: spanned)
            guard let bundleID = entry["bundle-id"]?.asString,
                !bundleID.isEmpty
            else {
                let span = entrySpans.value("bundle-id") ?? baseSpans.header
                warnings.append(
                    ConfigWarning(
                        kind: .perAppParseError,
                        message:
                            "[[bindings.per-app]] for '\(displayName)'"
                            + "\(sourceTag(span)): missing or empty 'bundle-id'",
                        source: span, bindingName: baseName))
                return .invalid
            }

            var synth = row.fields
            var synthFields = baseSpans.fields
            synth["per-app"] = nil
            synthFields["per-app"] = nil
            synth["apps"] = .array([.string(bundleID)])
            // The synthesized `apps` comes from the entry's bundle-id —
            // point any `apps` complaint there.
            synthFields["apps"] = entrySpans.fields["bundle-id"]
            for key in layerableKeys {
                if let v = entry[key] {
                    synth[key] = v
                    synthFields[key] = entrySpans.fields[key]
                }
            }
            if let baseName {
                synth["name"] = .string("\(baseName) — \(bundleID)")
            }
            out.append(
                (
                    synth,
                    RowSpans(
                        header: entrySpans.header ?? baseSpans.header,
                        fields: synthFields)
                ))
        }
        return .many(out)
    }

    /// Alias for clarity — fallback expansion uses the same outcome shape.
    typealias FallbackExpansion = RowExpansion

    /// Validate + expand `[[fallbacks]]` `inputs = [a, b, c]` sugar
    /// into N synthesised rows. Each expansion clones the original
    /// row, replaces `input` with one element, and (when the user
    /// provided a `name`) appends `" — <input>"` so warnings /
    /// `config --show --json` distinguish the siblings.
    ///
    /// Every expanded fallback attributes back to the source
    /// `[[fallbacks]]` row's spans (the synthesized `input` points at
    /// the `inputs` array it came from).
    static func expandFallbackRow(
        _ row: TOML.Row,
        at prefix: [TOML.PathSegment],
        in spanned: TOML.SpannedTree,
        warnings: inout [ConfigWarning]
    ) -> FallbackExpansion {
        let baseSpans = rowSpans(row, at: prefix, in: spanned)
        guard let inputsRaw = row["inputs"] else {
            return .single(row.fields, spans: baseSpans)
        }
        let baseName = row["name"]?.asString
        let displayName = baseName ?? "[[fallbacks]] entry"

        guard case .array(let arr) = inputsRaw else {
            let span = baseSpans.value("inputs")
            warnings.append(
                ConfigWarning(
                    kind: .missingInput,
                    message:
                        "[[fallbacks]] '\(displayName)'\(sourceTag(span)): "
                        + "inputs must be an array of strings",
                    source: span, bindingName: baseName))
            return .invalid
        }
        if row["input"] != nil {
            let span = baseSpans.key("input")
            warnings.append(
                ConfigWarning(
                    kind: .missingInput,
                    message:
                        "[[fallbacks]] '\(displayName)'\(sourceTag(span)): "
                        + "'input' and 'inputs' are mutually exclusive — pick one",
                    source: span, bindingName: baseName))
            return .invalid
        }
        if arr.isEmpty {
            let span = baseSpans.value("inputs")
            warnings.append(
                ConfigWarning(
                    kind: .missingInput,
                    message:
                        "[[fallbacks]] '\(displayName)'\(sourceTag(span)): "
                        + "inputs[] must contain at least one entry",
                    source: span, bindingName: baseName))
            return .invalid
        }
        let inputStrings = arr.compactMap(\.asString)
        if inputStrings.count != arr.count {
            let span = baseSpans.value("inputs")
            warnings.append(
                ConfigWarning(
                    kind: .missingInput,
                    message:
                        "[[fallbacks]] '\(displayName)'\(sourceTag(span)): "
                        + "every inputs[] element must be a string",
                    source: span, bindingName: baseName))
            return .invalid
        }

        // The synthesized `input` comes from the `inputs` array — point
        // any input complaint there.
        var synthSpanFields = baseSpans.fields
        synthSpanFields["input"] = baseSpans.fields["inputs"]
        synthSpanFields["inputs"] = nil
        let synthSpans = RowSpans(header: baseSpans.header, fields: synthSpanFields)

        var out: [(row: [String: TOML.Value], spans: RowSpans)] = []
        for inputStr in inputStrings {
            var synth = row.fields
            synth["input"] = .string(inputStr)
            synth["inputs"] = nil
            if let baseName {
                synth["name"] = .string("\(baseName) — \(inputStr)")
            }
            out.append((synth, synthSpans))
        }
        return .many(out)
    }
}
