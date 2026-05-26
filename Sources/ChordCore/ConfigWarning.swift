import Foundation

/// Structured representation of a single config-parse warning.
///
/// Before PR2 every warning was a `String` flowing through
/// `ParseResult.warnings`. That worked for the human-facing
/// `--validate` output but offered nothing to machine consumers
/// (chord.bindings.v1 schema, canon's
/// `gen-chord-doc.py` / CI). `ConfigWarning` is the promoted form:
///
/// * `kind` — a stable enum slug downstream code can branch on
///   (`undefined-alias`, `unknown-input-token`, …) without having
///   to grep the message string. The raw values are part of the
///   schema's wire contract; renaming requires a schema major bump.
/// * `message` — the human-readable line; `description` returns it
///   verbatim so existing callers (`print("warning: \(w)")`)
///   keep working byte-for-byte.
/// * `sourceLine` — the 1-based config-file line, when known. Comes
///   from the `__line__` synthetic key the TOML parser injects on
///   every `[[X]]` header (`TOML.lineKey`). For `[aliases]` entries
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
        case undefinedAlias       = "undefined-alias"
        case aliasNonString       = "alias-non-string"
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
