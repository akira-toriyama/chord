import Foundation

/// Structured representation of a single config-parse warning.
///
/// Before PR2 every warning was a `String` flowing through
/// `ParseResult.warnings`. That worked for the human-facing
/// `config --validate` output but offered nothing to machine consumers
/// (the chord.bindings.v* JSON schemas, canon's
/// `gen-chord-doc.py` / CI). `ConfigWarning` is the promoted form:
///
/// * `kind` — a stable enum slug downstream code can branch on
///   (`undefined-alias`, `unknown-input-token`, …) without having
///   to grep the message string. The raw values are part of the
///   schema's wire contract; renaming requires a schema major bump
///   (e.g. `chord.bindings.v3` → `v4`). Adding new values is
///   forward-compatible if consumers branch defensively.
/// * `message` — the human-readable line; `description` returns it
///   verbatim so existing callers (`print("warning: \(w)")`)
///   keep working byte-for-byte.
/// * `sourceLine` — the 1-based config-file line, when known. Comes
///   from the `Toml.Row.span` each `[[X]]` row carries (swift-toml-edit
///   2.0.0; resolved at parse time and threaded into the binding). For
///   `[action-aliases]` entries and `[options]` table fields, lines are
///   not tracked (plain `[table]`s carry no span) — surfaces as `nil`.
/// * `bindingName` — the row's `name` (or the synthetic `binding-N`
///   fallback) when the warning is attributable to a single binding.
public struct ConfigWarning: Sendable, Hashable, CustomStringConvertible {

    /// Stable identifiers exposed in the JSON schema. Renaming any
    /// value is a breaking change for consumers — bump the schema
    /// major (`chord.bindings.v3` → `v4`) instead.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case configNotFound       = "config-not-found"
        case missingInput         = "missing-input"
        case missingAction        = "missing-action"
        case unknownInputToken    = "unknown-input-token"
        case actionKeysParseError = "action-keys-parse-error"
        /// `action-keys-delay-ms` is present but not a positive integer
        /// (inter-key delay for a multi-key `action-keys` array).
        case actionKeysDelayParseError = "action-keys-delay-parse-error"
        /// `[action-aliases]` entry whose value isn't a string.
        /// (was `aliasNonString` / `alias-non-string` before the split)
        case actionAliasNonString = "action-alias-non-string"
        /// A binding's `action-shell` contains an `@name` reference
        /// whose `name` is not in `[action-aliases]`.
        /// (was `undefinedAlias` / `undefined-alias` before the split)
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
        /// `[v-key-aliases]` entry is malformed: value not an integer,
        /// id out of 1–255, name shadows a real key / modifier / the
        /// `v-key` wildcard, or a duplicate name. The entry is ignored.
        case vkeyAliasInvalid     = "v-key-alias-invalid"
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
        /// v0.9.0: `@name(args)` call-site error — alias body has
        /// `{{N}}` placeholder but the call doesn't supply enough
        /// args, or the parenthesised arg list is malformed.
        case actionAliasCallError = "action-alias-call-error"
        /// `[options]` contains a key the parser doesn't recognise
        /// (most often a typo: `passthroughUnmatched` instead of
        /// `passthrough-unmatched`). The unknown key is silently
        /// ignored at runtime, so without this warning a typo would
        /// look like "the option doesn't work". --strict turns it
        /// into a hard exit 1.
        case unknownOptionKey     = "unknown-option-key"
        /// #52-bounded: a `[[bindings]]` / `[[fallbacks]]` / `[[sequence]]`
        /// / `[[remap]]` row (or a nested `per-app` / `sequence.bindings`
        /// row) contains a key the descriptor doesn't recognise (a typo:
        /// `actoin-shell`, `passthrouh`) — OR a top-level SECTION header is
        /// itself mistyped (`[[bindigs]]`, `[optoins]`), so the rows it
        /// "contains" load into a section nothing reads. Either way the key
        /// / section is silently ignored at runtime, so without this warning
        /// the typo would look like it just "didn't take". --strict turns it
        /// into exit 1. The known inventory (section names + each section's
        /// keys) is the same `ChordConfigSchema` descriptor that drives
        /// `--emit-schema`, so the two can't drift.
        case unknownKey           = "unknown-key"
        /// Two or more user-named `[[bindings]]` rows share the same
        /// `name`. Both still load (chord doesn't enforce unique
        /// names) but `config --show --json` consumers and the `daemon
        /// --reload --dry-run` name-keyed diff can't tell them apart. Synth
        /// `binding-N` names (from rows without a user-supplied
        /// `name`) are exempt.
        case duplicateBindingName = "duplicate-binding-name"
        /// An optional `[options]` or `[[bindings]]` field is *present
        /// but of the wrong TOML type* (e.g. `passthrough = "true"`
        /// — a string where a boolean is expected, or `input-source
        /// = 3`). The loader reads these through `?.asBool` /
        /// `?.asArray`, which return `nil` on a type miss, so the value
        /// would otherwise be silently skipped and the default left in
        /// place — looking exactly like "the option had no effect". The
        /// field-level miss fires once; an array field with non-string
        /// elements (silently dropped by `compactMap`) fires once too.
        /// --strict turns it into a hard exit 1.
        case fieldTypeMismatch    = "field-type-mismatch"
        /// Reserved for future surface-area expansion (e.g.
        /// `[include]` cycles). Kept as a catch-all so a downstream
        /// consumer's match-exhaustion never breaks.
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
