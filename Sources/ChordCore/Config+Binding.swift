// Config+Binding.swift — #51 split of Config.swift.
// `makeBinding` (the per-row Binding synthesiser, internal so the
// sugar-expansion extensions can route synthetic rows through it)
// + its `hasOnUpAction` helper. Members of `enum Config`.

import Foundation

extension Config {
    /// Internal so the extension files (Config+Sequence.swift,
    /// Config+Remap.swift, Config+Expansion.swift) can synthesize TOML
    /// rows and route them through the same validation as user-authored
    /// rows.
    static func makeBinding(
        from row: [String: TOML.Value], index: Int,
        isFallback: Bool,
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        vkeyAliases: [String: UInt8] = [:],
        allowReservedVarNames: Bool = false,
        warnings: inout [ConfigWarning]
    ) -> Binding? {
        let section = isFallback ? "[[fallbacks]]" : "[[bindings]]"
        let name = row["name"]?.asString ?? "binding-\(index + 1)"
        let line = row.sourceLine
        let source = sourceTag(line: line)
        guard let inputRaw = row["input"]?.asString else {
            warnings.append(ConfigWarning(
                kind: .missingInput,
                message: "\(section) '\(name)'\(source): missing 'input'",
                sourceLine: line, bindingName: name))
            return nil
        }
        let parsed: InputParser.Parsed
        do { parsed = try InputParser.parse(
                inputRaw,
                allowWildcard: isFallback,
                allowModifiersOnly: !isFallback,
                inputAliases: inputAliases,
                vkeyAliases: vkeyAliases) }
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
        // chord 0.9.0+: action-hold-var auto-synthesises an on-up
        // (setVariable(name, 0)). If the user ALSO wrote an explicit
        // action-*-on-up, that's a conflict — they're contradicting
        // hold-var's contract.
        let onUpResult: ParsedAction?
        let userWroteOnUp = hasOnUpAction(row: row)
        if userWroteOnUp {
            if parsedAction.autoOnUpAction != nil {
                warnings.append(ConfigWarning(
                    kind: .missingAction,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "action-hold-var owns the on-up half — remove " +
                        "the explicit action-*-on-up entry",
                    sourceLine: line, bindingName: name))
                return nil
            }
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
        } else if let auto = parsedAction.autoOnUpAction {
            // hold-var synthetic on-up.
            onUpResult = ParsedAction(action: auto)
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

        // chord 0.9.0+ input-source filter — same glob semantics as
        // `apps` (allow / `!`-prefix deny / `["*"]` → nil). String
        // form is sugar for a one-element list.
        var inputSource: [String]?
        if let arr = row["input-source"]?.asArray {
            let strs = arr.compactMap(\.asString)
            inputSource = strs.isEmpty || strs == ["*"] ? nil : strs
        } else if let s = row["input-source"]?.asString {
            inputSource = [s]
        }

        // chord 0.9.0+ repeat strategy: how the binding reacts to
        // macOS autorepeat events. Default `.fireEach` preserves
        // pre-0.9.0 behaviour (every repeat invokes the action).
        var repeatStrategy: RepeatStrategy = .fireEach
        if let raw = row["repeat"]?.asString {
            if let parsed = RepeatStrategy(rawValue: raw) {
                repeatStrategy = parsed
            } else {
                warnings.append(ConfigWarning(
                    kind: .other,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "repeat: unknown value '\(raw)' — " +
                        "expected fire-each / ignore / passthrough",
                    sourceLine: line, bindingName: name))
                return nil
            }
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
            case .shell, .setVariable, .toggleVariable:
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
            repeatStrategy: repeatStrategy,
            inputSource: inputSource,
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
            // chord 0.9.0+: detect to-on-up forms so parseAction can
            // emit the "not allowed on -on-up paths" rejection
            // instead of silently dropping the field on the floor.
            || row["action-toggle-var-on-up"] != nil
            || row["action-hold-var-on-up"] != nil
    }
}
