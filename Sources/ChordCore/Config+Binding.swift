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
        from row: [String: TOML.Value], spans: RowSpans, index: Int,
        isFallback: Bool,
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        vkeyAliases: [String: UInt8] = [:],
        allowReservedVarNames: Bool = false,
        warnings: inout [ConfigWarning]
    ) -> Binding? {
        let section = isFallback ? "[[fallbacks]]" : "[[bindings]]"
        let name = row["name"]?.asString ?? "binding-\(index + 1)"
        // Locations are resolved by the caller from parseWithSpans' entry
        // index and passed in as a per-field view — synthesized desugar rows
        // carry no source bytes, so the spans travel alongside the fields,
        // not inside them (no synthetic dict key). Each warning below picks
        // the field it is actually about; a field with no source falls back
        // to the row header.
        guard let inputRaw = row["input"]?.asString else {
            let span = spans.header
            warnings.append(
                ConfigWarning(
                    kind: .missingInput,
                    message: "\(section) '\(name)'\(sourceTag(span)): missing 'input'",
                    source: span, bindingName: name))
            return nil
        }
        let parsed: InputParser.Parsed
        do {
            parsed = try InputParser.parse(
                inputRaw,
                allowWildcard: isFallback,
                allowModifiersOnly: !isFallback,
                inputAliases: inputAliases,
                vkeyAliases: vkeyAliases)
        } catch let e as InputParser.InputParseError {
            // Differentiate `$name` typos (undefinedInputAlias) from
            // plain modifier typos (unknownToken) so CI / schema
            // consumers can branch on the structured kind.
            let kind: ConfigWarning.Kind
            if case .undefinedInputAlias = e {
                kind = .undefinedInputAlias
            } else {
                kind = .unknownInputToken
            }
            let span = spans.value("input")
            warnings.append(
                ConfigWarning(
                    kind: kind,
                    message: "\(section) '\(name)'\(sourceTag(span)): \(e)",
                    source: span, bindingName: name))
            return nil
        } catch {
            let span = spans.value("input")
            warnings.append(
                ConfigWarning(
                    kind: .unknownInputToken,
                    message: "\(section) '\(name)'\(sourceTag(span)): \(error)",
                    source: span, bindingName: name))
            return nil
        }
        let actionResult = parseAction(
            row: row,
            section: section,
            name: name,
            spans: spans,
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
            let keysVal = row["action-keys"]
        {
            do {
                let parsed = try parseKeysListValue(keysVal)
                extraDownActions = parsed.map { .keys($0.0, $0.1) }
            } catch {
                let span = spans.value("action-keys")
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): " + "action-keys: \(error)",
                        source: span, bindingName: name))
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
        let explicitOnUpKey = firstOnUpActionKey(row: row)
        if let explicitOnUpKey {
            if parsedAction.autoOnUpAction != nil {
                let span = spans.key(explicitOnUpKey)
                warnings.append(
                    ConfigWarning(
                        kind: .missingAction,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "action-hold-var owns the on-up half — remove "
                            + "the explicit action-*-on-up entry",
                        source: span, bindingName: name))
                return nil
            }
            onUpResult = parseAction(
                row: row,
                section: section,
                name: name,
                spans: spans,
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
        guard
            let condition = parseCondition(
                row: row, section: section,
                name: name, spans: spans,
                warnings: &warnings)
        else { return nil }
        guard
            let holdWhile = parseHoldWhile(
                row: row, section: section,
                name: name, spans: spans,
                warnings: &warnings)
        else { return nil }
        guard
            let holdWhileTimeout = parseHoldWhileTimeout(
                row: row, section: section,
                name: name, spans: spans,
                warnings: &warnings)
        else { return nil }
        guard
            let actionKeysDelay = parseActionKeysDelay(
                row: row, section: section,
                name: name, spans: spans,
                warnings: &warnings)
        else { return nil }
        // hold-while and hold-while-timeout are mutually exclusive —
        // they pick different lifecycles for the same variable. The
        // user almost certainly meant one or the other; offer a clear
        // error rather than silently picking.
        if holdWhile.value != nil && holdWhileTimeout.value != nil {
            let span = spans.key("hold-while-timeout")
            warnings.append(
                ConfigWarning(
                    kind: .holdWhileParseError,
                    message:
                        "\(section) '\(name)'\(sourceTag(span)): "
                        + "hold-while and hold-while-timeout are mutually "
                        + "exclusive — pick one",
                    source: span, bindingName: name))
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
        // t-0055: present-but-wrong-type. Accepts an array or a bare
        // string (sugar for a one-element list); anything else was
        // silently skipped. The read below is unchanged.
        warnFieldType(
            row, key: "input-source", accept: ["array", "string"],
            label: "\(section) '\(name)': input-source",
            spans: spans, bindingName: name,
            warnings: &warnings)
        warnArrayElementTypes(
            row, key: "input-source",
            label: "\(section) '\(name)': input-source",
            spans: spans, bindingName: name,
            warnings: &warnings)
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
                let span = spans.value("repeat")
                warnings.append(
                    ConfigWarning(
                        kind: .other,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "repeat: unknown value '\(raw)' — "
                            + "expected fire-each / ignore / passthrough",
                        source: span, bindingName: name))
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
        warnFieldType(
            row, key: "passthrough", accept: ["boolean"],
            label: "\(section) '\(name)': passthrough",
            spans: spans, bindingName: name,
            warnings: &warnings)
        if let raw = row["passthrough"]?.asBool {
            passthrough = raw
        }
        if passthrough {
            let span = spans.key("passthrough")
            if !extraDownActions.isEmpty {
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "passthrough is incompatible with action-keys "
                            + "(the original event already reaches the OS)",
                        source: span, bindingName: name))
                return nil
            }
            switch parsedAction.action {
            case .keys:
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "passthrough requires action-shell (or no action) — "
                            + "action-keys would duplicate the keystroke",
                        source: span, bindingName: name))
                return nil
            case .noop:
                warnings.append(
                    ConfigWarning(
                        kind: .missingAction,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "passthrough is incompatible with action-noop "
                            + "(noop = absorb; passthrough = relay)",
                        source: span, bindingName: name))
                return nil
            case .shell, .setVariable, .toggleVariable:
                break
            }
            if onUpResult != nil {
                warnings.append(
                    ConfigWarning(
                        kind: .missingAction,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "passthrough cannot carry an action-*-on-up — "
                            + "no paired-up is captured when the event flows through",
                        source: span, bindingName: name))
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
            actionKeysDelayMs: actionKeysDelay.value,
            inputSource: inputSource,
            inputRaw: inputRaw,
            actionRaw: parsedAction.raw,
            aliasName: parsedAction.aliasName,
            sourceSpan: spans.header)
    }

    /// The first `action-*-on-up` key present in `row`, or `nil` when
    /// none is. Lets `makeBinding` decide whether to even invoke the
    /// parser (keeps the absent-on-up case zero-cost) AND attribute
    /// the hold-var conflict warning to the offending key.
    private static func firstOnUpActionKey(row: [String: TOML.Value]) -> String? {
        // chord 0.9.0+: the to-on-up forms are listed so parseAction can
        // emit the "not allowed on -on-up paths" rejection instead of
        // silently dropping the field on the floor.
        let onUpKeys = [
            "action-shell-on-up",
            "action-keys-on-up",
            "action-noop-on-up",
            "action-set-var-on-up",
            "action-toggle-var-on-up",
            "action-hold-var-on-up"
        ]
        return onUpKeys.first { row[$0] != nil }
    }
}
