// Config+Condition.swift — #51 split of Config.swift.
// `when-var` / `when-vars` condition parsing + `hold-while` /
// `hold-while-timeout` parsing + the `OptionalParse` carrier that
// distinguishes absent (ok) from malformed (drop). Members of
// `enum Config`; `internal` where `makeBinding` calls across files.

import Foundation

extension Config {
    /// Parse the optional `when-var` / `when-var-value` pair (single-
    /// variable equality) or the chord 0.9.0+ `when-vars = { a = 1,
    /// b = 2 }` table form (AND of N equality gates).
    /// Returns:
    ///   * `.some(.some(condition))` — field present and well-formed
    ///   * `.some(.none)`            — field absent (no gate)
    ///   * `.none`                   — field present but malformed
    ///                                 (caller drops the binding)
    ///
    /// `when-var` and `when-vars` are mutually exclusive. `when-vars`
    /// must be a non-empty inline table; values must be integers.
    /// A single-entry `when-vars` is emitted as a plain `.variable`
    /// condition (matching the v2 shape) so the matcher / schema can
    /// stay on one path for the common case.
    static func parseCondition(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Condition>? {
        let varName = row["when-var"]?.asString
        let rawValue = row["when-var-value"]
        let whenVars = row["when-vars"]

        // Mutual exclusion: pick the user's intent up front so the
        // error is clear (they wrote both forms).
        if whenVars != nil && (varName != nil || rawValue != nil) {
            warnings.append(
                ConfigWarning(
                    kind: .conditionParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "when-var / when-var-value and when-vars are "
                        + "mutually exclusive — pick one",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }

        if let whenVars {
            return parseWhenVarsTable(
                whenVars, section: section, name: name, source: source,
                sourceLine: sourceLine, warnings: &warnings)
        }

        if varName == nil && rawValue == nil {
            return OptionalParse(value: nil)
        }
        guard let varName = varName else {
            warnings.append(
                ConfigWarning(
                    kind: .conditionParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "when-var-value present without when-var",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        // when-var-value defaults to 1 — matches the leader-key idiom.
        let value: Int
        if let raw = rawValue {
            guard let v = raw.asInt else {
                warnings.append(
                    ConfigWarning(
                        kind: .conditionParseError,
                        message:
                            "\(section) '\(name)'\(source): " + "when-var-value must be an integer",
                        sourceLine: sourceLine, bindingName: name))
                return nil
            }
            value = Int(v)
        } else {
            value = 1
        }
        return OptionalParse(value: .variable(name: varName, equals: value))
    }

    private static func parseWhenVarsTable(
        _ raw: TOML.Value,
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Condition>? {
        guard case .table(let table) = raw else {
            warnings.append(
                ConfigWarning(
                    kind: .conditionParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "when-vars must be an inline table { var = value, … }",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        if table.isEmpty {
            warnings.append(
                ConfigWarning(
                    kind: .conditionParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "when-vars must contain at least one variable",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        // Sort by key for deterministic ordering — same reason as
        // [[remap]] map iteration. Affects config --show --json output only.
        var parts: [Condition] = []
        for key in table.keys.sorted() {
            guard let v = table[key]?.asInt else {
                warnings.append(
                    ConfigWarning(
                        kind: .conditionParseError,
                        message:
                            "\(section) '\(name)'\(source): "
                            + "when-vars['\(key)'] value must be an integer",
                        sourceLine: sourceLine, bindingName: name))
                return nil
            }
            parts.append(.variable(name: key, equals: Int(v)))
        }
        // Single entry collapses to .variable — keeps the matcher /
        // schema path uniform with the common case.
        if parts.count == 1 {
            return OptionalParse(value: parts[0])
        }
        return OptionalParse(value: .conjunction(parts))
    }

    /// Parse the optional `hold-while-timeout = 800` field. Positive
    /// integer in milliseconds; 0 / negative is a user error and
    /// drops the binding (the field has no zero meaning — explicit
    /// clear uses `action-set-value = 0`).
    static func parseHoldWhileTimeout(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Int>? {
        guard let raw = row["hold-while-timeout"] else {
            return OptionalParse(value: nil)
        }
        guard let v = raw.asInt else {
            warnings.append(
                ConfigWarning(
                    kind: .holdWhileParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "hold-while-timeout must be an integer (ms)",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        let ms = Int(v)
        guard ms > 0 else {
            warnings.append(
                ConfigWarning(
                    kind: .holdWhileParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "hold-while-timeout must be > 0 (got \(ms))",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        return OptionalParse(value: ms)
    }

    /// Parse the optional `action-keys-delay-ms = 20` field — the
    /// inter-key delay (ms) for a multi-key `action-keys` array.
    /// Positive integer; 0 / negative / non-int is a user error and
    /// drops the binding (0 would mean "no delay", which is just the
    /// default — omit the field instead). Same `OptionalParse<Int>?`
    /// convention as `parseHoldWhileTimeout`: outer `nil` = drop,
    /// `OptionalParse(value: nil)` = field absent.
    static func parseActionKeysDelay(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Int>? {
        guard let raw = row["action-keys-delay-ms"] else {
            return OptionalParse(value: nil)
        }
        guard let v = raw.asInt else {
            warnings.append(
                ConfigWarning(
                    kind: .actionKeysDelayParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "action-keys-delay-ms must be an integer (ms)",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        let ms = Int(v)
        guard ms > 0 else {
            warnings.append(
                ConfigWarning(
                    kind: .actionKeysDelayParseError,
                    message:
                        "\(section) '\(name)'\(source): "
                        + "action-keys-delay-ms must be > 0 (got \(ms))",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
        return OptionalParse(value: ms)
    }

    /// Parse the optional `hold-while = "cmd + opt"` field into a
    /// [Modifiers] mask. Same return convention as `parseCondition`.
    static func parseHoldWhile(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Modifiers>? {
        guard let raw = row["hold-while"]?.asString else {
            return OptionalParse(value: nil)
        }
        do {
            let mask = try InputParser.parseModifiersOnly(raw)
            // Empty mask is meaningless for hold-while — surface it
            // as a parse error rather than silently no-op'ing.
            if mask.rawValue == 0 {
                warnings.append(
                    ConfigWarning(
                        kind: .holdWhileParseError,
                        message:
                            "\(section) '\(name)'\(source): "
                            + "hold-while must contain at least one modifier",
                        sourceLine: sourceLine, bindingName: name))
                return nil
            }
            return OptionalParse(value: mask)
        } catch {
            warnings.append(
                ConfigWarning(
                    kind: .holdWhileParseError,
                    message:
                        "\(section) '\(name)'\(source): hold-while: \(error)",
                    sourceLine: sourceLine, bindingName: name))
            return nil
        }
    }

    /// Wrapper used by optional-field parsers so they can distinguish
    /// "absent (success)" from "present-but-malformed (drop binding)".
    /// `Optional<Optional<T>>` would technically work but the inner
    /// nesting reads poorly at call sites.
    /// internal: the (now internal) `parseCondition` / `parseHoldWhile` /
    /// `parseHoldWhileTimeout` return it, and `makeBinding`
    /// (Config+Binding.swift) reads `.value` across the file boundary.
    struct OptionalParse<T> {
        let value: T?
    }
}
