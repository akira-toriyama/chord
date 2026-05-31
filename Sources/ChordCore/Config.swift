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
            if let b = opts["fn-auto-arrows"]?.asBool {
                options.fnAutoArrows = b
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
        var bindingIndex = 0
        for row in rows {
            // v0.8.0 per-app sugar: a `[[bindings]]` row with a
            // `[[bindings.per-app]]` AoT child expands to N siblings,
            // one per per-app entry, with `apps = [bundle-id]` and
            // the entry's action-* fields layered onto the base row.
            let synthRows: [[String: TOML.Value]]
            switch expandBindingPerApp(row, warnings: &warnings) {
            case .single(let r): synthRows = [r]
            case .many(let rs):  synthRows = rs
            case .invalid:       dropped += 1; continue
            }

            for synth in synthRows {
                guard let b = makeBinding(from: synth, index: bindingIndex,
                                          isFallback: false,
                                          actionAliases: actionAliases,
                                          inputAliases: inputAliasesParsed,
                                          warnings: &warnings)
                else {
                    dropped += 1
                    continue
                }
                bindingIndex += 1
                // Sequence-prefix collision: a regular binding sharing
                // (trigger, modifiers) with a `[[sequence]]` prefix is
                // dropped with a warning (sequence wins, document order).
                // Children carry a `.variable` condition so they don't
                // collide unconditionally.
                if let collision = seq.prefixes.first(where: { p in
                    p.trigger == b.trigger && p.modifiers == b.modifiers
                }) {
                    warnings.append(ConfigWarning(
                        kind: .sequenceParseError,
                        message:
                            "[[bindings]] '\(b.name)'" +
                            sourceTag(line: b.sourceLine) +
                            ": input '\(b.inputRaw)' collides with " +
                            "[[sequence]] prefix '\(collision.name)' — " +
                            "regular binding dropped (sequence wins)",
                        sourceLine: b.sourceLine, bindingName: b.name))
                    dropped += 1
                    continue
                }
                bindings.append(b)
            }
        }

        // v0.8.0 [[remap]] sugar: expand each row into N action-keys
        // bindings (one per `map` entry). Appended AFTER regular
        // bindings so a specific `[[bindings]]` row can override a
        // bulk remap entry via first-match-wins.
        let remap = parseRemaps(root: root,
                                actionAliases: actionAliases,
                                inputAliases: inputAliasesParsed,
                                warnings: &warnings)
        bindings.append(contentsOf: remap.expanded)
        dropped += remap.dropped

        var fallbacks: [Binding] = []
        let fbRows = root["fallbacks"]?.asArrayOfTables ?? []
        var fbExpansionIndex = 0
        for row in fbRows {
            let expanded = expandFallbackRow(row,
                                             warnings: &warnings)
            switch expanded {
            case .single(let r):
                if let b = makeBinding(from: r, index: fbExpansionIndex,
                                       isFallback: true,
                                       actionAliases: actionAliases,
                                       inputAliases: inputAliasesParsed,
                                       warnings: &warnings)
                {
                    fallbacks.append(b)
                    fbExpansionIndex += 1
                } else {
                    dropped += 1
                }
            case .many(let rows):
                for r in rows {
                    if let b = makeBinding(from: r, index: fbExpansionIndex,
                                           isFallback: true,
                                           actionAliases: actionAliases,
                                           inputAliases: inputAliasesParsed,
                                           warnings: &warnings)
                    {
                        fallbacks.append(b)
                        fbExpansionIndex += 1
                    } else {
                        dropped += 1
                    }
                }
            case .invalid:
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

    // MARK: - Remap table sugar (chord 0.8.0+)

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
    private static func parseRemaps(
        root: [String: TOML.Value],
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        warnings: inout [ConfigWarning]
    ) -> (expanded: [Binding], dropped: Int) {
        var expanded: [Binding] = []
        var dropped = 0
        let rows = root["remap"]?.asArrayOfTables ?? []
        for (ri, row) in rows.enumerated() {
            let line = row[TOML.lineKey]?.asInt.map { Int($0) }
            let source = sourceTag(line: line)
            let baseName = row["name"]?.asString ?? "remap-\(ri + 1)"

            func failRemap(_ msg: String) {
                warnings.append(ConfigWarning(
                    kind: .remapParseError,
                    message: "[[remap]] '\(baseName)'\(source): \(msg)",
                    sourceLine: line, bindingName: baseName))
                dropped += 1
            }

            guard let modsRaw = row["modifiers"]?.asString,
                  !modsRaw.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                failRemap("missing 'modifiers' (bare-key remap is not allowed)")
                continue
            }
            do {
                let mask = try InputParser.parseModifiersOnly(
                    modsRaw, inputAliases: inputAliases)
                guard mask.rawValue != 0 else {
                    failRemap("modifiers resolved to an empty mask " +
                              "(at least one modifier required)")
                    continue
                }
            } catch {
                failRemap("modifiers: \(error)")
                continue
            }

            guard let mapValue = row["map"] else {
                failRemap("missing 'map' (inline table of key → action-keys)")
                continue
            }
            guard case .table(let mapTable) = mapValue else {
                failRemap("'map' must be an inline table " +
                          "(`{ b = \"left\", … }`)")
                continue
            }
            if mapTable.isEmpty {
                failRemap("map must contain at least one entry")
                continue
            }

            // Sort by key for deterministic ordering. Inline-table key
            // iteration is unordered in Swift dictionaries, and that
            // would surface as non-deterministic `--list --json` output.
            for key in mapTable.keys.sorted() {
                let entryName = "\(baseName).\(key)"
                guard let valueStr = mapTable[key]?.asString else {
                    warnings.append(ConfigWarning(
                        kind: .remapParseError,
                        message:
                            "[[remap]] '\(baseName)'\(source): " +
                            "map['\(key)']: value must be a string " +
                            "(interpreted as action-keys)",
                        sourceLine: line, bindingName: entryName))
                    dropped += 1
                    continue
                }
                let composedInput = "\(modsRaw) - \(key)"
                var synth: [String: TOML.Value] = [
                    "name": .string(entryName),
                    "input": .string(composedInput),
                    "action-keys": .string(valueStr),
                ]
                if let apps = row["apps"] { synth["apps"] = apps }
                if let lv = row[TOML.lineKey] { synth[TOML.lineKey] = lv }
                if let b = makeBinding(from: synth, index: ri,
                                       isFallback: false,
                                       actionAliases: actionAliases,
                                       inputAliases: inputAliases,
                                       warnings: &warnings) {
                    expanded.append(b)
                } else {
                    dropped += 1
                }
            }
        }
        return (expanded, dropped)
    }

    // MARK: - Row expansion (per-app, fallback inputs[])

    /// Outcome of inspecting a single row for sugar that fans out
    /// into multiple synthesised rows. Used by both `[[fallbacks]]
    /// inputs[]` (chord 0.8.0+) and `[[bindings]] [[bindings.per-app]]`
    /// (chord 0.8.0+).
    private enum RowExpansion {
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
    private static func expandBindingPerApp(
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
            "when-var", "when-var-value",
            "hold-while", "hold-while-timeout",
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

    // MARK: - Fallback inputs[] expansion (chord 0.8.0+)

    /// Alias for clarity — fallback expansion uses the same outcome shape.
    private typealias FallbackExpansion = RowExpansion

    /// Validate + expand `[[fallbacks]]` `inputs = [a, b, c]` sugar
    /// into N synthesised rows. Each expansion clones the original
    /// row, replaces `input` with one element, and (when the user
    /// provided a `name`) appends `" — <input>"` so warnings /
    /// `--list --json` distinguish the siblings.
    ///
    /// The `__line__` synthetic metadata key is preserved verbatim
    /// across expansions (all expanded fallbacks attribute back to
    /// the source `[[fallbacks]]` header line).
    private static func expandFallbackRow(
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

        // Multi-action on down. Three sources combine here:
        //   1. action-shell as primary + sibling action-keys (string or
        //      array — chord 0.9.0+). Karabiner-style: shell first, then
        //      one or more synthetic key posts.
        //   2. action-keys ARRAY as primary (chord 0.9.0+). parseAction
        //      already split the first element into `action` and parked
        //      the rest in `parsedAction.extraKeys`.
        //   3. All other primaries (noop / setVariable): no extras.
        let extraDownActions: [Action]
        if case .shell = parsedAction.action,
           let keysVal = row["action-keys"] {
            do {
                let parsed = try parseKeysListValue(keysVal)
                extraDownActions = parsed.map { .keys($0.0, $0.1) }
            } catch {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "action-keys: \(error)",
                    sourceLine: line, bindingName: name))
                return nil
            }
        } else if !parsedAction.extraKeys.isEmpty {
            extraDownActions = parsedAction.extraKeys
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

        // chord 0.9.0+ passthrough: fire action AND let the original
        // event reach the OS. Restricted to `action-shell` only —
        // posting `action-keys` while the original passes through
        // would deliver two key events (duplicate). On-up doesn't
        // fire either (we never register pendingUps), so reject that
        // combination explicitly. `noop` + passthrough is also
        // nonsense (the whole point of noop is to consume).
        var passthrough = false
        if let raw = row["passthrough"]?.asBool {
            passthrough = raw
        }
        if passthrough {
            if !extraDownActions.isEmpty {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "passthrough is incompatible with action-keys " +
                        "(the original event already reaches the OS)",
                    sourceLine: line, bindingName: name))
                return nil
            }
            switch parsedAction.action {
            case .keys:
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "passthrough requires action-shell (or no action) — " +
                        "action-keys would duplicate the keystroke",
                    sourceLine: line, bindingName: name))
                return nil
            case .noop:
                warnings.append(ConfigWarning(
                    kind: .missingAction,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "passthrough is incompatible with action-noop " +
                        "(noop = absorb; passthrough = relay)",
                    sourceLine: line, bindingName: name))
                return nil
            case .shell, .setVariable:
                break
            }
            if onUpResult != nil {
                warnings.append(ConfigWarning(
                    kind: .missingAction,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "passthrough cannot carry an action-*-on-up — " +
                        "no paired-up is captured when the event flows through",
                    sourceLine: line, bindingName: name))
                return nil
            }
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
            passthrough: passthrough,
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
            case .callError(let aliasName, let msg):
                warnings.append(ConfigWarning(
                    kind: .actionAliasCallError,
                    message:
                        "binding '\(name)'\(source)\(fieldLabel) " +
                        "@\(aliasName) call error: \(msg); binding dropped",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
        }
        if let keysVal = row[keysKey] {
            // chord 0.9.0+: action-keys accepts string OR string array.
            // - string  → single .keys action, no extras
            // - array   → primary = .keys(first), extras = .keys(rest...)
            //   Carried in `ParsedAction.extraKeys` so the caller can
            //   layer extras onto Binding.extraDownActions.
            // on-up does not support arrays (Binding.onUpAction holds
            // a single Action; multiple wouldn't fire).
            let parsed: [(Modifiers, UInt16)]
            do {
                parsed = try parseKeysListValue(keysVal)
            } catch {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(keysKey): \(error)",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if parsed.isEmpty {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(keysKey): must contain at least one keystroke",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if !suffix.isEmpty && parsed.count > 1 {
                warnings.append(ConfigWarning(
                    kind: .actionKeysParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(keysKey): array form is not supported for on-up " +
                        "(use a single string)",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            let (mods, code) = parsed[0]
            let extras = parsed.dropFirst().map { Action.keys($0.0, $0.1) }
            let rawString = keysVal.asString
            return ParsedAction(action: .keys(mods, code),
                                extraKeys: Array(extras),
                                raw: rawString,
                                aliasName: nil)
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
        /// chord 0.9.0+: when `action-keys = [a, b, …]` (array form),
        /// the first element becomes `action`, the rest are surfaced
        /// here so makeBinding can drop them onto `extraDownActions`.
        /// Empty for the common single-string action-keys path and
        /// for shell / noop / setVariable.
        let extraKeys: [Action]
        let raw: String?
        let aliasName: String?

        init(action: Action,
             extraKeys: [Action] = [],
             raw: String? = nil,
             aliasName: String? = nil) {
            self.action = action
            self.extraKeys = extraKeys
            self.raw = raw
            self.aliasName = aliasName
        }
    }

    /// Parse `action-keys` value (string or array) into one or more
    /// (Modifiers, keycode) pairs. Used by both primary and on-up
    /// action-keys paths.
    private static func parseKeysListValue(
        _ v: TOML.Value
    ) throws -> [(Modifiers, UInt16)] {
        if let s = v.asString {
            return [try InputParser.parseKeyForOutput(s)]
        }
        if let arr = v.asArray {
            var out: [(Modifiers, UInt16)] = []
            for (i, item) in arr.enumerated() {
                guard let s = item.asString else {
                    throw InputParser.InputParseError.unknownToken(
                        "non-string element at index \(i)",
                        context: "action-keys array")
                }
                out.append(try InputParser.parseKeyForOutput(s))
            }
            return out
        }
        throw InputParser.InputParseError.unknownToken(
            "action-keys must be a string or array of strings",
            context: "action-keys")
    }

    private enum AliasResolution {
        /// Either no `@name` was used (`aliasName == nil`) or it
        /// resolved successfully (`aliasName == "rift_focus_next"`).
        case body(String, aliasName: String?)
        case undefined(String)
        /// chord 0.9.0+: `@name(args)` call-site error — alias body
        /// has `{{N}}` placeholder but the call doesn't supply enough
        /// args, or the parenthesised arg list is malformed.
        case callError(aliasName: String, message: String)
    }

    /// Resolve a single `@name` or `@name(arg1, arg2, …)` token at
    /// the start of the value against [actionAliases]. Anything else
    /// is passed through unchanged.
    ///
    /// `@name(args)` (chord 0.9.0+) parses parenthesised arguments and
    /// substitutes them into `{{1}}` `{{2}}` … placeholders in the
    /// alias body. The substitution is **literal** (no shell escape):
    /// the user is expected to add their own quoting in the alias body
    /// (e.g. `afplay "{{1}}.wav"`). This matches the issue example and
    /// keeps the implementation small; tighter escape semantics can be
    /// added later if needed.
    ///
    /// `@name` (no parens) still works for unparameterised aliases.
    /// Mixing — a body with `{{N}}` but the call site uses bare
    /// `@name`, or vice versa — surfaces a structured `.callError`.
    private static func resolveAlias(_ raw: String,
                                     actionAliases: [String: String])
        -> AliasResolution
    {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return .body(raw, aliasName: nil) }

        // Read the identifier after `@` up to either '(' or end /
        // whitespace. The identifier charset is the same as before:
        // letter / digit / underscore / hyphen.
        let afterAt = trimmed.dropFirst()
        var nameEnd = afterAt.startIndex
        while nameEnd < afterAt.endIndex {
            let c = afterAt[nameEnd]
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                nameEnd = afterAt.index(after: nameEnd)
            } else { break }
        }
        let name = String(afterAt[..<nameEnd])
        if name.isEmpty {
            return .body(raw, aliasName: nil)
        }
        let rest = String(afterAt[nameEnd...])

        // Bare `@name` (no parens): existing v1 path.
        if rest.isEmpty {
            return resolveBareAlias(name: name, body: nil,
                                    actionAliases: actionAliases)
        }
        // `@name(...)` call form.
        if rest.hasPrefix("(") {
            // The closing paren must terminate the value (no trailing
            // junk like `@name() trailing`); else fall through to
            // literal so the user's `@name(typo` doesn't silently
            // become a partial alias call.
            guard rest.hasSuffix(")") else {
                return .body(raw, aliasName: nil)
            }
            let inner = String(rest.dropFirst().dropLast())
            let args = parseAliasCallArgs(inner)
            return resolveCallAlias(name: name, args: args,
                                    actionAliases: actionAliases)
        }
        // `@name arg` (no parens, trailing text). Treat as literal —
        // the v1 spec carve-out, kept so users with whitespace-quoted
        // shell shorthand don't suddenly hit an alias error.
        return .body(raw, aliasName: nil)
    }

    /// Bare `@name` resolution. `body` is unused (alias call form
    /// passes its own substituted body through `resolveCallAlias`).
    private static func resolveBareAlias(
        name: String, body: String?,
        actionAliases: [String: String]
    ) -> AliasResolution {
        guard let body = actionAliases[name] else {
            return .undefined(name)
        }
        // Body has `{{N}}` but the user called bare? Reject — running
        // the body verbatim would leak `{{N}}` into the shell.
        if maxPlaceholder(in: body) > 0 {
            return .callError(
                aliasName: name,
                message:
                    "alias '\(name)' uses {{N}} placeholders — " +
                    "call it as @\(name)(arg) with arguments")
        }
        return .body(body, aliasName: name)
    }

    private static func resolveCallAlias(
        name: String, args: [String],
        actionAliases: [String: String]
    ) -> AliasResolution {
        guard let body = actionAliases[name] else {
            return .undefined(name)
        }
        let needed = maxPlaceholder(in: body)
        if needed > args.count {
            return .callError(
                aliasName: name,
                message:
                    "alias '\(name)' needs {{\(needed)}} but only " +
                    "\(args.count) argument(s) supplied at call site")
        }
        // Substitute {{1}}…{{N}} in the body. Literal substitution —
        // see resolveAlias docstring for the escape contract.
        var substituted = body
        for i in (1...max(needed, 1)).reversed() {
            // Reverse order so that `{{10}}` (if ever supported) isn't
            // accidentally hit by the `{{1}}` pass. Currently single-
            // digit only but cheap to be defensive.
            guard i <= args.count else { continue }
            substituted = substituted.replacingOccurrences(
                of: "{{\(i)}}", with: args[i - 1])
        }
        return .body(substituted, aliasName: name)
    }

    /// Walk an alias body and return the highest `{{N}}` placeholder
    /// number (1-based). Returns 0 when no placeholder is present.
    /// Limited to single-digit N to keep the scan trivial — chord's
    /// shell-action surface never needs more than a handful of args.
    private static func maxPlaceholder(in body: String) -> Int {
        var maxN = 0
        let chars = Array(body)
        var i = 0
        while i + 4 < chars.count {
            if chars[i] == "{" && chars[i + 1] == "{",
               let d = chars[i + 2].wholeNumberValue,
               chars[i + 3] == "}", chars[i + 4] == "}",
               d > 0
            {
                if d > maxN { maxN = d }
                i += 5
                continue
            }
            i += 1
        }
        return maxN
    }

    /// Split the inside of `@name(...)` on commas, respecting double
    /// and single quotes. Bare args are trimmed; quoted args have
    /// the surrounding quotes stripped (contents kept verbatim).
    /// Empty input → empty args list. Whitespace-only segments drop.
    private static func parseAliasCallArgs(_ inner: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inStr = false
        var quote: Character = "\""
        for c in inner {
            if inStr {
                if c == quote { inStr = false }
                else { current.append(c) }
            } else if c == "\"" || c == "'" {
                inStr = true
                quote = c
            } else if c == "," {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty || !out.isEmpty {
                    out.append(trimmed)
                }
                current = ""
            } else {
                current.append(c)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty || !out.isEmpty {
            out.append(trimmed)
        }
        return out
    }
}
