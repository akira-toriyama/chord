import Foundation

/// Wire format for `chord --list --json` / `chord --validate --json`,
/// versioned `chord.bindings.v3` (was v1 through 0.3.x). The JSON
/// Schema published at `docs/schema/chord.bindings.v3.json` is the
/// canonical contract; every field in this file is mirrored there.
///
/// v2 additions over v1:
///   * action.kind = "set-variable" with `variable` + `value` fields
///   * binding.condition (state-gate predicate)
///   * binding.hold_while  (modifier-mask lifecycle for variables)
///   * binding.action_on_up (release action)
///   * three new dropped[].kind values for the new fields' parse errors
///
/// Consumers still pinned to v1 will reject these documents under
/// strict-schema validation (`additionalProperties: false` on the v1
/// binding object). Either re-pin to v2 or vendor the v2 schema.
///
/// Design choices (locked for v1):
///
/// * **Modifier side encoded per-category** (`modifier_sides:
///   {"ctrl": "right"}`), not as a flat array mixing `ctrl` and
///   `rctrl`. canon's Q1-2: consuming-side code stays clean
///   when "logical modifier" and "physical side" are orthogonal.
/// * **`apps` absent vs `apps: []`** — absent means "any app" (the
///   user didn't write `apps`); `[]` means "explicitly empty list".
///   The TOML parser folds `["*"]` to nil (→ omitted by encoder).
/// * **Nil-Optional fields are OMITTED** from the JSON output, not
///   emitted as explicit `null`. This is JSONEncoder's default
///   behaviour. The schema's required[] lists reflect this — a
///   consumer treating absent and null as equivalent (jq's `.field`
///   returns `null` for both) doesn't need to care.
/// * **`dropped[].kind`** is a stable string drawn from
///   [ConfigWarning.Kind] so machine consumers can branch without
///   grepping the message.
/// * **`generated_at`** is ISO-8601 UTC with fractional seconds.
///   Consumers should treat it as informational only — not a stable
///   sort key.
public enum BindingsSchema {

    public static let version = "chord.bindings.v3"

    /// Where the running daemon snapshots its last-loaded state, so
    /// `chord --reload --dry-run` can diff the on-disk config
    /// against what would actually change. Volatile (per-boot) by
    /// design — the daemon refreshes it on every loadConfig, and
    /// without a running daemon the dry-run treats absent snapshot
    /// as an empty "before" (every binding shows as "added").
    public static let snapshotPath = "/tmp/chord-loaded.json"

    /// Top-level wire document.
    public struct Document: Codable, Sendable {
        public let schema: String
        public let generatedAt: String
        public let sourcePath: String?
        public let options: WireOptions
        public let actionAliases: [String: String]
        /// `[input-aliases]` table — bare-reference modifier-set
        /// aliases for matching `input = "…"`. Each entry is a logical
        /// name (e.g. `"ULTRA_LL"`) → modifier-list body (e.g.
        /// `"rctrl + ralt + rshift"`). Resolution happens at the
        /// parser layer; this surface is purely for documentation /
        /// introspection. Schema-v2.x forward-compatible addition.
        public let inputAliases: [String: String]
        public let bindings: [WireBinding]
        public let fallbacks: [WireBinding]
        public let dropped: [WireDropped]
        /// Populated by `chord --validate --json`, absent on
        /// `chord --list --json`. Lets CI surface validation
        /// status structurally without re-deriving it from
        /// `dropped[].length` + exit code.
        public let validation: WireValidation?

        enum CodingKeys: String, CodingKey {
            case schema, options, bindings, fallbacks, dropped, validation
            case generatedAt   = "generated_at"
            case sourcePath    = "source_path"
            case actionAliases = "action_aliases"
            case inputAliases  = "input_aliases"
        }
    }

    /// Validation summary block, populated only by --validate emitters.
    public struct WireValidation: Codable, Sendable {
        /// What the process would exit with: `true` ⇔ exit 0.
        /// Independent of `strict` — `ok` already accounts for it.
        public let ok: Bool
        /// Whether `--strict` was passed. Lets consumers
        /// distinguish "we ran lenient and it passed because drops
        /// don't fail by default" from "we ran strict and it
        /// passed because there were no warnings at all".
        public let strict: Bool
        public let parsedCounts: WireParsedCounts
        public let droppedCount: Int
        public let warningCount: Int
        public let undefinedActionAliases: Int

        enum CodingKeys: String, CodingKey {
            case ok, strict
            case parsedCounts     = "parsed_counts"
            case droppedCount     = "dropped_count"
            case warningCount     = "warning_count"
            case undefinedActionAliases = "undefined_action_aliases"
        }
    }

    public struct WireParsedCounts: Codable, Sendable {
        public let bindings: Int
        public let fallbacks: Int
        public let actionAliases: Int
    }

    public struct WireOptions: Codable, Sendable {
        public let passthroughUnmatched: Bool
        public let excludeApps: [String]
        /// chord 0.8.0+: when true (default), arrow / nav triggers
        /// ignore the `fn` bit during matching. Schema-v3.x
        /// forward-compatible addition; older v3 consumers that
        /// ignore unknown options keep working.
        public let fnAutoArrows: Bool

        enum CodingKeys: String, CodingKey {
            case passthroughUnmatched = "passthrough_unmatched"
            case excludeApps          = "exclude_apps"
            case fnAutoArrows         = "fn_auto_arrows"
        }
    }

    public struct WireBinding: Codable, Sendable, Hashable {
        public let index: Int
        public let name: String
        public let sourceLine: Int?
        public let input: WireInput
        public let apps: [String]?
        public let action: WireAction
        /// v2: optional state-gate predicate. `nil` ⇒ no gate; the
        /// binding fires whenever input + apps match.
        public let condition: WireCondition?
        /// v2: modifier-mask tying a variable's lifecycle to a held-
        /// down mod set. Tokens drawn from `modifier_token`.
        public let holdWhile: [String]?
        /// Inactivity timeout (ms) lifecycle (added in chord 0.4.0).
        /// Mutually exclusive with [holdWhile]; the parser drops the
        /// binding if both are set.
        public let holdWhileTimeoutMs: Int?
        /// v2: secondary action that fires on the matching key's
        /// release. Same shape as `action`.
        public let actionOnUp: WireAction?
        /// v3.x: additional actions that fire on the same key-down,
        /// in order, after `action` (Karabiner `to`-array shape).
        /// Absent when the binding has only the single primary action.
        public let extraActions: [WireAction]?
        /// chord 0.9.0+: when `true`, the original event reaches the
        /// OS in addition to firing `action`. Absent (= omitted from
        /// JSON) when `false` — the common case.
        public let passthrough: Bool?

        enum CodingKeys: String, CodingKey {
            case index, name, input, apps, action, condition
            case sourceLine         = "source_line"
            case holdWhile          = "hold_while"
            case holdWhileTimeoutMs = "hold_while_timeout"
            case actionOnUp         = "action_on_up"
            case extraActions       = "extra_actions"
            case passthrough
        }
    }

    public struct WireCondition: Codable, Sendable, Hashable {
        /// Discriminator. `"variable"` is the v2 single-equality
        /// shape; `"all"` (chord 0.9.0+) is the AND-of-N form whose
        /// `conditions[]` carries nested predicates.
        public let kind: String
        /// Populated when `kind == "variable"`.
        public let variable: String?
        public let equals: Int?
        /// Populated when `kind == "all"`. Nested WireConditions
        /// follow the same shape recursively.
        public let conditions: [WireCondition]?
    }

    public struct WireInput: Codable, Sendable, Hashable {
        /// Original `input = "..."` user string, verbatim.
        public let raw: String
        /// Canonical token list — both any-side (`ctrl`) and
        /// side-specific (`rctrl`) tokens appear if both were set on
        /// the binding constraint. Sorted alphabetically for stable
        /// output.
        public let modifiers: [String]
        /// Per-modifier-category side requirement.
        /// Each value: `"absent"` | `"any"` | `"left"` | `"right"`
        /// | `"both"`. `fn` is reported as a separate bool below.
        public let modifierSides: ModifierSides
        public let fn: Bool
        public let trigger: WireTrigger

        enum CodingKeys: String, CodingKey {
            case raw, modifiers, fn, trigger
            case modifierSides = "modifier_sides"
        }
    }

    public struct ModifierSides: Codable, Sendable, Hashable {
        public let cmd: String
        public let opt: String
        public let ctrl: String
        public let shift: String
    }

    public struct WireTrigger: Codable, Sendable, Hashable {
        /// `"key"` | `"mouseButton"` | `"scroll"` | `"anyKey"`.
        public let kind: String
        public let name: String?
        public let keycode: UInt16?
    }

    public struct WireAction: Codable, Sendable, Hashable {
        /// `"keys"` | `"shell"` | `"noop"` | `"set-variable"` (v2) |
        /// `"toggle-variable"` (chord 0.9.0+).
        public let kind: String
        /// `action-shell` / `action-keys` / `action-set-var`
        /// original user string. `nil` for `noop`.
        public let raw: String?
        /// `keys` only — canonical modifier-token list.
        public let modifiers: [String]?
        /// `keys` only — key payload.
        public let key: WireKey?
        /// `shell` only — resolved command (post-alias if applicable).
        public let command: String?
        /// `shell` only — alias name used (without leading `@`), or
        /// `nil` if no alias was referenced.
        public let alias: String?
        /// `set-variable` only — variable name.
        public let variable: String?
        /// `set-variable` only — value (0 = clear).
        public let value: Int?
    }

    public struct WireKey: Codable, Sendable, Hashable {
        public let name: String
        public let keycode: UInt16
    }

    public struct WireDropped: Codable, Sendable {
        /// `"[[bindings]]"` | `"[[fallbacks]]"` | `"[actionAliases]"` —
        /// matches the literal section header the warning fired in.
        public let section: String
        public let name: String?
        public let sourceLine: Int?
        /// Stable [ConfigWarning.Kind] raw value.
        public let kind: String
        public let message: String

        enum CodingKeys: String, CodingKey {
            case section, name, kind, message
            case sourceLine = "source_line"
        }
    }

    // MARK: - diff (chord --reload --dry-run)

    /// Outcome of comparing a previously-loaded snapshot against the
    /// freshly-parsed config. Bindings are matched by `name`; a name
    /// that exists on both sides is `changed` iff the semantic
    /// fields differ (line numbers are ignored — they shift when the
    /// user inserts unrelated rows above). `[[fallbacks]]` are
    /// compared as their own bucket with the same rules.
    public struct Diff: Sendable {
        public struct Change: Sendable {
            public let old: WireBinding
            public let new: WireBinding
        }
        public var addedBindings:    [WireBinding] = []
        public var removedBindings:  [WireBinding] = []
        public var changedBindings:  [Change]      = []
        public var unchangedBindingCount: Int      = 0
        public var addedFallbacks:   [WireBinding] = []
        public var removedFallbacks: [WireBinding] = []
        public var changedFallbacks: [Change]      = []
        public var unchangedFallbackCount: Int     = 0
        public var actionAliasesAdded:   [String: String] = [:]
        public var actionAliasesRemoved: [String: String] = [:]
        public var actionAliasesChanged: [(name: String, oldBody: String, newBody: String)] = []
        public var inputAliasesAdded:   [String: String] = [:]
        public var inputAliasesRemoved: [String: String] = [:]
        public var inputAliasesChanged: [(name: String, oldBody: String, newBody: String)] = []

        public var isClean: Bool {
            addedBindings.isEmpty && removedBindings.isEmpty
                && changedBindings.isEmpty
                && addedFallbacks.isEmpty && removedFallbacks.isEmpty
                && changedFallbacks.isEmpty
                && actionAliasesAdded.isEmpty && actionAliasesRemoved.isEmpty
                && actionAliasesChanged.isEmpty
                && inputAliasesAdded.isEmpty && inputAliasesRemoved.isEmpty
                && inputAliasesChanged.isEmpty
        }
    }

    /// Diff two documents by `name`. `old` may be `nil` when no
    /// snapshot was found — every binding then surfaces as added.
    public static func diff(old: Document?, new: Document) -> Diff {
        var d = Diff()
        diffBucket(old: old?.bindings ?? [], new: new.bindings,
                   added: &d.addedBindings,
                   removed: &d.removedBindings,
                   changed: &d.changedBindings,
                   unchanged: &d.unchangedBindingCount)
        diffBucket(old: old?.fallbacks ?? [], new: new.fallbacks,
                   added: &d.addedFallbacks,
                   removed: &d.removedFallbacks,
                   changed: &d.changedFallbacks,
                   unchanged: &d.unchangedFallbackCount)
        let oldActionAliases = old?.actionAliases ?? [:]
        for (k, v) in new.actionAliases where oldActionAliases[k] == nil {
            d.actionAliasesAdded[k] = v
        }
        for (k, v) in oldActionAliases where new.actionAliases[k] == nil {
            d.actionAliasesRemoved[k] = v
        }
        for (k, newV) in new.actionAliases {
            if let oldV = oldActionAliases[k], oldV != newV {
                d.actionAliasesChanged.append((k, oldV, newV))
            }
        }
        let oldInputAliases = old?.inputAliases ?? [:]
        for (k, v) in new.inputAliases where oldInputAliases[k] == nil {
            d.inputAliasesAdded[k] = v
        }
        for (k, v) in oldInputAliases where new.inputAliases[k] == nil {
            d.inputAliasesRemoved[k] = v
        }
        for (k, newV) in new.inputAliases {
            if let oldV = oldInputAliases[k], oldV != newV {
                d.inputAliasesChanged.append((k, oldV, newV))
            }
        }
        return d
    }

    private static func diffBucket(
        old: [WireBinding], new: [WireBinding],
        added: inout [WireBinding],
        removed: inout [WireBinding],
        changed: inout [Diff.Change],
        unchanged: inout Int
    ) {
        let oldByName = Dictionary(uniqueKeysWithValues:
            old.map { ($0.name, $0) })
        let newByName = Dictionary(uniqueKeysWithValues:
            new.map { ($0.name, $0) })
        for (name, n) in newByName.sorted(by: { $0.key < $1.key }) {
            if let o = oldByName[name] {
                if semanticallyEqual(o, n) {
                    unchanged += 1
                } else {
                    changed.append(.init(old: o, new: n))
                }
            } else {
                added.append(n)
            }
        }
        for (name, o) in oldByName.sorted(by: { $0.key < $1.key })
            where newByName[name] == nil
        {
            removed.append(o)
        }
    }

    /// Compare two bindings ignoring `index` and `source_line` —
    /// reordering / re-numbering must NOT show up in the diff or
    /// the user gets noise every time they insert a row above an
    /// existing binding.
    static func semanticallyEqual(_ a: WireBinding,
                                  _ b: WireBinding) -> Bool {
        return a.name == b.name
            && a.input == b.input
            && a.apps == b.apps
            && a.action == b.action
            && a.condition == b.condition
            && a.holdWhile == b.holdWhile
            && a.holdWhileTimeoutMs == b.holdWhileTimeoutMs
            && a.actionOnUp == b.actionOnUp
            && a.extraActions == b.extraActions
    }

    // MARK: - encoding

    /// Build a [Document] from a parse result.
    ///
    /// `validationStrict` controls whether the optional
    /// `validation` block is included (and computed under strict /
    /// lenient semantics). `nil` ⇒ block is omitted (the
    /// `--list --json` path); non-`nil` ⇒ block is populated using
    /// the same rules as `runValidate(strict:)` (the
    /// `--validate --json` path).
    public static func makeDocument(
        from result: Config.ParseResult,
        validationStrict: Bool? = nil,
        generatedAt: Date = Date()
    ) -> Document {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,
                                   .withFractionalSeconds]
        let opts = WireOptions(
            passthroughUnmatched: result.config.options.passthroughUnmatched,
            excludeApps: result.config.options.excludeApps,
            fnAutoArrows: result.config.options.fnAutoArrows)
        let bindings = result.config.bindings.enumerated().map { i, b in
            wire(binding: b, index: i)
        }
        let fallbacks = result.config.fallbacks.enumerated().map { i, b in
            wire(binding: b, index: i)
        }
        let dropped = result.warnings.compactMap(wireDropped(from:))
        let validation = validationStrict.map { strict in
            let undef = result.warnings.lazy
                .filter { $0.kind == .undefinedActionAlias }
                .count
            let ok = strict
                ? (result.warnings.isEmpty && result.droppedBindings == 0)
                : true
            return WireValidation(
                ok: ok,
                strict: strict,
                parsedCounts: WireParsedCounts(
                    bindings: result.config.bindings.count,
                    fallbacks: result.config.fallbacks.count,
                    actionAliases: result.config.actionAliases.count),
                droppedCount: result.droppedBindings,
                warningCount: result.warnings.count,
                undefinedActionAliases: undef)
        }
        return Document(
            schema: version,
            generatedAt: formatter.string(from: generatedAt),
            sourcePath: result.sourcePath,
            options: opts,
            actionAliases: result.config.actionAliases,
            inputAliases: result.config.inputAliases,
            bindings: bindings,
            fallbacks: fallbacks,
            dropped: dropped,
            validation: validation)
    }

    /// Encode a [Document] as pretty-printed JSON with sorted keys
    /// (stable for diffs / golden tests).
    public static func encodeJSON(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: - mappers

    private static func wire(binding b: Binding, index: Int) -> WireBinding {
        WireBinding(
            index: index,
            name: b.name,
            sourceLine: b.sourceLine,
            input: wireInput(b: b),
            apps: b.apps,
            action: wireAction(action: b.action,
                               raw: b.actionRaw,
                               aliasName: b.aliasName),
            condition: b.condition.map(wireCondition),
            holdWhile: b.holdWhile.map { modifierTokens($0) },
            holdWhileTimeoutMs: b.holdWhileTimeoutMs,
            actionOnUp: b.onUpAction.map {
                wireAction(action: $0, raw: nil, aliasName: nil)
            },
            extraActions: b.extraDownActions.isEmpty ? nil
                : b.extraDownActions.map {
                    wireAction(action: $0, raw: nil, aliasName: nil)
                },
            passthrough: b.passthrough ? true : nil)
    }

    private static func wireCondition(_ c: Condition) -> WireCondition {
        switch c {
        case .variable(let name, let equals):
            return WireCondition(kind: "variable",
                                 variable: name, equals: equals,
                                 conditions: nil)
        case .conjunction(let parts):
            return WireCondition(kind: "all",
                                 variable: nil, equals: nil,
                                 conditions: parts.map(wireCondition))
        }
    }

    private static func wireInput(b: Binding) -> WireInput {
        WireInput(
            raw: b.inputRaw,
            modifiers: modifierTokens(b.modifiers),
            modifierSides: modifierSides(b.modifiers),
            fn: b.modifiers.contains(.fn),
            trigger: wireTrigger(b.trigger))
    }

    /// All set modifier bits as canonical token strings, sorted for
    /// stable output. Both `ctrl` and `rctrl` appear when both bits
    /// are set on the binding.
    static func modifierTokens(_ m: Modifiers) -> [String] {
        var out: [String] = []
        if m.contains(.cmd)    { out.append("cmd") }
        if m.contains(.opt)    { out.append("opt") }
        if m.contains(.ctrl)   { out.append("ctrl") }
        if m.contains(.shift)  { out.append("shift") }
        if m.contains(.fn)     { out.append("fn") }
        if m.contains(.lcmd)   { out.append("lcmd") }
        if m.contains(.rcmd)   { out.append("rcmd") }
        if m.contains(.lopt)   { out.append("lopt") }
        if m.contains(.ropt)   { out.append("ropt") }
        if m.contains(.lctrl)  { out.append("lctrl") }
        if m.contains(.rctrl)  { out.append("rctrl") }
        if m.contains(.lshift) { out.append("lshift") }
        if m.contains(.rshift) { out.append("rshift") }
        return out.sorted()
    }

    /// Per-category side requirement: "absent" / "any" / "left" /
    /// "right" / "both". Matches the binding-constraint semantics
    /// described in [Modifiers.matches(event:)].
    static func modifierSides(_ m: Modifiers) -> ModifierSides {
        func side(any: Modifiers, l: Modifiers, r: Modifiers) -> String {
            let hasL = m.contains(l), hasR = m.contains(r)
            if hasL && hasR     { return "both" }
            if hasL             { return "left" }
            if hasR             { return "right" }
            if m.contains(any)  { return "any" }
            return "absent"
        }
        return ModifierSides(
            cmd:   side(any: .cmd,   l: .lcmd,   r: .rcmd),
            opt:   side(any: .opt,   l: .lopt,   r: .ropt),
            ctrl:  side(any: .ctrl,  l: .lctrl,  r: .rctrl),
            shift: side(any: .shift, l: .lshift, r: .rshift))
    }

    private static func wireTrigger(_ t: Trigger) -> WireTrigger {
        switch t {
        case .key(let code):
            return WireTrigger(kind: "key",
                               name: KeyCodes.name(forCode: code),
                               keycode: code)
        case .mouseButton(let btn):
            return WireTrigger(kind: "mouseButton",
                               name: mouseButtonName(btn),
                               keycode: nil)
        case .scroll(let dir):
            return WireTrigger(kind: "scroll",
                               name: dir.rawValue,
                               keycode: nil)
        case .anyKey:
            return WireTrigger(kind: "anyKey", name: nil, keycode: nil)
        }
    }

    private static func mouseButtonName(_ b: MouseButton) -> String {
        switch b {
        case .left:    return "left"
        case .right:   return "right"
        case .middle:  return "middle"
        case .side1:   return "side1"
        case .side2:   return "side2"
        case .other5:  return "other5"
        case .other6:  return "other6"
        case .other7:  return "other7"
        }
    }

    /// Map a [Action] → [WireAction]. Caller supplies `raw` /
    /// `aliasName` because they live on Binding (the primary path)
    /// or are absent (the `actionOnUp` path).
    private static func wireAction(action: Action,
                                   raw: String?,
                                   aliasName: String?) -> WireAction {
        switch action {
        case .keys(let mods, let code):
            return WireAction(
                kind: "keys",
                raw: raw,
                modifiers: modifierTokens(mods),
                key: WireKey(name: KeyCodes.name(forCode: code),
                             keycode: code),
                command: nil,
                alias: nil,
                variable: nil,
                value: nil)
        case .shell(let body):
            return WireAction(
                kind: "shell",
                raw: raw,
                modifiers: nil,
                key: nil,
                command: body,
                alias: aliasName,
                variable: nil,
                value: nil)
        case .noop:
            return WireAction(kind: "noop", raw: nil, modifiers: nil,
                              key: nil, command: nil, alias: nil,
                              variable: nil, value: nil)
        case .setVariable(let name, let v):
            return WireAction(
                kind: "set-variable",
                raw: raw,
                modifiers: nil,
                key: nil,
                command: nil,
                alias: nil,
                variable: name,
                value: v)
        case .toggleVariable(let name):
            return WireAction(
                kind: "toggle-variable",
                raw: raw,
                modifiers: nil,
                key: nil,
                command: nil,
                alias: nil,
                variable: name,
                value: nil)
        }
    }

    private static func wireDropped(from w: ConfigWarning) -> WireDropped? {
        // Non-binding warnings (e.g. `[options]` typos when we add
        // them) emit with section = "[options]" and name = nil.
        // For now the kind-to-section map is hand-coded; PR2.1
        // could carry the section explicitly on ConfigWarning.
        let section: String
        switch w.kind {
        case .configNotFound:
            // Surface as a global note, not a dropped binding —
            // skip in the dropped[] list.
            return nil
        case .actionAliasNonString:
            section = "[actionAliases]"
        case .inputAliasNonString,
             .inputAliasShadowsModifier,
             .inputAliasInvalidBody:
            section = "[input-aliases]"
        default:
            // missing-input / missing-action / unknown-input-token /
            // action-keys-parse-error / undefined-alias all come
            // from [[bindings]] or [[fallbacks]] paths. Inferring
            // which exactly requires extra metadata — for v1 we
            // emit "[[bindings]]" and let the consumer cross-
            // reference with sourceLine.
            section = "[[bindings]]"
        }
        return WireDropped(
            section: section,
            name: w.bindingName,
            sourceLine: w.sourceLine,
            kind: w.kind.rawValue,
            message: w.message)
    }
}
