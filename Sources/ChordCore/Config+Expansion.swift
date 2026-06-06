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
        /// Use the row as-is (no sugar field present).
        case single([String: TOML.Value])
        /// Expand into N rows. Caller threads each through makeBinding.
        case many([[String: TOML.Value]])
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
        _ row: [String: TOML.Value],
        warnings: inout [ConfigWarning]
    ) -> RowExpansion {
        guard let perApp = row["per-app"]?.asArrayOfTables else {
            return .single(row)
        }
        let line = row[TOML.lineKey]?.asInt.map { Int($0) }
        let baseName = row["name"]?.asString
        let displayName = baseName ?? "[[bindings]] entry"
        let source = sourceTag(line: line)

        if row["apps"] != nil {
            warnings.append(ConfigWarning(
                kind: .perAppParseError,
                message:
                    "[[bindings]] '\(displayName)'\(source): " +
                    "'apps' and 'per-app' are mutually exclusive — " +
                    "per-app entries provide their own bundle id",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }
        if perApp.isEmpty {
            warnings.append(ConfigWarning(
                kind: .perAppParseError,
                message:
                    "[[bindings]] '\(displayName)'\(source): " +
                    "per-app must contain at least one [[bindings.per-app]] entry",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }

        // Field names whose per-app override layers onto the base.
        // Everything binding-shape (input / when-var / hold-while /
        // action-* / on-up variants) is layerable; metadata
        // (`name`, `__line__`) is treated separately.
        let layerableKeys: Set<String> = [
            "input",
            "action-shell", "action-keys", "action-noop",
            "action-set-var", "action-set-value",
            "action-shell-on-up", "action-keys-on-up",
            "action-noop-on-up",
            "action-set-var-on-up", "action-set-value-on-up",
            "when-var", "when-var-value", "when-vars",
            "hold-while", "hold-while-timeout",
            "passthrough", "repeat",
            "input-source",
        ]

        var out: [[String: TOML.Value]] = []
        for entry in perApp {
            let entryLine = entry[TOML.lineKey]?.asInt.map { Int($0) } ?? line
            let entrySource = sourceTag(line: entryLine)
            guard let bundleID = entry["bundle-id"]?.asString,
                  !bundleID.isEmpty
            else {
                warnings.append(ConfigWarning(
                    kind: .perAppParseError,
                    message:
                        "[[bindings.per-app]] for '\(displayName)'" +
                        "\(entrySource): missing or empty 'bundle-id'",
                    sourceLine: entryLine, bindingName: baseName))
                return .invalid
            }

            var synth = row
            synth["per-app"] = nil
            synth["apps"] = .array([.string(bundleID)])
            for key in layerableKeys {
                if let v = entry[key] { synth[key] = v }
            }
            if let baseName {
                synth["name"] = .string("\(baseName) — \(bundleID)")
            }
            // Attribute each expansion to the per-app entry's line
            // when present (so warnings point at the override row),
            // otherwise inherit the base row's line.
            if let lv = entry[TOML.lineKey] { synth[TOML.lineKey] = lv }
            out.append(synth)
        }
        return .many(out)
    }

    /// Alias for clarity — fallback expansion uses the same outcome shape.
    typealias FallbackExpansion = RowExpansion

    /// Validate + expand `[[fallbacks]]` `inputs = [a, b, c]` sugar
    /// into N synthesised rows. Each expansion clones the original
    /// row, replaces `input` with one element, and (when the user
    /// provided a `name`) appends `" — <input>"` so warnings /
    /// `--list --json` distinguish the siblings.
    ///
    /// The `__line__` synthetic metadata key is preserved verbatim
    /// across expansions (all expanded fallbacks attribute back to
    /// the source `[[fallbacks]]` header line).
    static func expandFallbackRow(
        _ row: [String: TOML.Value],
        warnings: inout [ConfigWarning]
    ) -> FallbackExpansion {
        guard let inputsRaw = row["inputs"] else {
            return .single(row)
        }
        let line = row[TOML.lineKey]?.asInt.map { Int($0) }
        let baseName = row["name"]?.asString
        let displayName = baseName ?? "[[fallbacks]] entry"
        let source = sourceTag(line: line)

        guard case .array(let arr) = inputsRaw else {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message:
                    "[[fallbacks]] '\(displayName)'\(source): " +
                    "inputs must be an array of strings",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }
        if row["input"] != nil {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message:
                    "[[fallbacks]] '\(displayName)'\(source): " +
                    "'input' and 'inputs' are mutually exclusive — pick one",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }
        if arr.isEmpty {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message:
                    "[[fallbacks]] '\(displayName)'\(source): " +
                    "inputs[] must contain at least one entry",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }
        let inputStrings = arr.compactMap(\.asString)
        if inputStrings.count != arr.count {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message:
                    "[[fallbacks]] '\(displayName)'\(source): " +
                    "every inputs[] element must be a string",
                sourceLine: line, bindingName: baseName))
            return .invalid
        }

        var out: [[String: TOML.Value]] = []
        for inputStr in inputStrings {
            var synth = row
            synth["input"] = .string(inputStr)
            synth["inputs"] = nil
            if let baseName {
                synth["name"] = .string("\(baseName) — \(inputStr)")
            }
            out.append(synth)
        }
        return .many(out)
    }
}
