// Config+Battery.swift — the `[battery]` table (chord 3.1.0+).
// Members of `enum Config`.

import Foundation

extension Config {
    /// Parse `[battery]` into a `ChordConfig.Battery`, or `nil` when it
    /// cannot run. `threshold` (integer 1–100) and `action-shell` (a
    /// non-empty string; `@name` resolves against `[action-aliases]` the way
    /// a binding's does) are both required — a threshold with nothing to
    /// run, or a command with nothing to fire it, is no watch at all, so any
    /// defect disables the whole table with a warning and leaves the rest of
    /// the config untouched. Unknown keys warn like `[options]` typos and
    /// are otherwise ignored.
    static func parseBattery(
        _ table: [String: TOML.Value],
        spans: RowSpans,
        actionAliases: [String: String],
        warnings: inout [ConfigWarning]
    ) -> ChordConfig.Battery? {
        let known = ChordConfigSchema.batteryShape().keySet
        for key in table.keys.sorted() where !known.contains(key) {
            let span = spans.key(key)
            warnings.append(
                ConfigWarning(
                    kind: .unknownKey,
                    message:
                        "[battery] '\(key)'\(sourceTag(span)): unknown key — ignored "
                        + "(known: \(known.sorted().joined(separator: ", ")))",
                    source: span))
        }

        var threshold: Int?
        if let value = table["threshold"] {
            if let raw = value.asInt {
                let percent = Int(raw)
                if (1...100).contains(percent) {
                    threshold = percent
                } else {
                    let span = spans.value("threshold")
                    warnings.append(
                        ConfigWarning(
                            kind: .batteryInvalid,
                            message:
                                "[battery] 'threshold'\(sourceTag(span)): \(percent) is outside "
                                + "1–100 (percent) — battery watch disabled",
                            source: span))
                }
            } else {
                warnBatteryType(
                    value, key: "threshold", expected: "integer", spans: spans, warnings: &warnings)
            }
        } else {
            warnings.append(
                ConfigWarning(
                    kind: .batteryInvalid,
                    message:
                        "[battery]\(sourceTag(spans.header)): 'threshold' (integer 1–100) is "
                        + "required — battery watch disabled",
                    source: spans.header))
        }

        var command: String?
        if let value = table["action-shell"] {
            if let raw = value.asString {
                let span = spans.value("action-shell")
                switch resolveAlias(raw, actionAliases: actionAliases) {
                case .body(let body, _):
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warnings.append(
                            ConfigWarning(
                                kind: .batteryInvalid,
                                message:
                                    "[battery] 'action-shell'\(sourceTag(span)): empty command — "
                                    + "battery watch disabled",
                                source: span))
                    } else {
                        command = body
                    }
                case .undefined(let aliasName):
                    warnings.append(
                        ConfigWarning(
                            kind: .undefinedActionAlias,
                            message:
                                "[battery] 'action-shell'\(sourceTag(span)): references undefined "
                                + "alias '@\(aliasName)' — battery watch disabled",
                            source: span))
                case .callError(let aliasName, let msg):
                    warnings.append(
                        ConfigWarning(
                            kind: .actionAliasCallError,
                            message:
                                "[battery] 'action-shell'\(sourceTag(span)): @\(aliasName) call "
                                + "error: \(msg) — battery watch disabled",
                            source: span))
                }
            } else {
                warnBatteryType(
                    value, key: "action-shell", expected: "string", spans: spans,
                    warnings: &warnings)
            }
        } else {
            warnings.append(
                ConfigWarning(
                    kind: .batteryInvalid,
                    message:
                        "[battery]\(sourceTag(spans.header)): 'action-shell' is required — "
                        + "battery watch disabled",
                    source: spans.header))
        }

        guard let threshold, let command else { return nil }
        return ChordConfig.Battery(threshold: threshold, actionShell: command)
    }

    /// `field-type-mismatch` for a `[battery]` key. Unlike an `[options]`
    /// key, whose type miss just keeps the default, a mistyped battery key
    /// disables the whole watch — so the message says so, like every other
    /// battery defect, instead of `warnFieldType`'s "value has no effect".
    private static func warnBatteryType(
        _ value: TOML.Value, key: String, expected: String, spans: RowSpans,
        warnings: inout [ConfigWarning]
    ) {
        let span = spans.value(key)
        warnings.append(
            ConfigWarning(
                kind: .fieldTypeMismatch,
                message:
                    "[battery] '\(key)'\(sourceTag(span)): expected \(expected), got "
                    + "\(tomlTypeName(value)) — battery watch disabled",
                source: span))
    }
}
