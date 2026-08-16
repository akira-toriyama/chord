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
        spans: RowSpans,
        actionAliases: [String: String],
        suffix: String = "",
        required: Bool = true,
        allowReservedVarNames: Bool = false,
        warnings: inout [ConfigWarning]
    ) -> ParsedAction? {
        let shellKey = "action-shell\(suffix)"
        let keysKey = "action-keys\(suffix)"
        let noopKey = "action-noop\(suffix)"
        let setKey = "action-set-var\(suffix)"
        let setValKey = "action-set-value\(suffix)"
        let toggleKey = "action-toggle-var\(suffix)"
        let holdVarKey = "action-hold-var\(suffix)"
        let fieldLabel = suffix.isEmpty ? "" : " (on-up)"

        // chord 3.0.0+ `action-drag-scroll` — the held-pointer mode.
        // Checked before every other action-* — the native sugar below
        // included — because it is the only one that claims the WHOLE press
        // (down opens the mode, the paired up closes it); combining it with
        // a second action would mean two owners for one span. Its
        // mutual-exclusion sweep is what reports that, so it only gets to
        // report it by running first: a branch that returns ahead of it
        // discards the row's `action-drag-scroll` silently.
        switch parseDragScrollAction(
            row: row, section: section, name: name, spans: spans,
            suffix: suffix, fieldLabel: fieldLabel, warnings: &warnings)
        {
        case .absent: break  // fall through to other action-*
        case .ok(let pa): return pa
        case .invalid: return nil  // warning already emitted
        }

        // chord 0.9.0+ native action sugar: each `action-<native>` is
        // desugared to a fixed `.keys` primary action targeting the
        // macOS default shortcut. No shell-out, no new Action case;
        // the rest of the pipeline (Controller / Dispatcher / Schema /
        // `config --show --json`) sees a plain keys binding. Caveat: if the
        // user has remapped the shortcut in System Settings → Keyboard,
        // the action effectively re-binds to whatever they assigned.
        // on-up variants are not supported (suffix must be empty).
        if suffix.isEmpty {
            switch parseNativeAction(
                row: row, section: section,
                name: name, spans: spans,
                warnings: &warnings)
            {
            case .absent: break  // fall through to other action-*
            case .ok(let pa): return pa
            case .invalid: return nil  // warning already emitted
            }
        }

        if let shell = row[shellKey]?.asString {
            switch resolveAlias(shell, actionAliases: actionAliases) {
            case .body(let body, let aliasName):
                return ParsedAction(
                    action: .shell(body),
                    raw: shell,
                    aliasName: aliasName)
            case .undefined(let aliasName):
                // canon-specified warning format — kept
                // separately from the `[[bindings]] '…' (line): …`
                // format on purpose. The structured `.undefinedActionAlias`
                // kind lets machine consumers disambiguate.
                let span = spans.value(shellKey)
                warnings.append(
                    ConfigWarning(
                        kind: .undefinedActionAlias,
                        message:
                            "binding '\(name)'\(sourceTag(span))\(fieldLabel) "
                            + "references undefined alias '@\(aliasName)'; " + "binding dropped",
                        source: span, bindingName: name))
                return nil
            case .callError(let aliasName, let msg):
                let span = spans.value(shellKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionAliasCallError,
                        message:
                            "binding '\(name)'\(sourceTag(span))\(fieldLabel) "
                            + "@\(aliasName) call error: \(msg); binding dropped",
                        source: span, bindingName: name))
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
            let span = spans.value(keysKey)
            let parsed: [(Modifiers, UInt16)]
            do {
                parsed = try parseKeysListValue(keysVal)
            } catch {
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(keysKey): \(error)",
                        source: span, bindingName: name))
                return nil
            }
            if parsed.isEmpty {
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(keysKey): must contain at least one keystroke",
                        source: span, bindingName: name))
                return nil
            }
            if !suffix.isEmpty && parsed.count > 1 {
                warnings.append(
                    ConfigWarning(
                        kind: .actionKeysParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(keysKey): array form is not supported for on-up "
                            + "(use a single string)",
                        source: span, bindingName: name))
                return nil
            }
            let (mods, code) = parsed[0]
            let extras = parsed.dropFirst().map { Action.keys($0.0, $0.1) }
            let rawString = keysVal.asString
            return ParsedAction(
                action: .keys(mods, code),
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
                let span = spans.key(toggleKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(toggleKey) is not allowed on -on-up paths",
                        source: span, bindingName: name))
                return nil
            }
            if !allowReservedVarNames && varName.hasPrefix("_seq_") {
                let span = spans.value(toggleKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "\(toggleKey) name '_seq_*' is reserved for "
                            + "[[sequence]] expansion",
                        source: span, bindingName: name))
                return nil
            }
            if row[setKey] != nil || row[setValKey] != nil
                || row[holdVarKey] != nil
            {
                let span = spans.key(toggleKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "\(toggleKey) is mutually exclusive with "
                            + "action-set-var / action-set-value / action-hold-var",
                        source: span, bindingName: name))
                return nil
            }
            return ParsedAction(
                action: .toggleVariable(name: varName),
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
                let span = spans.key(holdVarKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(holdVarKey) is not allowed on -on-up paths",
                        source: span, bindingName: name))
                return nil
            }
            if !allowReservedVarNames && varName.hasPrefix("_seq_") {
                let span = spans.value(holdVarKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "\(holdVarKey) name '_seq_*' is reserved for "
                            + "[[sequence]] expansion",
                        source: span, bindingName: name))
                return nil
            }
            if row[setKey] != nil || row[setValKey] != nil {
                let span = spans.key(holdVarKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span)): "
                            + "\(holdVarKey) is mutually exclusive with "
                            + "action-set-var / action-set-value",
                        source: span, bindingName: name))
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
                let span = spans.value(setKey)
                warnings.append(
                    ConfigWarning(
                        kind: .actionSetParseError,
                        message:
                            "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                            + "\(setKey) name '_seq_*' is reserved for " + "[[sequence]] expansion",
                        source: span, bindingName: name))
                return nil
            }
            // `action-set-value` defaults to 1 (the leader-key case).
            // Writing 0 explicitly unsets the variable; non-int is an
            // error.
            let value: Int
            if let raw = row[setValKey] {
                guard let v = raw.asInt else {
                    let span = spans.value(setValKey)
                    warnings.append(
                        ConfigWarning(
                            kind: .actionSetParseError,
                            message:
                                "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                                + "\(setValKey) must be an integer",
                            source: span, bindingName: name))
                    return nil
                }
                value = Int(v)
            } else {
                value = 1
            }
            return ParsedAction(
                action: .setVariable(name: varName, value: value),
                raw: varName,
                aliasName: nil)
        }
        if row[setValKey] != nil {
            // Orphan: action-set-value without action-set-var. Common
            // typo — surfacing it explicitly beats silently ignoring.
            let span = spans.key(setValKey)
            warnings.append(
                ConfigWarning(
                    kind: .actionSetParseError,
                    message:
                        "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): "
                        + "\(setValKey) present without \(setKey)",
                    source: span, bindingName: name))
            return nil
        }
        if !required { return nil }
        let span = spans.header
        warnings.append(
            ConfigWarning(
                kind: .missingAction,
                message: "\(section) '\(name)'\(sourceTag(span)): no action-* key provided",
                source: span, bindingName: name))
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

        init(
            action: Action,
            extraKeys: [Action] = [],
            autoOnUpAction: Action? = nil,
            raw: String? = nil,
            aliasName: String? = nil
        ) {
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
    private enum ActionParseOutcome {
        case absent
        case ok(ParsedAction)
        case invalid  // warning already appended
    }
    private static func parseNativeAction(
        row: [String: TOML.Value],
        section: String, name: String, spans: RowSpans,
        warnings: inout [ConfigWarning]
    ) -> ActionParseOutcome {
        func warn(_ msg: String, field: String) {
            let span = spans.value(field)
            warnings.append(
                ConfigWarning(
                    kind: .actionKeysParseError,
                    message: "\(section) '\(name)'\(sourceTag(span)): \(msg)",
                    source: span, bindingName: name))
        }

        if let target = row["action-mission-control"]?.asString {
            switch target {
            case "show-all-windows":
                // ctrl + ↑ — macOS Mission Control default.
                return .ok(
                    ParsedAction(
                        action: .keys([.ctrl], 0x7E),
                        raw: "action-mission-control:show-all-windows"))
            case "show-app-windows":
                // ctrl + ↓ — App Exposé default.
                return .ok(
                    ParsedAction(
                        action: .keys([.ctrl], 0x7D),
                        raw: "action-mission-control:show-app-windows"))
            default:
                warn(
                    "action-mission-control: unknown value '\(target)' "
                        + "(expected show-all-windows / show-app-windows)",
                    field: "action-mission-control")
                return .invalid
            }
        }
        if let target = row["action-screenshot"]?.asString {
            switch target {
            case "selection":
                // cmd + shift + 4 (selection-to-file).
                return .ok(
                    ParsedAction(
                        action: .keys([.cmd, .shift], 0x15),
                        raw: "action-screenshot:selection"))
            case "screen":
                // cmd + shift + 3 (full screen-to-file).
                return .ok(
                    ParsedAction(
                        action: .keys([.cmd, .shift], 0x14),
                        raw: "action-screenshot:screen"))
            default:
                warn(
                    "action-screenshot: unknown value '\(target)' "
                        + "(expected selection / screen)",
                    field: "action-screenshot")
                return .invalid
            }
        }
        if row["action-spotlight"]?.asBool == true {
            // cmd + space — Spotlight default.
            return .ok(
                ParsedAction(
                    action: .keys([.cmd], 0x31),
                    raw: "action-spotlight:true"))
        }
        return .absent
    }

    /// The sibling keys that tune `action-drag-scroll`. Listed once so
    /// the parser, the orphan check, and the mutual-exclusion message
    /// cannot drift apart.
    static let dragScrollTuningKeys = [
        "action-drag-scroll-speed",
        "action-drag-scroll-axis",
        "action-drag-scroll-invert",
        "action-drag-scroll-max-ms"
    ]

    /// chord 3.0.0+ `action-drag-scroll = true` (+ its `-speed` /
    /// `-axis` / `-invert` / `-max-ms` siblings) → [Action.dragScroll].
    ///
    /// Rejects, rather than silently ignoring:
    ///   * the `-on-up` spelling (the mode's release half is implicit —
    ///     an explicit one would be a second owner of the same edge)
    ///   * a value other than `true` (with tuning siblings present, a
    ///     `false` here is a mistake, not a way to disable the binding)
    ///   * any other `action-*` on the same row — the `-on-up` halves
    ///     included, since the release they fire on is the same edge
    ///     that closes the mode
    ///   * out-of-domain tuning values
    private static func parseDragScrollAction(
        row: [String: TOML.Value],
        section: String, name: String, spans: RowSpans,
        suffix: String, fieldLabel: String,
        warnings: inout [ConfigWarning]
    ) -> ActionParseOutcome {
        let dragKey = "action-drag-scroll\(suffix)"
        guard let flag = row[dragKey] else { return .absent }

        func reject(_ msg: String, field: String) -> ActionParseOutcome {
            let span = spans.value(field) ?? spans.key(field)
            warnings.append(
                ConfigWarning(
                    kind: .dragScrollParseError,
                    message: "\(section) '\(name)'\(sourceTag(span))\(fieldLabel): \(msg)",
                    source: span, bindingName: name))
            return .invalid
        }

        if !suffix.isEmpty {
            return reject(
                "\(dragKey) is not allowed on -on-up paths — the mode "
                    + "already ends on the paired release",
                field: dragKey)
        }
        guard flag.asBool == true else {
            return reject(
                "\(dragKey) must be true (omit the key to disable the mode)",
                field: dragKey)
        }
        // One press, one owner — and the press is a SPAN, so the on-up
        // half counts too: `action-keys-on-up` would fire off the same
        // release edge that closes the mode. Both lists come from the
        // schema descriptor so a newly-added action-* is covered without
        // touching this line.
        let clashes =
            (ChordConfigSchema.actionUnionFields()
            + ChordConfigSchema.onUpFields())
            .map(\.key)
            .filter { $0 != dragKey && row[$0] != nil }
        if let clash = clashes.sorted().first {
            return reject(
                "\(dragKey) is mutually exclusive with \(clash) — it owns "
                    + "the whole down/up span",
                field: dragKey)
        }

        var spec = DragScrollSpec()

        if let raw = row["action-drag-scroll-speed"] {
            guard let v = raw.asDouble, v.isFinite, v > 0 else {
                return reject(
                    "action-drag-scroll-speed must be a number > 0",
                    field: "action-drag-scroll-speed")
            }
            spec.speed = v
        }
        if let raw = row["action-drag-scroll-axis"] {
            guard let s = raw.asString, let axis = DragScrollAxis(rawValue: s) else {
                let domain = DragScrollAxis.allCases.map(\.rawValue).joined(separator: " / ")
                return reject(
                    "action-drag-scroll-axis must be one of \(domain)",
                    field: "action-drag-scroll-axis")
            }
            spec.axis = axis
        }
        if let raw = row["action-drag-scroll-invert"] {
            guard let b = raw.asBool else {
                return reject(
                    "action-drag-scroll-invert must be a boolean",
                    field: "action-drag-scroll-invert")
            }
            spec.invert = b
        }
        if let raw = row["action-drag-scroll-max-ms"] {
            guard let v = raw.asInt, v > 0 else {
                return reject(
                    "action-drag-scroll-max-ms must be an integer > 0 (ms)",
                    field: "action-drag-scroll-max-ms")
            }
            spec.maxMs = v
        }

        return .ok(ParsedAction(action: .dragScroll(spec), raw: dragKey))
    }

    /// `action-drag-scroll-*` tuning present without the
    /// `action-drag-scroll` key that gives it meaning. Same shape as the
    /// `action-set-value`-without-`action-set-var` orphan check: a typo
    /// that silently does nothing is worse than a dropped binding.
    static func rejectOrphanDragScrollTuning(
        row: [String: TOML.Value],
        section: String, name: String, spans: RowSpans,
        warnings: inout [ConfigWarning]
    ) -> Bool {
        guard row["action-drag-scroll"] == nil else { return false }
        guard let orphan = dragScrollTuningKeys.filter({ row[$0] != nil }).sorted().first
        else { return false }
        let span = spans.key(orphan)
        warnings.append(
            ConfigWarning(
                kind: .dragScrollParseError,
                message:
                    "\(section) '\(name)'\(sourceTag(span)): "
                    + "\(orphan) present without action-drag-scroll",
                source: span, bindingName: name))
        return true
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
