// Config+Action.swift — #51 split of Config.swift.
// The `action-*` parsing: `parseAction` (the 5-way action union),
// native-action desugar, and the `ParsedAction` carrier. Members of
// `enum Config`; `internal` where `makeBinding` calls across files.

import Foundation

extension Config {
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
    static func parseAction(
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
        let toggleKey = "action-toggle-var\(suffix)"
        let holdVarKey = "action-hold-var\(suffix)"
        let fieldLabel = suffix.isEmpty ? "" : " (on-up)"

        // chord 0.9.0+ native action sugar: each `action-<native>` is
        // desugared to a fixed `.keys` primary action targeting the
        // macOS default shortcut. No shell-out, no new Action case;
        // the rest of the pipeline (Controller / Dispatcher / Schema /
        // `config --show --json`) sees a plain keys binding. Caveat: if the
        // user has remapped the shortcut in System Settings → Keyboard,
        // the action effectively re-binds to whatever they assigned.
        // on-up variants are not supported (suffix must be empty).
        if suffix.isEmpty {
            switch parseNativeAction(row: row, section: section,
                                     name: name, source: source,
                                     sourceLine: sourceLine,
                                     warnings: &warnings) {
            case .absent: break          // fall through to other action-*
            case .ok(let pa): return pa
            case .invalid:    return nil // warning already emitted
            }
        }

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
        // chord 0.9.0+ `action-toggle-var` — flip 0↔1 on each press.
        // Standalone: action-set-value / hold-while / hold-while-timeout
        // are rejected (toggle's lifecycle is "until next toggle"; the
        // value is implicit). on-up variant is also rejected — toggle
        // semantics belong on the primary action only.
        if let varName = row[toggleKey]?.asString {
            if !suffix.isEmpty {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(toggleKey) is not allowed on -on-up paths",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if !allowReservedVarNames && varName.hasPrefix("_seq_") {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "\(toggleKey) name '_seq_*' is reserved for " +
                        "[[sequence]] expansion",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if row[setKey] != nil || row[setValKey] != nil
                || row[holdVarKey] != nil
            {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "\(toggleKey) is mutually exclusive with " +
                        "action-set-var / action-set-value / action-hold-var",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            return ParsedAction(action: .toggleVariable(name: varName),
                                raw: varName,
                                aliasName: nil)
        }

        // chord 0.9.0+ `action-hold-var` — sugar for setVariable(name, 1)
        // on down + setVariable(name, 0) on paired up. Standalone:
        // action-set-var / set-value / hold-while* / explicit on-up
        // are all rejected (the lifecycle is defined by the paired-up
        // contract that this sugar owns).
        if let varName = row[holdVarKey]?.asString {
            if !suffix.isEmpty {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source)\(fieldLabel): " +
                        "\(holdVarKey) is not allowed on -on-up paths",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if !allowReservedVarNames && varName.hasPrefix("_seq_") {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "\(holdVarKey) name '_seq_*' is reserved for " +
                        "[[sequence]] expansion",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            if row[setKey] != nil || row[setValKey] != nil {
                warnings.append(ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(source): " +
                        "\(holdVarKey) is mutually exclusive with " +
                        "action-set-var / action-set-value",
                    sourceLine: sourceLine, bindingName: name))
                return nil
            }
            return ParsedAction(
                action: .setVariable(name: varName, value: 1),
                autoOnUpAction: .setVariable(name: varName, value: 0),
                raw: varName,
                aliasName: nil)
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

    /// What `parseAction` hands back: the runtime `Action`, plus the
    /// raw user string (`action-shell` body or `action-keys` body)
    /// and the alias name when `@name` resolved successfully.
    struct ParsedAction {
        let action: Action
        /// chord 0.9.0+: when `action-keys = [a, b, …]` (array form),
        /// the first element becomes `action`, the rest are surfaced
        /// here so makeBinding can drop them onto `extraDownActions`.
        /// Empty for the common single-string action-keys path and
        /// for shell / noop / setVariable.
        let extraKeys: [Action]
        /// chord 0.9.0+: `action-hold-var = "name"` synthesises
        /// `setVariable(name, 1)` as the primary action AND a paired
        /// `setVariable(name, 0)` on key-up. The caller (makeBinding)
        /// plumbs this into `onUpAction` when the user didn't write
        /// their own `action-*-on-up`.
        let autoOnUpAction: Action?
        let raw: String?
        let aliasName: String?

        init(action: Action,
             extraKeys: [Action] = [],
             autoOnUpAction: Action? = nil,
             raw: String? = nil,
             aliasName: String? = nil) {
            self.action = action
            self.extraKeys = extraKeys
            self.autoOnUpAction = autoOnUpAction
            self.raw = raw
            self.aliasName = aliasName
        }
    }

    /// chord 0.9.0+ native action desugar. Each `action-<native>`
    /// maps to the macOS-default keyboard shortcut for that system
    /// action; the rest of the pipeline sees a plain `.keys` action.
    private enum NativeActionOutcome {
        case absent
        case ok(ParsedAction)
        case invalid     // warning already appended
    }
    private static func parseNativeAction(
        row: [String: TOML.Value],
        section: String, name: String, source: String,
        sourceLine: Int?,
        warnings: inout [ConfigWarning]
    ) -> NativeActionOutcome {
        func warn(_ msg: String) {
            warnings.append(ConfigWarning(
                kind: .actionKeysParseError,
                message: "\(section) '\(name)'\(source): \(msg)",
                sourceLine: sourceLine, bindingName: name))
        }

        if let target = row["action-mission-control"]?.asString {
            switch target {
            case "show-all-windows":
                // ctrl + ↑ — macOS Mission Control default.
                return .ok(ParsedAction(
                    action: .keys([.ctrl], 0x7E),
                    raw: "action-mission-control:show-all-windows"))
            case "show-app-windows":
                // ctrl + ↓ — App Exposé default.
                return .ok(ParsedAction(
                    action: .keys([.ctrl], 0x7D),
                    raw: "action-mission-control:show-app-windows"))
            default:
                warn("action-mission-control: unknown value '\(target)' " +
                     "(expected show-all-windows / show-app-windows)")
                return .invalid
            }
        }
        if let target = row["action-screenshot"]?.asString {
            switch target {
            case "selection":
                // cmd + shift + 4 (selection-to-file).
                return .ok(ParsedAction(
                    action: .keys([.cmd, .shift], 0x15),
                    raw: "action-screenshot:selection"))
            case "screen":
                // cmd + shift + 3 (full screen-to-file).
                return .ok(ParsedAction(
                    action: .keys([.cmd, .shift], 0x14),
                    raw: "action-screenshot:screen"))
            default:
                warn("action-screenshot: unknown value '\(target)' " +
                     "(expected selection / screen)")
                return .invalid
            }
        }
        if row["action-spotlight"]?.asBool == true {
            // cmd + space — Spotlight default.
            return .ok(ParsedAction(
                action: .keys([.cmd], 0x31),
                raw: "action-spotlight:true"))
        }
        return .absent
    }

    /// Parse `action-keys` value (string or array) into one or more
    /// (Modifiers, keycode) pairs. Used by both primary and on-up
    /// action-keys paths.
    static func parseKeysListValue(
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
}
