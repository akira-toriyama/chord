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
        public var warnings: [String]
        public var droppedBindings: Int
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
            return ParseResult(config: .init(),
                               warnings: ["config not found at \(path)"],
                               droppedBindings: 0)
        }
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) }
        catch { throw LoadError.ioError("read \(path): \(error)") }
        return try parse(source)
    }

    public static func parse(_ source: String) throws -> ParseResult {
        let root: [String: TOML.Value]
        do { root = try TOML.parse(source) }
        catch let e as TOML.ParseError { throw LoadError.tomlError(String(describing: e)) }
        catch { throw LoadError.tomlError(String(describing: error)) }

        var warnings: [String] = []
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
                    warnings.append(
                        "[aliases] '\(key)': value must be a string — ignored")
                }
            }
        }

        var bindings: [Binding] = []
        var dropped = 0
        let rows = root["bindings"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            do {
                if let b = try makeBinding(from: row, index: i,
                                           isFallback: false,
                                           aliases: aliases,
                                           warnings: &warnings)
                {
                    bindings.append(b)
                } else {
                    dropped += 1
                }
            } catch {
                dropped += 1
                warnings.append(
                    "[[bindings]] #\(i + 1): \(error) — dropped")
            }
        }

        var fallbacks: [Binding] = []
        let fbRows = root["fallbacks"]?.asArrayOfTables ?? []
        for (i, row) in fbRows.enumerated() {
            do {
                if let b = try makeBinding(from: row, index: i,
                                           isFallback: true,
                                           aliases: aliases,
                                           warnings: &warnings)
                {
                    fallbacks.append(b)
                } else {
                    dropped += 1
                }
            } catch {
                dropped += 1
                warnings.append(
                    "[[fallbacks]] #\(i + 1): \(error) — dropped")
            }
        }

        let cfg = ChordConfig(options: options, bindings: bindings,
                              fallbacks: fallbacks, aliases: aliases)
        return ParseResult(config: cfg, warnings: warnings,
                           droppedBindings: dropped)
    }

    private static func makeBinding(
        from row: [String: TOML.Value], index: Int,
        isFallback: Bool,
        aliases: [String: String],
        warnings: inout [String]
    ) throws -> Binding? {
        let section = isFallback ? "[[fallbacks]]" : "[[bindings]]"
        let name = row["name"]?.asString ?? "binding-\(index + 1)"
        let source = sourceTag(row: row)
        guard let inputRaw = row["input"]?.asString else {
            warnings.append(
                "\(section) '\(name)'\(source): missing 'input'")
            return nil
        }
        let parsed: InputParser.Parsed
        do { parsed = try InputParser.parse(inputRaw,
                                            allowWildcard: isFallback) }
        catch {
            warnings.append("\(section) '\(name)'\(source): \(error)")
            return nil
        }
        guard let action = parseAction(row: row,
                                       section: section,
                                       name: name,
                                       source: source,
                                       aliases: aliases,
                                       warnings: &warnings)
        else { return nil }

        var apps: [String]?
        if let arr = row["apps"]?.asArray {
            let strs = arr.compactMap(\.asString)
            apps = strs.isEmpty || strs == ["*"] ? nil : strs
        }

        return Binding(name: name, trigger: parsed.trigger,
                       modifiers: parsed.modifiers, apps: apps,
                       action: action)
    }

    /// Pick the binding's [Action] from `action-shell` / `action-keys`
    /// / `action-noop`, expanding any `@name` alias along the way.
    ///
    /// Returns `nil` and appends a warning when:
    ///   * no `action-*` key was provided
    ///   * `@name` references an alias not in `[aliases]`
    ///   * `action-keys` fails to parse
    ///
    /// TODO(PR2 / chord.bindings.v1.json): the warning strings here
    /// are human-readable only. PR2's `--list --json` schema will
    /// need a structured `kind:` discriminator (e.g.
    /// `"undefined-alias"` / `"action-keys-parse-error"` /
    /// `"missing-action"`) so machine consumers can distinguish them
    /// without grepping the message. Promote `warnings: [String]` to
    /// `warnings: [ConfigWarning]` (kind + message + source line)
    /// when PR2 lands.
    private static func parseAction(
        row: [String: TOML.Value],
        section: String,
        name: String,
        source: String,
        aliases: [String: String],
        warnings: inout [String]
    ) -> Action? {
        if let shell = row["action-shell"]?.asString {
            switch resolveAlias(shell, aliases: aliases) {
            case .body(let body):
                return .shell(body)
            case .undefined(let aliasName):
                // capsule-corp-specified warning format — kept
                // separately from the `[[bindings]] '…' (line): …`
                // format on purpose. See note above re: PR2 schema.
                warnings.append(
                    "binding '\(name)'\(source) references undefined " +
                    "alias '@\(aliasName)'; binding dropped")
                return nil
            }
        }
        if let keysStr = row["action-keys"]?.asString {
            do {
                let (mods, code) =
                    try InputParser.parseKeyForOutput(keysStr)
                return .keys(mods, code)
            } catch {
                warnings.append(
                    "\(section) '\(name)'\(source): action-keys: \(error)")
                return nil
            }
        }
        if row["action-noop"]?.asBool == true {
            return .noop
        }
        warnings.append(
            "\(section) '\(name)'\(source): no action-* key provided")
        return nil
    }

    /// Render the `(config.toml:42)` suffix attached to per-binding
    /// warnings. Returns the empty string if the parser couldn't
    /// resolve a line — better to drop the suffix than print
    /// "config.toml:?".
    private static func sourceTag(row: [String: TOML.Value]) -> String {
        guard let line = row[TOML.lineKey]?.asInt else { return "" }
        return " (config.toml:\(line))"
    }

    private enum AliasResolution {
        case body(String)         // `@name` resolved, or no alias used
        case undefined(String)    // `@name` references an unknown alias
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
        guard trimmed.hasPrefix("@") else { return .body(raw) }
        // `@name` only — no whitespace splitting yet (reserved).
        let name = String(trimmed.dropFirst())
        guard name.allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }), !name.isEmpty else {
            // `@foo bar` or `@` alone falls through to literal.
            return .body(raw)
        }
        if let body = aliases[name] { return .body(body) }
        return .undefined(name)
    }
}
