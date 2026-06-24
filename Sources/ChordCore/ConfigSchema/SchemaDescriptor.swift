// SchemaDescriptor.swift — chord-LOCAL descriptor DATA for the config.toml
// INPUT surface (the keys a user writes), the single source for:
//   • `chord config --emit-schema` → the Draft-07 JSON Schema for taplo
//     editor completion (issue #78), and
//   • the parser's STRUCTURAL validation (unknown-key per section) — issue
//     #52, bounded: the descriptor owns the key inventory; the hand-written
//     leaf DSL parsing (InputParser / ActionParser / alias resolution) stays.
//
// The descriptor TYPES (`SchemaField` / `ObjectShape` / `SchemaSection` /
// `ExclusionRule` / `NestedTable`) and the JSON-Schema LOWERING now live in
// sill's `ConfigSchema` module (atelier #138 S1) — generalised so facet / wand
// / perch share one emitter. This file is the chord-specific DATA + the
// runtime-only-constraint catalog (which needs `ConfigWarning.Kind`, a
// chord-local type). `config.schema.json` stays byte-identical across the
// move — the only chord-specific output spellings (the `x-chord-constraints`
// vendor key, slash-escaping, no trailing newline) are passed as `EmitOptions`.
//
// This is NOT sill `ConfigSchema.Spec` (#52's full parser-unification is
// iceboxed — chord's config is an imperative DSL, not a flat decode), and it
// is NOT `chord.bindings.v3.json` (that is the parse-OUTPUT wire format; this
// models the config.toml INPUT).

import Foundation
import ConfigSchema

// MARK: - Shared field factories (reused across every binding-like context so
// a field added once lands everywhere — completeness is structural).

public enum ChordConfigSchema {
    public static let title = "chord config.toml"

    /// The `$comment` line carried into the emitted schema.
    static let comment = "chord config.toml INPUT schema (editor completion). "
        + "Regenerate: `chord config --emit-schema > config.schema.json`. "
        + "NOT chord.bindings.v3.json (the parse-OUTPUT wire format)."

    /// The action-* union members (key-down). Free-form vs enum vs const-true,
    /// matching ActionParser. mission-control / screenshot enum values are the
    /// `switch` cases in Config+Action.swift (the parser is the authority).
    static func actionUnionFields() -> [SchemaField] {
        [
            SchemaField("action-shell", .string,
                doc: "Shell command (run via /bin/sh -c). Supports @alias / @alias(a,b) refs from [action-aliases]. e.g. `open -a Safari`, `@focus_next`."),
            SchemaField("action-keys", .stringOrStringArray,
                doc: "Keystroke(s) to synthesise. A single string, or an array whose first element is primary and the rest fire in order. e.g. `\"cmd - c\"`, or `[\"cmd - a\", \"cmd - c\"]`."),
            SchemaField("action-noop", .constTrue,
                doc: "Consume the event and do nothing (block a key). Only `true` is meaningful."),
            SchemaField("action-set-var", .string,
                doc: "Set a state variable (used by when-var gates). Must not be a reserved `_seq_*` name."),
            SchemaField("action-set-value", .integer,
                doc: "Value for action-set-var (0 clears). Requires action-set-var.", defaultInt: 1),
            SchemaField("action-toggle-var", .string,
                doc: "Flip a state variable between 0 and 1."),
            SchemaField("action-hold-var", .string,
                doc: "Set the variable to 1 on key-down and back to 0 on key-up (momentary layer)."),
            SchemaField("action-mission-control", .string,
                doc: "macOS Mission Control action.",
                enumDomain: ["show-all-windows", "show-app-windows"],
                enumDocs: ["Show every open window (Mission Control).",
                           "Show all windows of the frontmost app (App Exposé)."]),
            SchemaField("action-screenshot", .string,
                doc: "macOS screenshot action.",
                enumDomain: ["selection", "screen"],
                enumDocs: ["Capture a selected region (⌘⇧4).",
                           "Capture the whole screen (⌘⇧3)."]),
            SchemaField("action-spotlight", .constTrue,
                doc: "Open Spotlight (cmd-space default). Only `true` is meaningful."),
        ]
    }

    /// The `-on-up` release-action mirror. action-keys-on-up is string-only
    /// (no array form). toggle-var/hold-var have no valid -on-up (the parser
    /// rejects those), so they are intentionally absent here.
    static func onUpFields() -> [SchemaField] {
        [
            SchemaField("action-shell-on-up", .string, doc: "Shell command to run on key-up."),
            SchemaField("action-keys-on-up", .string, doc: "Keystroke on key-up (string only — no array)."),
            SchemaField("action-noop-on-up", .constTrue, doc: "Consume the key-up. Only `true`."),
            SchemaField("action-set-var-on-up", .string, doc: "Set a state variable on key-up."),
            SchemaField("action-set-value-on-up", .integer, doc: "Value for action-set-var-on-up.", defaultInt: 1),
            // Recognised-to-reject (rejected = not schema-valid, kept out of
            // the emitted schema): toggle-var / hold-var own their own on-up
            // lifecycle, so an explicit -on-up form is a user error. The
            // parser (Config+Binding.hasOnUpAction) detects these to emit a
            // precise rejection; listing them here keeps the #52 unknown-key
            // check from also flagging them as a typo.
            SchemaField("action-toggle-var-on-up", .string,
                doc: "Invalid — toggle-var has no on-up half.", rejected: true),
            SchemaField("action-hold-var-on-up", .string,
                doc: "Invalid — hold-var already owns the on-up half.", rejected: true),
        ]
    }

    /// when-var / when-var-value / when-vars condition gate.
    static func gateFields() -> [SchemaField] {
        [
            SchemaField("when-var", .string, doc: "Only fire when this state variable equals when-var-value."),
            SchemaField("when-var-value", .integer, doc: "Expected value for when-var.", defaultInt: 1),
            SchemaField("when-vars", .intMap,
                doc: "AND gate: fire only when every `name = value` here matches. Non-empty; all integers. Mutually exclusive with when-var."),
        ]
    }

    /// hold-while / hold-while-timeout variable lifecycle.
    static func lifecycleFields() -> [SchemaField] {
        [
            SchemaField("hold-while", .string,
                doc: "Keep the set variable at 1 while these modifiers are held (≥1 modifier). Mutually exclusive with hold-while-timeout. e.g. `cmd + opt`."),
            SchemaField("hold-while-timeout", .integer,
                doc: "Clear the set variable after this many ms of inactivity (>0).", exclusiveMinimum: 0),
        ]
    }

    /// apps / input-source / passthrough / repeat scope fields.
    static func scopeFields() -> [SchemaField] {
        [
            SchemaField("apps", .stringArray,
                doc: "Bundle-id globs this binding applies to (`*` `?`); a `!` prefix excludes. Mutually exclusive with per-app. e.g. `[\"com.apple.Safari\"]`, or `[\"!com.apple.Terminal\"]` to exclude."),
            SchemaField("input-source", .stringOrStringArray,
                doc: "Restrict to keyboard input-source id(s)."),
            SchemaField("passthrough", .boolean,
                doc: "Let the original event reach the OS after firing.", defaultBool: false),
            // enumDocs are index-aligned to RepeatStrategy.allCases
            // (fire-each / ignore / passthrough) — ConfigSchemaShapeTests pins
            // both the enum order and the enumDocs length.
            SchemaField("repeat", .string,
                doc: "How key-repeat (typematic auto-repeat) is handled.",
                enumDomain: RepeatStrategy.allCases.map(\.rawValue),
                enumDocs: ["Fire the action on every repeat tick (default).",
                           "Fire once on key-down, swallow repeats (still consumed).",
                           "Fire once on key-down, let repeats reach the OS (niche)."]),
        ]
    }

    /// The cross-field rules shared by every binding-like context.
    static func commonExclusions() -> [ExclusionRule] {
        [
            .anyOfRequired(actionUnionFields().map(\.key)),
            .dependency(key: "action-set-value", needs: "action-set-var"),
            .dependency(key: "action-set-value-on-up", needs: "action-set-var-on-up"),
            .dependency(key: "when-var-value", needs: "when-var"),
            .forbidsTogether(["hold-while", "hold-while-timeout"]),
            .forbidsTogether(["when-var", "when-vars"]),
            .forbidsTogether(["apps", "per-app"]),
            .forbidsTogether(["action-set-var", "action-toggle-var"]),
            .forbidsTogether(["action-set-var", "action-hold-var"]),
            .forbidsTogether(["action-toggle-var", "action-hold-var"]),
        ]
    }

    static func nameField() -> SchemaField {
        SchemaField("name", .string, doc: "Display name; defaults to `binding-N`.")
    }

    // MARK: Runtime-only constraints (x-chord-constraints)

    /// A cross-cutting rule the daemon enforces at load that Draft-07 cannot
    /// express — emitted as `x-chord-constraints` hover text. Each carries the
    /// ConfigWarning.Kind(s) it documents so ConfigConstraintCoverageTests can
    /// assert every binding-relevant runtime-only kind is surfaced (and the
    /// rest are explicitly classified as not-surfaced).
    public struct RuntimeConstraint: Sendable, Equatable {
        public let kinds: [ConfigWarning.Kind]
        public let text: String
        public init(_ kinds: [ConfigWarning.Kind], _ text: String) {
            self.kinds = kinds; self.text = text
        }
    }

    /// The runtime-only rules surfaced in binding-like hovers. These STAY
    /// runtime-only (they need a symbol table from another table, uniqueness on
    /// a derived key, or case-folding — none expressible in Draft-07);
    /// `chord config --validate` / the daemon remain the enforcement authority.
    public static let runtimeConstraints: [RuntimeConstraint] = [
        RuntimeConstraint([.undefinedActionAlias],
            "`@name` in action-shell must be defined in [action-aliases]; an undefined reference drops the binding."),
        RuntimeConstraint([.undefinedInputAlias],
            "`$name` in input must be defined in [input-aliases]; an undefined reference drops the binding."),
        RuntimeConstraint([.vkeyAliasInvalid],
            "A bare v-key input must be defined in [v-key-aliases] (id 1–255) and must not shadow a built-in key or modifier."),
        RuntimeConstraint([.inputAliasShadowsModifier],
            "[input-aliases] names must not shadow built-in modifier tokens (cmd / ctrl / shift / opt / fn and L/R variants)."),
        RuntimeConstraint([.duplicateBindingName],
            "Each user-set `name` must be unique across [[bindings]] (auto `binding-N` names are exempt)."),
        RuntimeConstraint([.actionSetParseError],
            "`action-set-var` must not use a reserved `_seq_*` name (those are reserved for [[sequence]] state)."),
        RuntimeConstraint([.sequenceParseError],
            "A [[bindings]] trigger must not collide with a [[sequence]] prefix; a sequence `name` must not be `_seq_*`."),
    ]

    /// The hover strings for binding-like shapes (bindings / fallbacks /
    /// sequence children). Derived from [runtimeConstraints] so the catalog is
    /// the single source.
    static func bindingConstraints() -> [String] { runtimeConstraints.map(\.text) }

    // MARK: Per-context shapes

    /// `[[bindings]]` — input required, no wildcard, per-app nesting allowed.
    static func bindingShape() -> ObjectShape {
        ObjectShape(
            fields: [
                nameField(),
                SchemaField("input", .string,
                    doc: "Trigger: `[MODIFIERS -] KEY`. Supports $input-aliases, side-aware L/R, scroll.up/down. e.g. `cmd + opt - f13`, `ctrl - scroll.up`, `$ULTRA - c`."),
            ] + actionUnionFields() + onUpFields() + gateFields() + lifecycleFields() + scopeFields(),
            required: ["input"],
            exclusions: commonExclusions(),
            nested: [NestedTable(key: "per-app", item: perAppShape())],
            doc: "A key/chord → action binding.",
            initKeys: ["input", "action-keys"],
            constraints: bindingConstraints())
    }

    /// `[[bindings.per-app]]` — bundle-id required, every field an optional
    /// override; no nested apps/per-app.
    static func perAppShape() -> ObjectShape {
        ObjectShape(
            fields: [
                SchemaField("bundle-id", .string, doc: "App this override applies to (bundle id)."),
                SchemaField("input", .string, doc: "Optional per-app input override."),
            ] + actionUnionFields() + onUpFields() + gateFields() + lifecycleFields() + scopeFields().filter { $0.key != "apps" },
            required: ["bundle-id"],
            // A per-app entry LAYERS onto the base binding, so its action is
            // optional (drop the action-union requirement); and it owns no
            // apps/per-app of its own (drop that forbids rule).
            exclusions: commonExclusions().filter { rule in
                switch rule {
                case .anyOfRequired: return false
                case .forbidsTogether(let g) where g.contains("apps"): return false
                default: return true
                }
            },
            doc: "Per-app override layered onto the parent binding.")
    }

    /// `[[fallbacks]]` — input xor inputs, wildcard `*` allowed, no per-app.
    static func fallbackShape() -> ObjectShape {
        ObjectShape(
            fields: [
                nameField(),
                SchemaField("input", .string,
                    doc: "Trigger; the wildcard `*` is allowed here (catch-all). Mutually exclusive with inputs. e.g. `*`, `cmd - a`."),
                SchemaField("inputs", .stringArray,
                    doc: "Multiple triggers sharing one action. Mutually exclusive with input."),
            ] + actionUnionFields() + onUpFields() + gateFields() + lifecycleFields() + scopeFields(),
            exclusions: [.oneOfRequired(["input", "inputs"])] + commonExclusions(),
            doc: "A lower-priority binding tried only when no [[bindings]] row matched.",
            constraints: bindingConstraints())
    }

    /// `[[sequence]]` — prefix + timeout-ms + nested bindings (leader key).
    static func sequenceShape() -> ObjectShape {
        ObjectShape(
            fields: [
                SchemaField("name", .string, doc: "Sequence name; must not be a reserved `_seq_*` name."),
                SchemaField("prefix", .string, doc: "Leader trigger (≥1 modifier). e.g. `cmd - g`."),
                SchemaField("timeout-ms", .integer, doc: "How long the prefix stays armed (ms, >0).", exclusiveMinimum: 0),
            ],
            required: ["prefix", "timeout-ms", "bindings"],
            nested: [NestedTable(key: "bindings", item: sequenceBindingShape(), required: true, nonEmpty: true)],
            doc: "Leader-key sequence: arm a prefix, then its child bindings fire within the timeout.",
            initKeys: ["prefix", "timeout-ms"])
    }

    /// `[[sequence.bindings]]` — child of a sequence; input primary-only.
    static func sequenceBindingShape() -> ObjectShape {
        ObjectShape(
            fields: [
                nameField(),
                SchemaField("input", .string, doc: "Child trigger fired after the prefix."),
            ] + actionUnionFields() + onUpFields() + gateFields() + lifecycleFields() + scopeFields(),
            required: ["input"],
            exclusions: commonExclusions(),
            doc: "A binding active only after its sequence prefix is armed.",
            constraints: bindingConstraints())
    }

    /// `[[remap]]` — modifiers + map of source→action-keys.
    static func remapShape() -> ObjectShape {
        ObjectShape(
            fields: [
                SchemaField("name", .string, doc: "Remap group name."),
                SchemaField("modifiers", .string, doc: "Modifier mask applied to every map entry (≥1 modifier). e.g. `cmd + opt`."),
                SchemaField("map", .stringMap, doc: "source-key → action-keys string. Non-empty. e.g. `{ h = \"left\", l = \"right\" }`."),
                SchemaField("apps", .stringArray, doc: "Bundle-id globs this remap applies to."),
            ],
            required: ["modifiers", "map"],
            doc: "Bulk key→key remap expanded into one binding per map entry.")
    }

    static func optionsShape() -> ObjectShape {
        ObjectShape(
            fields: [
                SchemaField("passthrough-unmatched", .boolean,
                    doc: "Let unmatched events reach the OS (default true).", defaultBool: true),
                SchemaField("exclude-apps", .stringArray,
                    doc: "Bundle-id globs where chord stays fully passive."),
                SchemaField("fn-auto-arrows", .boolean,
                    doc: "Map fn+hjkl etc. to arrows automatically (default true).", defaultBool: true),
            ],
            doc: "Global options. All keys optional.")
    }

    /// The single source of truth: every config.toml section.
    public static var sections: [SchemaSection] {
        [
            SchemaSection("options", .table(optionsShape()), doc: "Global options."),
            SchemaSection("action-aliases",
                .openStringMap(valueDoc: "Shell command body. Reference via @name in action-shell."),
                doc: "name → shell command. Open vocabulary."),
            SchemaSection("input-aliases",
                .openStringMap(valueDoc: "Modifier-set string, e.g. 'cmd + opt'. Reference via $name in input."),
                doc: "name → modifier-set string. Names must not shadow built-in modifier tokens."),
            SchemaSection("v-key-aliases",
                .openIntMap(valueDoc: "Vendor-HID v-key id 1–255 (the value `&vkey <id>` sends).", min: 1, max: 255),
                doc: "name → vendor-HID v-key id. Reference via a bare `input = \"<name>\"` (no $ sigil — a complete trigger like `f13`). Names must not shadow built-in keys / modifiers."),
            SchemaSection("bindings", .arrayOfTables(bindingShape()), doc: "The primary key→action bindings."),
            SchemaSection("fallbacks", .arrayOfTables(fallbackShape()), doc: "Lower-priority catch-all bindings."),
            SchemaSection("sequence", .arrayOfTables(sequenceShape()), doc: "Leader-key sequences."),
            SchemaSection("remap", .arrayOfTables(remapShape()), doc: "Bulk key remaps."),
        ]
    }

    // MARK: Emit (delegated to sill's shared lowering)

    /// The whole config.toml input surface as a sill `SchemaDescriptor`.
    static var descriptor: SchemaDescriptor {
        SchemaDescriptor(title: title, comment: comment, sections: sections)
    }

    /// The emitted Draft-07 JSON Schema for config.toml (no trailing newline,
    /// matching the sibling apps' `--emit-schema`). chord's output spellings —
    /// the `x-chord-constraints` vendor key, escaped slashes, no trailing
    /// newline — are the `EmitOptions`; everything else is sill's shared
    /// lowering. NOT chord.bindings.v3.json (the parse-OUTPUT wire format).
    public static var jsonSchema: String {
        descriptor.jsonSchema(options: .init(escapeSlashes: true,
                                             trailingNewline: false,
                                             constraintsKey: "x-chord-constraints"))
    }
}
