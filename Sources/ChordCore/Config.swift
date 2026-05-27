import Foundation

/// Parses TOML → [ChordConfig]. Out-of-range / unknown values are
/// *clamped* or *dropped* with a warning rather than rejected — a
/// typo in one binding can never disable the whole daemon. The
/// strict-rejection path is `chord --validate`, which surfaces
/// every warning and fails with a non-zero exit if any binding
/// dropped.
public enum Config {
    public struct ParseResult: Sendable {
        public var config: ChordConfig
        public var warnings: [ConfigWarning]
        public var droppedBindings: Int
        /// Absolute path the result was loaded from, or `nil` if
        /// `parse(_:)` was called directly with an in-memory string.
        public var sourcePath: String?
    }

    public enum LoadError: Error, CustomStringConvertible {
        case ioError(String)
        case tomlError(String)
        public var description: String {
            switch self {
            case .ioError(let m): return m
            case .tomlError(let m): return m
            }
        }
    }

    /// Read + parse the file at [ChordConfig.path]. A missing file
    /// is *not* an error: returns an empty config. (The README
    /// tells users to `curl` the template into place; an empty
    /// daemon is a perfectly reasonable startup state.)
    public static func load(path: String = ChordConfig.path) throws
        -> ParseResult
    {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return ParseResult(
                config: .init(),
                warnings: [ConfigWarning(
                    kind: .configNotFound,
                    message: "config not found at \(path)")],
                droppedBindings: 0,
                sourcePath: path)
        }
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) }
        catch { throw LoadError.ioError("read \(path): \(error)") }
        var result = try parse(source)
        result.sourcePath = path
        return result
    }

    public static func parse(_ source: String) throws -> ParseResult {
        let root: [String: TOML.Value]
        do { root = try TOML.parse(source) }
        catch let e as TOML.ParseError { throw LoadError.tomlError(String(describing: e)) }
        catch { throw LoadError.tomlError(String(describing: error)) }

        var warnings: [ConfigWarning] = []
        var options = ChordConfig.Options()

        if case .table(let opts)? = root["options"] {
            if let b = opts["passthrough-unmatched"]?.asBool {
                options.passthroughUnmatched = b
            }
            if let arr = opts["exclude-apps"]?.asArray {
                options.excludeApps = arr.compactMap(\.asString)
            }
        }

        // [aliases] — flat `name = "command"` lookup. Validation is
        // minimal: only string values are accepted; anything else is
        // dropped with a warning.
        var aliases: [String: String] = [:]
        if case .table(let raw)? = root["aliases"] {
            for (key, value) in raw {
                if key == TOML.lineKey { continue }
                if let s = value.asString {
                    aliases[key] = s
                } else {
                    warnings.append(ConfigWarning(
                        kind: .aliasNonString,
                        message: "[aliases] '\(key)': value must be a string — ignored",
                        bindingName: key))
                }
            }
        }

        var bindings: [Binding] = []
        var dropped = 0
        let rows = root["bindings"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            if let b = makeBinding(from: row, index: i,
                                   isFallback: false,
                                   aliases: aliases,
                                   warnings: &warnings)
            {
                bindings.append(b)
            } else {
                dropped += 1
            }
        }

        var fallbacks: [Binding] = []
        let fbRows = root["fallbacks"]?.asArrayOfTables ?? []
        for (i, row) in fbRows.enumerated() {
            if let b = makeBinding(from: row, index: i,
                                   isFallback: true,
                                   aliases: aliases,
                                   warnings: &warnings)
            {
                fallbacks.append(b)
            } else {
                dropped += 1
            }
        }

        let cfg = ChordConfig(options: options, bindings: bindings,
                              fallbacks: fallbacks, aliases: aliases)
        return ParseResult(config: cfg, warnings: warnings,
                           droppedBindings: dropped, sourcePath: nil)
    }

    private static func makeBinding(
        from row: [String: TOML.Value], index: Int,
        isFallback: Bool,
        aliases: [String: String],
        warnings: inout [ConfigWarning]
    ) -> Binding? {
        let section = isFallback ? "[[fallbacks]]" : "[[bindings]]"
        let name = row["name"]?.asString ?? "binding-\(index + 1)"
        let line = row[TOML.lineKey]?.asInt.map { Int($0) }
        let source = sourceTag(line: line)
        guard let inputRaw = row["input"]?.asString else {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message: "\(section) '\(name)'\(source): missing 'input'",
                sourceLine: line, bindingName: name))
            return nil
        }
        let parsed: InputParser.Parsed
        do { parsed = try InputParser.parse(inputRaw,
                                            allowWildcard: isFallback) }
        catch {
            warnings.append(ConfigWarning(
                kind: .unknownInputToken,
                message: "\(section) '\(name)'\(source): \(error)",
                sourceLine: line, bindingName: name))
            return nil
        }
        let actionResult = parseAction(row: row,
                                       section: section,
                                       name: name,
                                       source: source,
                                       sourceLine: line,
                                       aliases: aliases,
                                       suffix: "",
                                       required: true,
                                       warnings: &warnings)
        guard let parsedAction = actionResult else { return nil }

        // On-up action: optional. Failure to parse drops the binding —
        // a broken on-up declaration is a user error, not silent
        // ignore (same severity as a broken primary action-keys).
        let onUpResult: ParsedAction?
        if hasOnUpAction(row: row) {
            onUpResult = parseAction(row: row,
                                     section: section,
                                     name: name,
                                     source: source,
                                     sourceLine: line,
                                     aliases: aliases,
                                     suffix: "-on-up",
                                     required: false,
                                     warnings: &warnings)
            if onUpResult == nil { return nil }
        } else {
            onUpResult = nil
        }

        // Optional v2 fields. Each parser returns nil for "field
        // absent", or appends a warning + drops the binding when the
        // field is present but malformed.
        guard let condition = parseCondition(row: row, section: section,
                                             name: name, source: source,
                                             sourceLine: line,
                                             warnings: &warnings)
        else { return nil }
        guard let holdWhile = parseHoldWhile(row: row, section: section,
                                             name: name, source: source,
                                             sourceLine: line,
                                             warnings: &warnings)
        else { return nil }

        var apps: [String]?
        if let arr = row["apps"]?.asArray {
            let strs = arr.compactMap(\.asString)
            apps = strs.isEmpty || strs == ["*"] ? nil : strs
        }

        return Binding(
            name: name, trigger: parsed.trigger,
            modifiers: parsed.modifiers, apps: apps,
            action: parsedAction.action,
            condition: condition.value,
            onUpAction: onUpResult?.action,
            holdWhile: holdWhile.value,
            inputRaw: inputRaw,
            actionRaw: parsedAction.raw,
            aliasName: parsedAction.aliasName,
            sourceLine: line)
    }

    /// True iff at least one `action-*-on-up` key is present in `row`.
    /// Lets `makeBinding` decide whether to even invoke the parser —
    /// keeps the absent-on-up case zero-cost.
    private static func hasOnUpAction(row: [String: TOML.Value]) -> Bool {
        row["action-shell-on-up"] != nil
            || row["action-keys-on-up"] != nil
            || row["action-noop-on-up"] != nil
            || row["action-set-var-on-up"] != nil
    }

    /// Pick the binding's [Action] from one of `action-shell` /
    /// `action-keys` / `action-noop` / `action-set-var`, expanding
    /// any `@name` alias on the shell path.
    ///
    /// `suffix` is `""` for the primary down action and `"-on-up"`
    /// for the optional release action. `required` controls whether
    /// the absence of every `action-*` key warns + drops — `true` for
    /// the primary, `false` for `-on-up` (caller already checked one
    /// was present before invoking).
    ///
    /// Returns `nil` and appends a warning when:
    ///   * no matching `action-*` key was provided (and `required`)
    ///   * `@name` references an alias not in `[aliases]`
    ///   * `action-keys` / `action-set-*` fails to parse
    private static func parseAction(
        row: [String: TOML.Value],
        section: String,
        name: String,
        source: String,
        sourceLine: Int?,
        aliases: [String: String],
        suffix: String = "",
        required: Bool = true,
        warnings: inout [ConfigWarning]
    ) -> ParsedAction? {
        let shellKey = "action-shell\(suffix)"
        let keysKey  = "action-keys\(suffix)"
        let noopKey  = "action-noop\(suffix)"
        let setKey   = "action-set-var\(suffix)"
        let setValKey = "action-set-value\(suffix)"
        let fieldLabel = suffix.isEmpty ? "" : " (on-up)"

        if let shell = row[shellKey]?.asString {
            switch resolveAlias(shell, aliases: aliases) {
            case .body(let body, let aliasName):
                return ParsedAction(action: .shell(body),
                                    raw: shell,
                                    aliasName: aliasName)
            case .undefined(let aliasName):
                // canon-specified warning format — kept
                // separately from the `[[bindings]] '…' (line): …`
                // format on purpose. The structured `.undefinedAlias`
                // kind lets machine consumers disambiguate.
                warnings.append(ConfigWarning(
                    kind: .undefinedAlias,
                    message:
                        "binding '\(name)'\(source)\(fieldLabel) " +
                        "references undefined alias '@\(aliasName)'; " +
                        "binding dropped",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
        }
        if let keysStr = row[keysKey]?.asString {
            do {
                let (mods, code) =
                    try InputParser.parseKeyForOutput(keysStr)
                return ParsedAction(action: .keys(mods, code),
                                    raw: keysStr,
                                    aliasName: nil)
            } catch {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(keysKey): \(error)",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
        }
        if row[noopKey]?.asBool == true {
            return ParsedAction(action: .noop, raw: nil, aliasName: nil)
        }
        if let varName = row[setKey]?.asString {
            // `action-set-value` defaults to 1 (the leader-key case).
            // Writing 0 explicitly unsets the variable; non-int is an
            // error.
            let value: Int
            if let raw = row[setValKey] {
                guard let v = raw.asInt else {
                    warnings.append(ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(source)\(fieldLabel): " +
                            "\(setValKey) must be an integer",
                        sourceLine: sourceLine, bindingName: name))
                    return nil
                }
                value = Int(v)
            } else {
                value = 1
            }
            return ParsedAction(action: .setVariable(name: varName, value: value),
                                raw: varName,
                                aliasName: nil)
        }
        if row[setValKey] != nil {
            // Orphan: action-set-value without action-set-var. Common
            // typo — surfacing it explicitly beats silently ignoring.
            warnings.append(ConfigWarning(
                kind: .actionSetParseError,
                message:
                    "\(section) '\(name)'\(source)\(fieldLabel): " +
                    "\(setValKey) present without \(setKey)",
                sourceLine: sourceLine, bindingName: name))
            return nil
        }
        if !required { return nil }
        warnings.append(ConfigWarning(
            kind: .missingAction,
            message: "\(section) '\(name)'\(source): no action-* key provided",
            sourceLine: sourceLine, bindingName: name))
        return nil
    }

    /// Parse the optional `when-var` / `when-var-value` pair into a
    /// [Condition]. Returns:
    ///   * `.some(.some(condition))` — field present and well-formed
    ///   * `.some(.none)`            — field absent (no gate)
    ///   * `.none`                   — field present but malformed
    ///                                 (caller drops the binding)
    private static func parseCondition(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Condition>? {
        let varName = row["when-var"]?.asString
        let rawValue = row["when-var-value"]
        if varName == nil && rawValue == nil {
            return OptionalParse(value: nil)
        }
        guard let varName = varName else {
            warnings.append(ConfigWarning(
                kind: .conditionParseError,
                message:
                    "\(section) '\(name)'\(source): " +
                    "when-var-value present without when-var",
                sourceLine: sourceLine, bindingName: name))
            return nil
        }
        // when-var-value defaults to 1 — matches the leader-key idiom.
        let value: Int
        if let raw = rawValue {
            guard let v = raw.asInt else {
                warnings.append(ConfigWarning(
                    kind: .conditionParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "when-var-value must be an integer",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            value = Int(v)
        } else {
            value = 1
        }
        return OptionalParse(value: .variable(name: varName, equals: value))
    }

    /// Parse the optional `hold-while = "cmd + opt"` field into a
    /// [Modifiers] mask. Same return convention as `parseCondition`.
    private static func parseHoldWhile(
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
                warnings.append(ConfigWarning(
                    kind: .holdWhileParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "hold-while must contain at least one modifier",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            return OptionalParse(value: mask)
        } catch {
            warnings.append(ConfigWarning(
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
    private struct OptionalParse<T> {
        let value: T?
    }

    /// Render the `(config.toml:42)` suffix attached to per-binding
    /// warnings. Returns the empty string when the parser couldn't
    /// resolve a line — better to drop the suffix than print
    /// "config.toml:?".
    private static func sourceTag(line: Int?) -> String {
        guard let line else { return "" }
        return " (config.toml:\(line))"
    }

    /// What `parseAction` hands back: the runtime `Action`, plus the
    /// raw user string (`action-shell` body or `action-keys` body)
    /// and the alias name when `@name` resolved successfully.
    private struct ParsedAction {
        let action: Action
        let raw: String?
        let aliasName: String?
    }

    private enum AliasResolution {
        /// Either no `@name` was used (`aliasName == nil`) or it
        /// resolved successfully (`aliasName == "rift_focus_next"`).
        case body(String, aliasName: String?)
        case undefined(String)
    }

    /// Resolve a single `@name` token at the start of the value
    /// against [aliases]. Anything else is passed through unchanged.
    ///
    /// `@name arg` syntax is reserved for a future expansion; in v1,
    /// a value of the form `@name arg` is treated as a literal
    /// command string (the user wrote it; we don't second-guess).
    private static func resolveAlias(_ raw: String,
                                     aliases: [String: String])
        -> AliasResolution
    {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return .body(raw, aliasName: nil) }
        let name = String(trimmed.dropFirst())
        guard name.allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }), !name.isEmpty else {
            // `@foo bar` or `@` alone falls through to literal.
            return .body(raw, aliasName: nil)
        }
        if let body = aliases[name] { return .body(body, aliasName: name) }
        return .undefined(name)
    }
}
