import Foundation

/// Parses TOML → [ChordConfig]. Out-of-range / unknown values are
/// *clamped* or *dropped* with a warning rather than rejected — a
/// typo in one binding can never disable the whole daemon. The
/// strict-rejection path is `chord config --validate`, which surfaces
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
                warnings: [
                    ConfigWarning(
                        kind: .configNotFound,
                        message: "config not found at \(path)")
                ],
                droppedBindings: 0,
                sourcePath: path)
        }
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) } catch {
            throw LoadError.ioError("read \(path): \(error)")
        }
        var result = try parse(source)
        result.sourcePath = path
        return result
    }

    public static func parse(_ source: String) throws -> ParseResult {
        // t-0030: parse via `parseWithSpans` — the same nested strict tree
        // (equivalence is CI-gated in swift-toml-edit), re-derived from the
        // lossless DOM. `spanned.entrySpans` / `.headerSpans` are the
        // per-entry line+column index behind every field-precise
        // `(config.toml:N:C)` warning below (resolved per row via
        // `rowSpans` / `tableSpans`, Config+Spans.swift).
        let spanned: TOML.SpannedTree
        do { spanned = try TOML.parseWithSpans(source) } catch let e as TOML.ParseError {
            throw LoadError.tomlError(String(describing: e))
        } catch { throw LoadError.tomlError(String(describing: error)) }
        let root = spanned.tree

        var warnings: [ConfigWarning] = []
        var options = ChordConfig.Options()

        // #52-bounded: descriptor-driven structural validation — warn on
        // unknown keys in the array-of-tables sections ([[bindings]] /
        // [[fallbacks]] / [[sequence]] / [[remap]]) and their nested rows.
        // [options] is checked inline below; open string maps ([action-
        // aliases] / [input-aliases]) accept any key by design.
        warnings.append(
            contentsOf:
                ChordConfigSchema.unknownKeyWarnings(spanned: spanned))

        if case .table(let opts)? = root["options"] {
            let optSpans = tableSpans(
                keys: opts.keys, at: [.key("options")], in: spanned)
            // t-0055: surface present-but-wrong-type. The reads below keep
            // their `?.asBool` / `?.asArray` guards (which fall through to
            // the default on a type miss); these calls only make that
            // otherwise-silent skip visible. Correct / absent → no warning.
            warnFieldType(
                opts, key: "passthrough-unmatched",
                accept: ["boolean"],
                label: "[options] 'passthrough-unmatched'",
                spans: optSpans,
                warnings: &warnings)
            if let b = opts["passthrough-unmatched"]?.asBool {
                options.passthroughUnmatched = b
            }
            warnFieldType(
                opts, key: "exclude-apps", accept: ["array"],
                label: "[options] 'exclude-apps'",
                spans: optSpans,
                warnings: &warnings)
            warnArrayElementTypes(
                opts, key: "exclude-apps",
                label: "[options] 'exclude-apps'",
                spans: optSpans,
                warnings: &warnings)
            if let arr = opts["exclude-apps"]?.asArray {
                options.excludeApps = arr.compactMap(\.asString)
            }
            warnFieldType(
                opts, key: "fn-auto-arrows", accept: ["boolean"],
                label: "[options] 'fn-auto-arrows'",
                spans: optSpans,
                warnings: &warnings)
            if let b = opts["fn-auto-arrows"]?.asBool {
                options.fnAutoArrows = b
            }
            // Surface typos: `passthroughUnmatched` (camelCase),
            // `exclude_apps` (underscore), etc. would otherwise look
            // exactly like the binding worked but had no effect.
            // #52-bounded: the known-key set is sourced from the
            // descriptor (the same single source as `--emit-schema`),
            // so it can't drift. `[options]` is a plain `[table]`, which
            // never carried a synthetic line key.
            let known = ChordConfigSchema.optionsShape().keySet
            for key in opts.keys where !known.contains(key) {
                let span = optSpans.key(key)
                warnings.append(
                    ConfigWarning(
                        kind: .unknownOptionKey,
                        message:
                            "[options] '\(key)'\(sourceTag(span)): unknown option key — "
                            + "ignored (known: \(known.sorted().joined(separator: ", ")))",
                        source: span))
            }
        }

        // [action-aliases] — flat `name = "command"` lookup. Validation is
        // minimal: only string values are accepted; anything else is
        // dropped with a warning.
        var actionAliases: [String: String] = [:]
        if case .table(let raw)? = root["action-aliases"] {
            let aliasSpans = tableSpans(
                keys: raw.keys, at: [.key("action-aliases")], in: spanned)
            for (key, value) in raw {
                if let s = value.asString {
                    actionAliases[key] = s
                } else {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .actionAliasNonString,
                            message:
                                "[action-aliases] '\(key)'\(sourceTag(span)): "
                                + "value must be a string — ignored",
                            source: span, bindingName: key))
                }
            }
        }

        // [input-aliases] — `name = "mod1 + mod2 + …"` lookup,
        // bare reference in `input = "…"`. Two parallel maps:
        //   * `inputAliasesRaw`: original case, used for schema /
        //     introspection output (`chord config --show --json`).
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
            let aliasSpans = tableSpans(
                keys: raw.keys, at: [.key("input-aliases")], in: spanned)
            for (key, value) in raw {
                let keyLower = key.lowercased()
                if InputParser.reservedModifierTokens.contains(keyLower) {
                    let span = aliasSpans.key(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .inputAliasShadowsModifier,
                            message:
                                "[input-aliases] '\(key)'\(sourceTag(span)): name shadows "
                                + "built-in modifier token — ignored",
                            source: span, bindingName: key))
                    continue
                }
                guard let s = value.asString else {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .inputAliasNonString,
                            message:
                                "[input-aliases] '\(key)'\(sourceTag(span)): "
                                + "value must be a string — ignored",
                            source: span, bindingName: key))
                    continue
                }
                let mask: Modifiers
                do {
                    mask = try InputParser.parseModifiersOnly(s)
                } catch {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .inputAliasInvalidBody,
                            message:
                                "[input-aliases] '\(key)'\(sourceTag(span)): \(error) — ignored",
                            source: span, bindingName: key))
                    continue
                }
                // Empty body is meaningless — same treatment as
                // hold-while: caller almost certainly mistyped.
                if mask.rawValue == 0 {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .inputAliasInvalidBody,
                            message:
                                "[input-aliases] '\(key)'\(sourceTag(span)): must contain at "
                                + "least one modifier — ignored",
                            source: span, bindingName: key))
                    continue
                }
                inputAliasesRaw[key] = s
                inputAliasesParsed[keyLower] = mask
            }
        }

        // [v-key-aliases] — `name = <id>` lookup for vendor-HID "original
        // keys". A binding selects one via a BARE `input = "<name>"` (no
        // `$` sigil — a v-key is a complete trigger, like a custom key
        // name, parallel to `f13`). The value is the 1–255 id the
        // firmware's `&vkey <id>` sends (canon Report ID 0x20). The
        // resolved map is threaded into `InputParser.parse`, where a hit
        // becomes a `.vkey(id)` trigger; from there a vkey binding flows
        // through the ordinary Matcher (apps / when-var / on-up all work).
        // Names that would shadow a real key / modifier / the `v-key`
        // wildcard are rejected — the bare-name resolution would otherwise
        // be ambiguous.
        var vkeyAliasesParsed: [String: UInt8] = [:]
        if case .table(let raw)? = root["v-key-aliases"] {
            let aliasSpans = tableSpans(
                keys: raw.keys, at: [.key("v-key-aliases")], in: spanned)
            for (key, value) in raw {
                let keyLower = key.lowercased()
                if InputParser.vkeyWildcardNames.contains(keyLower)
                    || InputParser.reservedModifierTokens.contains(keyLower)
                    || KeyCodes.code(forName: keyLower) != nil
                {
                    let span = aliasSpans.key(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .vkeyAliasInvalid,
                            message:
                                "[v-key-aliases] '\(key)'\(sourceTag(span)): "
                                + "name shadows a built-in "
                                + "key / modifier / the v-key wildcard — ignored "
                                + "(rename so `input = \"\(key)\"` stays unambiguous)",
                            source: span, bindingName: key))
                    continue
                }
                guard let idRaw = value.asInt.map({ Int($0) }) else {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .vkeyAliasInvalid,
                            message:
                                "[v-key-aliases] '\(key)'\(sourceTag(span)): value must be an "
                                + "integer 1–255 (the id `&vkey <id>` sends) — ignored",
                            source: span, bindingName: key))
                    continue
                }
                guard (1...255).contains(idRaw) else {
                    let span = aliasSpans.value(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .vkeyAliasInvalid,
                            message:
                                "[v-key-aliases] '\(key)'\(sourceTag(span)): id \(idRaw) out of "
                                + "range 1–255 — ignored",
                            source: span, bindingName: key))
                    continue
                }
                if let existing = vkeyAliasesParsed[keyLower] {
                    let span = aliasSpans.key(key)
                    warnings.append(
                        ConfigWarning(
                            kind: .vkeyAliasInvalid,
                            message:
                                "[v-key-aliases] '\(key)'\(sourceTag(span)): duplicate name "
                                + "(already = \(existing)) — first wins, ignored",
                            source: span, bindingName: key))
                    continue
                }
                vkeyAliasesParsed[keyLower] = UInt8(idRaw)
            }
        }

        // v0.7.0 sequence sugar: parse `[[sequence]]` rows first and
        // expand them into prefix + child bindings. The expansion
        // produces ordinary Binding values (no new runtime concepts),
        // and the expanded set is prepended to `[[bindings]]` so the
        // prefix wins over a regular binding with the same trigger
        // (= first-match-wins yields the documented "sequence wins"
        // semantics without needing an extra precedence dimension).
        let seq = parseSequences(
            spanned: spanned,
            actionAliases: actionAliases,
            inputAliases: inputAliasesParsed,
            vkeyAliases: vkeyAliasesParsed,
            warnings: &warnings)

        var bindings: [Binding] = seq.expanded
        var dropped = seq.dropped
        let rows = root["bindings"]?.asArrayOfTables ?? []
        var bindingIndex = 0
        for (ri, row) in rows.enumerated() {
            // v0.8.0 per-app sugar: a `[[bindings]]` row with a
            // `[[bindings.per-app]]` AoT child expands to N siblings,
            // one per per-app entry, with `apps = [bundle-id]` and
            // the entry's action-* fields layered onto the base row.
            // Each synthesized row carries its resolved spans alongside
            // its fields (the per-app entry's field spans win).
            let prefix: [TOML.PathSegment] = [.key("bindings"), .index(ri)]
            let synthRows: [(row: [String: TOML.Value], spans: RowSpans)]
            switch expandBindingPerApp(row, at: prefix, in: spanned, warnings: &warnings) {
            case .single(let r, let s): synthRows = [(r, s)]
            case .many(let rs): synthRows = rs
            case .invalid: dropped += 1; continue
            }

            for synth in synthRows {
                guard
                    let b = makeBinding(
                        from: synth.row,
                        spans: synth.spans,
                        index: bindingIndex,
                        isFallback: false,
                        actionAliases: actionAliases,
                        inputAliases: inputAliasesParsed,
                        vkeyAliases: vkeyAliasesParsed,
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
                    let span = synth.spans.value("input")
                    warnings.append(
                        ConfigWarning(
                            kind: .sequenceParseError,
                            message:
                                "[[bindings]] '\(b.name)'" + sourceTag(span)
                                + ": input '\(b.inputRaw)' collides with "
                                + "[[sequence]] prefix '\(collision.name)' — "
                                + "regular binding dropped (sequence wins)",
                            source: span, bindingName: b.name))
                    dropped += 1
                    continue
                }
                bindings.append(b)
            }
        }

        // Duplicate `name` detection. Two user-named bindings sharing
        // a name still both load (chord doesn't enforce uniqueness),
        // but `config --show --json` consumers and the `daemon --reload --dry-run`
        // name-keyed diff can't distinguish them. Synthetic
        // `binding-N` names from makeBinding's index fallback are
        // exempt — they're unique by construction.
        let synthBindingName = #/^binding-\d+$/#
        var seenUserNames: [String: Int] = [:]
        for b in bindings {
            if b.name.contains(synthBindingName) { continue }
            seenUserNames[b.name, default: 0] += 1
        }
        for (name, count) in seenUserNames where count > 1 {
            warnings.append(
                ConfigWarning(
                    kind: .duplicateBindingName,
                    message:
                        "duplicate binding name '\(name)' appears \(count) times — "
                        + "name-keyed tooling (config --show / daemon --reload --dry-run diff) "
                        + "cannot distinguish them",
                    bindingName: name))
        }

        // v0.8.0 [[remap]] sugar: expand each row into N action-keys
        // bindings (one per `map` entry). Appended AFTER regular
        // bindings so a specific `[[bindings]]` row can override a
        // bulk remap entry via first-match-wins.
        let remap = parseRemaps(
            spanned: spanned,
            actionAliases: actionAliases,
            inputAliases: inputAliasesParsed,
            vkeyAliases: vkeyAliasesParsed,
            warnings: &warnings)
        bindings.append(contentsOf: remap.expanded)
        dropped += remap.dropped

        var fallbacks: [Binding] = []
        let fbRows = root["fallbacks"]?.asArrayOfTables ?? []
        var fbExpansionIndex = 0
        for (ri, row) in fbRows.enumerated() {
            let expanded = expandFallbackRow(
                row,
                at: [.key("fallbacks"), .index(ri)], in: spanned,
                warnings: &warnings)
            switch expanded {
            case .single(let r, let s):
                if let b = makeBinding(
                    from: r, spans: s,
                    index: fbExpansionIndex,
                    isFallback: true,
                    actionAliases: actionAliases,
                    inputAliases: inputAliasesParsed,
                    vkeyAliases: vkeyAliasesParsed,
                    warnings: &warnings)
                {
                    fallbacks.append(b)
                    fbExpansionIndex += 1
                } else {
                    dropped += 1
                }
            case .many(let rows):
                for (r, s) in rows {
                    if let b = makeBinding(
                        from: r, spans: s,
                        index: fbExpansionIndex,
                        isFallback: true,
                        actionAliases: actionAliases,
                        inputAliases: inputAliasesParsed,
                        vkeyAliases: vkeyAliasesParsed,
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

        let cfg = ChordConfig(
            options: options, bindings: bindings,
            fallbacks: fallbacks, actionAliases: actionAliases,
            inputAliases: inputAliasesRaw)
        return ParseResult(
            config: cfg, warnings: warnings,
            droppedBindings: dropped, sourcePath: nil)
    }

    // MARK: - Parsers extracted to extension files (#51)
    //
    // This file keeps the public entry (`load` / `parse`) + the `parse`
    // orchestrator + `sourceTag`. Everything else is a member of
    // `enum Config` carried in an `extension Config { … }` next door —
    // call sites here are unchanged.
    //
    //   Config+Binding.swift   — makeBinding (per-row Binding synthesis)
    //                            + hasOnUpAction.
    //   Config+Action.swift    — parseAction (the action-* union) +
    //                            native-action desugar + ParsedAction.
    //   Config+Condition.swift — when-var / when-vars + hold-while
    //                            (timeout) parsing + OptionalParse.
    //   Config+Alias.swift     — @name / @name(args) resolution.
    //   Config+Sequence.swift  — parseSequences + SequenceParse
    //                            (`[[sequence]]` leader-key sugar).
    //   Config+Remap.swift     — parseRemaps (`[[remap]]` table sugar).
    //   Config+Expansion.swift — expandBindingPerApp / expandFallbackRow
    //                            + RowExpansion / FallbackExpansion.

    /// Render the `(config.toml:N:C)` suffix attached to warnings —
    /// `(config.toml:N)` when the span carries no column, the empty
    /// string when there is no span at all (better to drop the suffix
    /// than print "config.toml:?"). Internal so extension parsers
    /// format the suffix consistently with the in-file emitters.
    static func sourceTag(_ span: TOML.SourceSpan?) -> String {
        guard let span else { return "" }
        guard let column = span.column else {
            return " (config.toml:\(span.line))"
        }
        return " (config.toml:\(span.line):\(column))"
    }

    /// Human-readable TOML type name for `field-type-mismatch` warnings.
    static func tomlTypeName(_ v: TOML.Value) -> String {
        switch v {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "float"
        case .bool: return "boolean"
        case .array: return "array"
        case .table: return "table"
        case .arrayOfTables: return "array-of-tables"
        }
    }

    /// present-but-wrong-type guard (t-0055). When `key` exists in
    /// `table` but its value's TOML type isn't one of `accept`, append a
    /// `field-type-mismatch` warning pointing at the field's VALUE
    /// (`spans.value(key)`). The read sites keep their `?.asBool` /
    /// `?.asArray` guards (which already fall through to the default on
    /// a type miss) — this only makes the otherwise-silent skip visible.
    /// A missing or correctly-typed field emits nothing, so valid
    /// configs are byte-for-byte unchanged (no regression).
    /// `accept` strings must match `tomlTypeName`'s vocabulary.
    static func warnFieldType(
        _ table: [String: TOML.Value],
        key: String,
        accept: Set<String>,
        label: String,
        spans: RowSpans = .none,
        bindingName: String? = nil,
        warnings: inout [ConfigWarning]
    ) {
        guard let value = table[key] else { return }
        let actual = tomlTypeName(value)
        guard !accept.contains(actual) else { return }
        let expected = accept.sorted().joined(separator: " or ")
        let span = spans.value(key)
        warnings.append(
            ConfigWarning(
                kind: .fieldTypeMismatch,
                message:
                    "\(label)\(sourceTag(span)): expected \(expected), got \(actual) — "
                    + "ignored (value has no effect)",
                source: span, bindingName: bindingName))
    }

    /// Element-level companion to `warnFieldType` for the string-array
    /// fields (`exclude-apps`, `input-source`). When `key` *is* an array
    /// but some elements are non-string — silently dropped by the read
    /// site's `compactMap(\.asString)` — warn once, naming the offending
    /// types. A field that isn't an array (caught by `warnFieldType`) or
    /// whose elements are all strings emits nothing.
    static func warnArrayElementTypes(
        _ table: [String: TOML.Value],
        key: String,
        label: String,
        spans: RowSpans = .none,
        bindingName: String? = nil,
        warnings: inout [ConfigWarning]
    ) {
        guard let arr = table[key]?.asArray else { return }
        let bad = arr.filter { $0.asString == nil }.map(tomlTypeName)
        guard !bad.isEmpty else { return }
        let span = spans.value(key)
        warnings.append(
            ConfigWarning(
                kind: .fieldTypeMismatch,
                message:
                    "\(label)\(sourceTag(span)): expected an array of strings, got non-string "
                    + "element(s) [\(bad.joined(separator: ", "))] — " + "dropped (no effect)",
                source: span, bindingName: bindingName))
    }

}
