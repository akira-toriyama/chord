import Foundation

/// `[[remap]]` table sugar extraction (chord 0.8.0+).
///
/// Same decomposition rationale as Config+Sequence.swift — see
/// Issue #51. `parseRemaps` stays a member of `enum Config` via
/// this extension; the only `Config.parse` call site is unchanged.
extension Config {

    /// Expand `[[remap]]` rows into ordinary `.keys`-action bindings.
    /// Pure syntactic sugar over `[[bindings]] input = "<mods> - <key>"
    /// action-keys = "<value>"`. Each map entry becomes one binding.
    ///
    /// Constraints (issue #13):
    ///   * `modifiers` is required and must include at least one
    ///     modifier — bare-key remap would swallow every primary
    ///     press, same trap as a bare-key sequence prefix.
    ///   * `map` must be a non-empty inline table whose values are
    ///     all strings (interpreted as `action-keys`).
    ///   * `apps` is optional and inherited verbatim by every
    ///     expanded binding.
    ///   * `action-shell` is intentionally not supported — the issue
    ///     spec restricts remap to action-keys only.
    static func parseRemaps(
        spanned: TOML.SpannedTree,
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        vkeyAliases: [String: UInt8] = [:],
        warnings: inout [ConfigWarning]
    ) -> (expanded: [Binding], dropped: Int) {
        var expanded: [Binding] = []
        var dropped = 0
        let rows = spanned.tree["remap"]?.asArrayOfTables ?? []
        for (ri, row) in rows.enumerated() {
            let spans = rowSpans(row, at: [.key("remap"), .index(ri)], in: spanned)
            let baseName = row["name"]?.asString ?? "remap-\(ri + 1)"

            func failRemap(_ msg: String, at span: TOML.SourceSpan?) {
                warnings.append(
                    ConfigWarning(
                        kind: .remapParseError,
                        message: "[[remap]] '\(baseName)'\(sourceTag(span)): \(msg)",
                        source: span, bindingName: baseName))
                dropped += 1
            }

            guard let modsRaw = row["modifiers"]?.asString,
                !modsRaw.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                failRemap(
                    "missing 'modifiers' (bare-key remap is not allowed)",
                    at: row["modifiers"] != nil
                        ? spans.value("modifiers") : spans.header)
                continue
            }
            do {
                let mask = try InputParser.parseModifiersOnly(
                    modsRaw, inputAliases: inputAliases)
                guard mask.rawValue != 0 else {
                    failRemap(
                        "modifiers resolved to an empty mask "
                            + "(at least one modifier required)",
                        at: spans.value("modifiers"))
                    continue
                }
            } catch {
                failRemap("modifiers: \(error)", at: spans.value("modifiers"))
                continue
            }

            // Inline-table interiors are not indexed by parseWithSpans
            // (the entry is the unit), so every map complaint — including
            // the per-entry ones below — points at the `map` entry.
            let mapSpan = spans.value("map")
            guard let mapValue = row["map"] else {
                failRemap(
                    "missing 'map' (inline table of key → action-keys)",
                    at: spans.header)
                continue
            }
            guard case .table(let mapTable) = mapValue else {
                failRemap(
                    "'map' must be an inline table " + "(`{ b = \"left\", … }`)",
                    at: mapSpan)
                continue
            }
            if mapTable.isEmpty {
                failRemap("map must contain at least one entry", at: mapSpan)
                continue
            }

            // Sort by key for deterministic ordering. Inline-table key
            // iteration is unordered in Swift dictionaries, and that
            // would surface as non-deterministic `config --show --json` output.
            // Synthesized fields map back to the [[remap]] fields they
            // came from (input ← modifiers, action-keys ← map) so a
            // makeBinding complaint points at the user's actual TOML.
            var synthSpanFields: [String: TOML.EntrySpans] = [:]
            synthSpanFields["name"] = spans.fields["name"]
            synthSpanFields["input"] = spans.fields["modifiers"]
            synthSpanFields["action-keys"] = spans.fields["map"]
            synthSpanFields["apps"] = spans.fields["apps"]
            let synthSpans = RowSpans(header: spans.header, fields: synthSpanFields)

            for key in mapTable.keys.sorted() {
                let entryName = "\(baseName).\(key)"
                guard let valueStr = mapTable[key]?.asString else {
                    warnings.append(
                        ConfigWarning(
                            kind: .remapParseError,
                            message:
                                "[[remap]] '\(baseName)'\(sourceTag(mapSpan)): "
                                + "map['\(key)']: value must be a string "
                                + "(interpreted as action-keys)",
                            source: mapSpan, bindingName: entryName))
                    dropped += 1
                    continue
                }
                // vkeys carry no modifiers, so a v-key alias can't be a
                // remap source (the source is composed with `modifiers`
                // below). Reject with a clear message instead of a
                // confusing composed-string unknown-token error.
                let keyLower = key.lowercased()
                if vkeyAliases[keyLower] != nil
                    || InputParser.vkeyWildcardNames.contains(keyLower)
                {
                    warnings.append(
                        ConfigWarning(
                            kind: .remapParseError,
                            message:
                                "[[remap]] '\(baseName)'\(sourceTag(mapSpan)): map key '\(key)' "
                                + "is a v-key — v-keys are not supported in remaps "
                                + "(they carry no modifiers); entry dropped",
                            source: mapSpan, bindingName: entryName))
                    dropped += 1
                    continue
                }
                let composedInput = "\(modsRaw) - \(key)"
                var synth: [String: TOML.Value] = [
                    "name": .string(entryName),
                    "input": .string(composedInput),
                    "action-keys": .string(valueStr)
                ]
                if let apps = row["apps"] { synth["apps"] = apps }
                if let b = makeBinding(
                    from: synth, spans: synthSpans, index: ri,
                    isFallback: false,
                    actionAliases: actionAliases,
                    inputAliases: inputAliases,
                    vkeyAliases: vkeyAliases,
                    warnings: &warnings)
                {
                    expanded.append(b)
                } else {
                    dropped += 1
                }
            }
        }
        return (expanded, dropped)
    }
}
