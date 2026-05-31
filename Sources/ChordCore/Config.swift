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

        // [actionAliases] — flat `name = "command"` lookup. Validation is
        // minimal: only string values are accepted; anything else is
        // dropped with a warning.
        var actionAliases: [String: String] = [:]
        if case .table(let raw)? = root["action-aliases"] {
            for (key, value) in raw {
                if key == TOML.lineKey { continue }
                if let s = value.asString {
                    actionAliases[key] = s
                } else {
                    warnings.append(ConfigWarning(
                        kind: .actionAliasNonString,
                        message: "[actionAliases] '\(key)': value must be a string — ignored",
                        bindingName: key))
                }
            }
        }

        // [input-aliases] — `name = "mod1 + mod2 + …"` lookup,
        // bare reference in `input = "…"`. Two parallel maps:
        //   * `inputAliasesRaw`: original case, used for schema /
        //     introspection output (`chord --list --json`).
        //   * `inputAliasesParsed`: lowercased keys → `Modifiers` mask,
        //     pre-validated. Passed to `InputParser.parse` so token
        //     resolution is a constant-time lookup (no body re-parse
        //     per binding).
        // Entries are rejected with a warning (not a hard error) when:
        //   * value isn't a string
        //   * name collides with a built-in modifier token — keeps
        //     `parse("cmd - a")` unambiguous
        //   * body fails to parse as a modifier list — bodies are
        //     constrained to built-in tokens only (no nested alias
        //     references; cycle-free by construction)
        var inputAliasesRaw: [String: String] = [:]
        var inputAliasesParsed: [String: Modifiers] = [:]
        if case .table(let raw)? = root["input-aliases"] {
            for (key, value) in raw {
                if key == TOML.lineKey { continue }
                let keyLower = key.lowercased()
                if InputParser.reservedModifierTokens.contains(keyLower) {
                    warnings.append(ConfigWarning(
                        kind: .inputAliasShadowsModifier,
                        message:
                            "[input-aliases] '\(key)': name shadows " +
                            "built-in modifier token — ignored",
                        bindingName: key))
                    continue
                }
                guard let s = value.asString else {
                    warnings.append(ConfigWarning(
                        kind: .inputAliasNonString,
                        message:
                            "[input-aliases] '\(key)': value must be a " +
                            "string — ignored",
                        bindingName: key))
                    continue
                }
                let mask: Modifiers
                do {
                    mask = try InputParser.parseModifiersOnly(s)
                } catch {
                    warnings.append(ConfigWarning(
                        kind: .inputAliasInvalidBody,
                        message:
                            "[input-aliases] '\(key)': \(error) — ignored",
                        bindingName: key))
                    continue
                }
                // Empty body is meaningless — same treatment as
                // hold-while: caller almost certainly mistyped.
                if mask.rawValue == 0 {
                    warnings.append(ConfigWarning(
                        kind: .inputAliasInvalidBody,
                        message:
                            "[input-aliases] '\(key)': must contain at " +
                            "least one modifier — ignored",
                        bindingName: key))
                    continue
                }
                inputAliasesRaw[key] = s
                inputAliasesParsed[keyLower] = mask
            }
        }

        // v0.7.0 sequence sugar: parse `[[sequence]]` rows first and
        // expand them into prefix + child bindings. The expansion
        // produces ordinary Binding values (no new runtime concepts),
        // and the expanded set is prepended to `[[bindings]]` so the
        // prefix wins over a regular binding with the same trigger
        // (= first-match-wins yields the documented "sequence wins"
        // semantics without needing an extra precedence dimension).
        let seq = parseSequences(root: root,
                                 actionAliases: actionAliases,
                                 inputAliases: inputAliasesParsed,
                                 warnings: &warnings)

        var bindings: [Binding] = seq.expanded
        var dropped = seq.dropped
        let rows = root["bindings"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            guard let b = makeBinding(from: row, index: i,
                                      isFallback: false,
                                      actionAliases: actionAliases,
                                      inputAliases: inputAliasesParsed,
                                      warnings: &warnings)
            else {
                dropped += 1
                continue
            }
            // Prefix collision: if a regular binding shares
            // (trigger, modifiers) with a sequence's prefix binding,
            // drop it with a warning. Children carry a `.variable`
            // condition so they don't collide in the same way; only
            // the prefix is unconditional.
            if let collision = seq.prefixes.first(where: { p in
                p.trigger == b.trigger && p.modifiers == b.modifiers
            }) {
                warnings.append(ConfigWarning(
                    kind: .sequenceParseError,
                    message:
                        "[[bindings]] '\(b.name)'\(sourceTag(line: b.sourceLine))" +
                        ": input '\(b.inputRaw)' collides with " +
                        "[[sequence]] prefix '\(collision.name)' — " +
                        "regular binding dropped (sequence wins)",
                    sourceLine: b.sourceLine, bindingName: b.name))
                dropped += 1
                continue
            }
            bindings.append(b)
        }

        var fallbacks: [Binding] = []
        let fbRows = root["fallbacks"]?.asArrayOfTables ?? []
        for (i, row) in fbRows.enumerated() {
            if let b = makeBinding(from: row, index: i,
                                   isFallback: true,
                                   actionAliases: actionAliases,
                                   inputAliases: inputAliasesParsed,
                                   warnings: &warnings)
            {
                fallbacks.append(b)
            } else {
                dropped += 1
            }
        }

        let cfg = ChordConfig(options: options, bindings: bindings,
                              fallbacks: fallbacks, actionAliases: actionAliases,
                              inputAliases: inputAliasesRaw)
        return ParseResult(config: cfg, warnings: warnings,
                           droppedBindings: dropped, sourcePath: nil)
    }

    // MARK: - Sequence sugar

    /// Result of expanding the `[[sequence]]` section:
    ///   • `expanded`  — prefix + child bindings in document order
    ///                   (per-sequence, prefix first then its children).
    ///   • `prefixes`  — just the prefix bindings, used by the main
    ///                   loop to detect collisions with regular
    ///                   `[[bindings]]` rows.
    ///   • `dropped`   — count of malformed sequences / children for
    ///                   the `--validate --strict` exit code.
    private struct SequenceParse {
        var expanded: [Binding]
        var prefixes: [Binding]
        var dropped: Int
    }

    /// Expand `[[sequence]]` rows into ordinary Binding values.
    /// Pure syntactic sugar over v2 state-var:
    ///   * the prefix becomes `action-set-var = "_seq_<name>"` with
    ///     `hold-while-timeout = <timeout-ms>`
    ///   * each child becomes a binding gated by `when-var = "_seq_<name>"`,
    ///     with its `input` composed as `"<prefix-modset> - <child input>"`
    /// Matcher / Controller see only the resulting bindings; there is
    /// no runtime concept of "sequence".
    ///
    /// Per the v0.7.0 issue, narrow surface intentionally:
    ///   * `timeout-ms` is required (the `hold-while` lifecycle does
    ///     not survive atomic ZMK chords, so the alternative would
    ///     defeat the leader-key use case)
    ///   * the prefix must include at least one modifier (a bare-key
    ///     leader would swallow every primary press)
    ///   * children's `input` are primary-only — they inherit the
    ///     prefix's modset
    ///   * nested `[[sequence.sequence]]` is rejected (out of scope)
    private static func parseSequences(
        root: [String: TOML.Value],
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        warnings: inout [ConfigWarning]
    ) -> SequenceParse {
        var expanded: [Binding] = []
        var prefixes: [Binding] = []
        var dropped = 0
        var seenNames: Set<String> = []

        let rows = root["sequence"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            let line = row[TOML.lineKey]?.asInt.map { Int($0) }
            let source = sourceTag(line: line)
            let rawName = row["name"]?.asString
            let seqName = rawName ?? "sequence-\(i + 1)"

            func failSeq(_ msg: String) {
                warnings.append(ConfigWarning(
                    kind: .sequenceParseError,
                    message: "[[sequence]] '\(seqName)'\(source): \(msg)",
                    sourceLine: line, bindingName: seqName))
                dropped += 1
            }

            // Reject `name = "_seq_..."` — the name maps directly to
            // the synthetic variable `_seq_<name>`, and `_seq_` is
            // the reservation surface we enforce on user `action-set-var`.
            if let n = rawName, n.hasPrefix("_seq_") {
                failSeq("sequence name must not start with '_seq_' (reserved)")
                continue
            }

            if seenNames.contains(seqName) {
                failSeq("duplicate sequence name (each sequence " +
                        "owns variable '_seq_\(seqName)' — names " +
                        "must be unique)")
                continue
            }
            seenNames.insert(seqName)

            if row["sequence"] != nil {
                failSeq("nested [[sequence.sequence]] is not supported")
                continue
            }

            guard let prefixRaw = row["prefix"]?.asString else {
                failSeq("missing 'prefix'")
                continue
            }
            guard let timeoutRaw = row["timeout-ms"]?.asInt else {
                failSeq("missing or non-integer 'timeout-ms'")
                continue
            }
            let timeoutMs = Int(timeoutRaw)
            guard timeoutMs > 0 else {
                failSeq("timeout-ms must be > 0 (got \(timeoutMs))")
                continue
            }

            // Verify the prefix parses and has at least one modifier.
            let prefixParsed: InputParser.Parsed
            do {
                prefixParsed = try InputParser.parse(
                    prefixRaw,
                    allowWildcard: false,
                    inputAliases: inputAliases)
            } catch {
                failSeq("prefix: \(error)")
                continue
            }
            guard prefixParsed.modifiers.rawValue != 0 else {
                failSeq("prefix must include at least one modifier " +
                        "(a bare-key leader would swallow every press)")
                continue
            }

            // Extract the modset substring from the prefix raw. The
            // InputParser splits on the first `-` whenever the whole
            // string isn't itself a primary token — since we just
            // verified prefixParsed.modifiers is non-empty, that branch
            // ran and the first `-` IS the separator.
            let trimmedPrefix = prefixRaw.trimmingCharacters(in: .whitespaces)
            guard let dashIdx = trimmedPrefix.firstIndex(of: "-") else {
                failSeq("internal error: prefix parsed with modifiers but no separator")
                continue
            }
            let modsetStr = String(trimmedPrefix[..<dashIdx])
                .trimmingCharacters(in: .whitespaces)

            let childRows = row["bindings"]?.asArrayOfTables ?? []
            guard !childRows.isEmpty else {
                failSeq("no [[sequence.bindings]] children declared")
                continue
            }

            let varName = "_seq_\(seqName)"

            // Prefix binding — synthesize a row and reuse makeBinding so
            // all the v2 validation (hold-while-timeout positive, etc.)
            // runs uniformly. allowReservedVarNames bypasses the
            // `_seq_*` guard for this synthetic row only.
            var prefixRow: [String: TOML.Value] = [
                "name": .string("\(seqName) [enter]"),
                "input": .string(prefixRaw),
                "action-set-var": .string(varName),
                "hold-while-timeout": .int(Int64(timeoutMs)),
            ]
            if let lv = row[TOML.lineKey] { prefixRow[TOML.lineKey] = lv }
            guard let prefixBinding = makeBinding(
                from: prefixRow, index: i, isFallback: false,
                actionAliases: actionAliases,
                inputAliases: inputAliases,
                allowReservedVarNames: true,
                warnings: &warnings)
            else {
                // makeBinding already appended its own warning.
                dropped += 1
                continue
            }
            expanded.append(prefixBinding)
            prefixes.append(prefixBinding)

            // Child bindings.
            for (ci, child) in childRows.enumerated() {
                let childLine = child[TOML.lineKey]?.asInt.map { Int($0) } ?? line
                let childSrc = sourceTag(line: childLine)
                let childName = child["name"]?.asString
                    ?? "\(seqName).\(ci + 1)"

                guard let childInputRaw = child["input"]?.asString else {
                    warnings.append(ConfigWarning(
                        kind: .missingInput,
                        message:
                            "[[sequence.bindings]] '\(childName)'\(childSrc): " +
                            "missing 'input'",
                        sourceLine: childLine, bindingName: childName))
                    dropped += 1
                    continue
                }

                // Compose: prefix modset + " - " + child primary.
                // Children are primary-only by design (issue spec) —
                // if the user wrote their own modifier prefix, the
                // composed string will fail to parse and makeBinding
                // surfaces a clear "unknown-input-token" warning.
                let composedInput = "\(modsetStr) - \(childInputRaw)"
                var childRow = child
                childRow["name"] = .string(childName)
                childRow["input"] = .string(composedInput)
                childRow["when-var"] = .string(varName)
                if childRow[TOML.lineKey] == nil,
                   let lv = row[TOML.lineKey] {
                    childRow[TOML.lineKey] = lv
                }

                if let b = makeBinding(
                    from: childRow, index: ci, isFallback: false,
                    actionAliases: actionAliases,
                    inputAliases: inputAliases,
                    allowReservedVarNames: true,
                    warnings: &warnings)
                {
                    expanded.append(b)
                } else {
                    dropped += 1
                }
            }
        }

        return SequenceParse(expanded: expanded, prefixes: prefixes,
                             dropped: dropped)
    }

    private static func makeBinding(
        from row: [String: TOML.Value], index: Int,
        isFallback: Bool,
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        allowReservedVarNames: Bool = false,
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
                                            allowWildcard: isFallback,
                                            inputAliases: inputAliases) }
        catch let e as InputParser.InputParseError {
            // Differentiate `$name` typos (undefinedInputAlias) from
            // plain modifier typos (unknownToken) so CI / schema
            // consumers can branch on the structured kind.
            let kind: ConfigWarning.Kind
            if case .undefinedInputAlias = e {
                kind = .undefinedInputAlias
            } else {
                kind = .unknownInputToken
            }
            warnings.append(ConfigWarning(
                kind: kind,
                message: "\(section) '\(name)'\(source): \(e)",
                sourceLine: line, bindingName: name))
            return nil
        }
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
                                       actionAliases: actionAliases,
                                       suffix: "",
                                       required: true,
                                       allowReservedVarNames: allowReservedVarNames,
                                       warnings: &warnings)
        guard let parsedAction = actionResult else { return nil }

        // Karabiner-style multi-action on down: when a binding
        // declares BOTH action-shell and action-keys, the shell runs
        // first (parseAction's precedence makes it the primary
        // `action`) and the keys are posted right after on the same
        // key-down. Only this pair combines — noop / set-var stay
        // single-action, so the existing first-wins precedence is
        // unchanged for every other combination.
        let extraDownActions: [Action]
        if case .shell = parsedAction.action,
           let keysStr = row["action-keys"]?.asString {
            do {
                let (mods, code) =
                    try InputParser.parseKeyForOutput(keysStr)
                extraDownActions = [.keys(mods, code)]
            } catch {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "action-keys: \(error)",
                    sourceLine: line, bindingName: name))
                return nil
            }
        } else {
            extraDownActions = []
        }

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
                                     actionAliases: actionAliases,
                                     suffix: "-on-up",
                                     required: false,
                                     allowReservedVarNames: allowReservedVarNames,
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
        guard let holdWhileTimeout = parseHoldWhileTimeout(
            row: row, section: section,
            name: name, source: source,
            sourceLine: line,
            warnings: &warnings)
        else { return nil }
        // hold-while and hold-while-timeout are mutually exclusive —
        // they pick different lifecycles for the same variable. The
        // user almost certainly meant one or the other; offer a clear
        // error rather than silently picking.
        if holdWhile.value != nil && holdWhileTimeout.value != nil {
            warnings.append(ConfigWarning(
                kind: .holdWhileParseError,
                message:
                    "\(section) '\(name)'\(source): " +
                    "hold-while and hold-while-timeout are mutually " +
                    "exclusive — pick one",
                sourceLine: line, bindingName: name))
            return nil
        }

        var apps: [String]?
        if let arr = row["apps"]?.asArray {
            let strs = arr.compactMap(\.asString)
            apps = strs.isEmpty || strs == ["*"] ? nil : strs
        }

        return Binding(
            name: name, trigger: parsed.trigger,
            modifiers: parsed.modifiers, apps: apps,
            action: parsedAction.action,
            extraDownActions: extraDownActions,
            condition: condition.value,
            onUpAction: onUpResult?.action,
            holdWhile: holdWhile.value,
            holdWhileTimeoutMs: holdWhileTimeout.value,
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
    ///   * `@name` references an alias not in `[actionAliases]`
    ///   * `action-keys` / `action-set-*` fails to parse
    private static func parseAction(
        row: [String: TOML.Value],
        section: String,
        name: String,
        source: String,
        sourceLine: Int?,
        actionAliases: [String: String],
        suffix: String = "",
        required: Bool = true,
        allowReservedVarNames: Bool = false,
        warnings: inout [ConfigWarning]
    ) -> ParsedAction? {
        let shellKey = "action-shell\(suffix)"
        let keysKey  = "action-keys\(suffix)"
        let noopKey  = "action-noop\(suffix)"
        let setKey   = "action-set-var\(suffix)"
        let setValKey = "action-set-value\(suffix)"
        let fieldLabel = suffix.isEmpty ? "" : " (on-up)"

        if let shell = row[shellKey]?.asString {
            switch resolveAlias(shell, actionAliases: actionAliases) {
            case .body(let body, let aliasName):
                return ParsedAction(action: .shell(body),
                                    raw: shell,
                                    aliasName: aliasName)
            case .undefined(let aliasName):
                // canon-specified warning format — kept
                // separately from the `[[bindings]] '…' (line): …`
                // format on purpose. The structured `.undefinedActionAlias`
                // kind lets machine consumers disambiguate.
                warnings.append(ConfigWarning(
                    kind: .undefinedActionAlias,
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
            // Reservation: `_seq_*` belongs to [[sequence]] expansion
            // (the synthetic variable each sequence owns). Reject user
            // writes to that namespace so a typo'd sequence name never
            // looks like a normal binding owning the var.
            if !allowReservedVarNames && varName.hasPrefix("_seq_") {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(setKey) name '_seq_*' is reserved for " +
                        "[[sequence]] expansion",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
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

    /// Parse the optional `hold-while-timeout = 800` field. Positive
    /// integer in milliseconds; 0 / negative is a user error and
    /// drops the binding (the field has no zero meaning — explicit
    /// clear uses `action-set-value = 0`).
    private static func parseHoldWhileTimeout(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> OptionalParse<Int>? {
        guard let raw = row["hold-while-timeout"] else {
            return OptionalParse(value: nil)
        }
        guard let v = raw.asInt else {
            warnings.append(ConfigWarning(
                kind: .holdWhileParseError,
                message:
                    "\(section) '\(name)'\(source): " +
                    "hold-while-timeout must be an integer (ms)",
                sourceLine: sourceLine, bindingName: name))
            return nil
        }
        let ms = Int(v)
        guard ms > 0 else {
            warnings.append(ConfigWarning(
                kind: .holdWhileParseError,
                message:
                    "\(section) '\(name)'\(source): " +
                    "hold-while-timeout must be > 0 (got \(ms))",
                sourceLine: sourceLine, bindingName: name))
            return nil
        }
        return OptionalParse(value: ms)
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
    /// against [actionAliases]. Anything else is passed through unchanged.
    ///
    /// `@name arg` syntax is reserved for a future expansion; in v1,
    /// a value of the form `@name arg` is treated as a literal
    /// command string (the user wrote it; we don't second-guess).
    private static func resolveAlias(_ raw: String,
                                     actionAliases: [String: String])
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
        if let body = actionAliases[name] { return .body(body, aliasName: name) }
        return .undefined(name)
    }
}
