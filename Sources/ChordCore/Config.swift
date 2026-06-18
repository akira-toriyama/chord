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

        // #52-bounded: descriptor-driven structural validation — warn on
        // unknown keys in the array-of-tables sections ([[bindings]] /
        // [[fallbacks]] / [[sequence]] / [[remap]]) and their nested rows.
        // [options] is checked inline below; open string maps ([action-
        // aliases] / [input-aliases]) accept any key by design.
        warnings.append(contentsOf:
            ChordConfigSchema.unknownKeyWarnings(root: root))

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
            // Surface typos: `passthroughUnmatched` (camelCase),
            // `exclude_apps` (underscore), etc. would otherwise look
            // exactly like the binding worked but had no effect.
            // TOML.lineKey is the synthetic line-number key the
            // parser injects on the table header. #52-bounded: the
            // known-key set is sourced from the descriptor (the same
            // single source as `--emit-schema`), so it can't drift.
            let known = ChordConfigSchema.optionsShape().keySet
            for key in opts.keys where key != TOML.lineKey && !known.contains(key) {
                warnings.append(ConfigWarning(
                    kind: .unknownOptionKey,
                    message:
                        "[options] '\(key)': unknown option key — " +
                        "ignored (known: \(known.sorted().joined(separator: ", ")))"))
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
            for (key, value) in raw {
                if key == TOML.lineKey { continue }
                let keyLower = key.lowercased()
                if InputParser.vkeyWildcardNames.contains(keyLower)
                    || InputParser.reservedModifierTokens.contains(keyLower)
                    || KeyCodes.code(forName: keyLower) != nil
                {
                    warnings.append(ConfigWarning(
                        kind: .vkeyAliasInvalid,
                        message:
                            "[v-key-aliases] '\(key)': name shadows a built-in " +
                            "key / modifier / the v-key wildcard — ignored " +
                            "(rename so `input = \"\(key)\"` stays unambiguous)",
                        bindingName: key))
                    continue
                }
                guard let idRaw = value.asInt.map({ Int($0) }) else {
                    warnings.append(ConfigWarning(
                        kind: .vkeyAliasInvalid,
                        message:
                            "[v-key-aliases] '\(key)': value must be an " +
                            "integer 1–255 (the id `&vkey <id>` sends) — ignored",
                        bindingName: key))
                    continue
                }
                guard (1...255).contains(idRaw) else {
                    warnings.append(ConfigWarning(
                        kind: .vkeyAliasInvalid,
                        message:
                            "[v-key-aliases] '\(key)': id \(idRaw) out of " +
                            "range 1–255 — ignored",
                        bindingName: key))
                    continue
                }
                if let existing = vkeyAliasesParsed[keyLower] {
                    warnings.append(ConfigWarning(
                        kind: .vkeyAliasInvalid,
                        message:
                            "[v-key-aliases] '\(key)': duplicate name " +
                            "(already = \(existing)) — first wins, ignored",
                        bindingName: key))
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
        let seq = parseSequences(root: root,
                                 actionAliases: actionAliases,
                                 inputAliases: inputAliasesParsed,
                                 vkeyAliases: vkeyAliasesParsed,
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
            warnings.append(ConfigWarning(
                kind: .duplicateBindingName,
                message:
                    "duplicate binding name '\(name)' appears \(count) times — " +
                    "name-keyed tooling (config --show / daemon --reload --dry-run diff) " +
                    "cannot distinguish them",
                bindingName: name))
        }

        // v0.8.0 [[remap]] sugar: expand each row into N action-keys
        // bindings (one per `map` entry). Appended AFTER regular
        // bindings so a specific `[[bindings]]` row can override a
        // bulk remap entry via first-match-wins.
        let remap = parseRemaps(root: root,
                                actionAliases: actionAliases,
                                inputAliases: inputAliasesParsed,
                                vkeyAliases: vkeyAliasesParsed,
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
                                       vkeyAliases: vkeyAliasesParsed,
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

        let cfg = ChordConfig(options: options, bindings: bindings,
                              fallbacks: fallbacks, actionAliases: actionAliases,
                              inputAliases: inputAliasesRaw)
        return ParseResult(config: cfg, warnings: warnings,
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

    /// Render the `(config.toml:42)` suffix attached to per-binding
    /// warnings. Returns the empty string when the parser couldn't
    /// resolve a line — better to drop the suffix than print
    /// "config.toml:?".
    /// Internal so extension parsers can format `(config.toml:N)`
    /// suffixes consistently with the in-file warning emitters.
    static func sourceTag(line: Int?) -> String {
        guard let line else { return "" }
        return " (config.toml:\(line))"
    }

}
