import Foundation

/// Structured representation of a single config-parse warning.
///
/// Before PR2 every warning was a `String` flowing through
/// `ParseResult.warnings`. That worked for the human-facing
/// `--validate` output but offered nothing to machine consumers
/// (the chord.bindings.v* JSON schemas, canon's
/// `gen-chord-doc.py` / CI). `ConfigWarning` is the promoted form:
///
/// * `kind` — a stable enum slug downstream code can branch on
///   (`undefined-alias`, `unknown-input-token`, …) without having
///   to grep the message string. The raw values are part of the
///   schema's wire contract; renaming requires a schema major bump
///   (e.g. `chord.bindings.v3` → `v3`). Adding new values is
///   forward-compatible if consumers branch defensively.
/// * `message` — the human-readable line; `description` returns it
///   verbatim so existing callers (`print("warning: \(w)")`)
///   keep working byte-for-byte.
/// * `sourceLine` — the 1-based config-file line, when known. Comes
///   from the `__line__` synthetic key the TOML parser injects on
///   every `[[X]]` header (`TOML.lineKey`). For `[actionAliases]` entries
///   and `[options]` table fields, lines are not tracked yet —
///   surfaces as `nil`.
/// * `bindingName` — the row's `name` (or the synthetic `binding-N`
///   fallback) when the warning is attributable to a single binding.
public struct ConfigWarning: Sendable, Hashable, CustomStringConvertible {

    /// Stable identifiers exposed in the JSON schema. Renaming any
    /// value is a breaking change for consumers — bump the schema
    /// major (`chord.bindings.v1` → `v2`) instead.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case configNotFound       = "config-not-found"
        case missingInput         = "missing-input"
        case missingAction        = "missing-action"
        case unknownInputToken    = "unknown-input-token"
        case actionKeysParseError = "action-keys-parse-error"
        /// `[action-actionAliases]` entry whose value isn't a string.
        /// (was `aliasNonString` / `alias-non-string` in schema v2)
        case actionAliasNonString = "action-alias-non-string"
        /// A binding's `action-shell` contains an `@name` reference
        /// whose `name` is not in `[action-actionAliases]`.
        /// (was `undefinedAlias` / `undefined-alias` in schema v2)
        case undefinedActionAlias = "undefined-action-alias"
        /// `[input-aliases]` entry whose value isn't a string.
        case inputAliasNonString  = "input-alias-non-string"
        /// `[input-aliases]` name collides with a built-in modifier
        /// token (cmd/ctrl/shift/…). The alias is rejected to keep
        /// `parse("cmd - a")` deterministic.
        case inputAliasShadowsModifier = "input-alias-shadows-modifier"
        /// `[input-aliases]` value fails to parse as a modifier list.
        /// Nested alias references (an alias body referring to another
        /// alias name) trigger this — bodies must be made of built-in
        /// modifier tokens only.
        case inputAliasInvalidBody = "input-alias-invalid-body"
        /// A binding's `input = "..."` contains a `$name` reference
        /// whose `name` is not in `[input-aliases]`. Parallel to
        /// `undefinedAlias` for shell-action `@name` references.
        case undefinedInputAlias  = "undefined-input-alias"
        /// v2: `when-var` / `when-var-value` malformed or orphan.
        case conditionParseError  = "condition-parse-error"
        /// v2: `hold-while = "…"` fails to parse as a modifier mask.
        case holdWhileParseError  = "hold-while-parse-error"
        /// v2: `action-set-var` / `action-set-value` malformed.
        case actionSetParseError  = "action-set-parse-error"
        /// v0.7.0: `[[sequence]]` row malformed (missing prefix /
        /// timeout-ms / bindings, duplicate sequence name, prefix
        /// without modifier, etc.) or a regular `[[bindings]]` row
        /// collides with a sequence prefix.
        case sequenceParseError   = "sequence-parse-error"
        /// v0.8.0: `[[remap]]` row malformed (missing modifiers / map,
        /// modifiers without any modifier token, non-string map value,
        /// etc.).
        case remapParseError      = "remap-parse-error"
        /// v0.8.0: `[[bindings.per-app]]` sub-row malformed (missing
        /// bundle-id, empty per-app array, `apps` and `per-app`
        /// simultaneously set).
        case perAppParseError     = "per-app-parse-error"
        /// Reserved for future surface-area expansion (e.g.
        /// `[include]` cycles, option key typos). Kept as a catch-all
        /// so a downstream consumer's match-exhaustion never breaks.
        case other                = "other"
    }

    public let kind: Kind
    public let message: String
    public let sourceLine: Int?
    public let bindingName: String?

    public init(kind: Kind, message: String,
                sourceLine: Int? = nil,
                bindingName: String? = nil) {
        self.kind = kind
        self.message = message
        self.sourceLine = sourceLine
        self.bindingName = bindingName
    }

    public var description: String { message }
}
