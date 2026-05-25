import Foundation

/// Wire format for `chord --list --json` / `chord --validate --json`,
/// versioned `chord.bindings.v1`. The JSON Schema published at
/// `docs/schema/chord.bindings.v1.json` is the canonical contract;
/// every field in this file is mirrored there.
///
/// Design choices (locked for v1):
///
/// * **Modifier side encoded per-category** (`modifier_sides:
///   {"ctrl": "right"}`), not as a flat array mixing `ctrl` and
///   `rctrl`. capsule-corp's Q1-2: consuming-side code stays clean
///   when "logical modifier" and "physical side" are orthogonal.
/// * **`apps: null` vs `apps: []`** — `null` means "any app" (the
///   user didn't write `apps`); `[]` means "explicitly empty list".
///   The TOML parser folds `["*"]` to `null`.
/// * **`dropped[].kind`** is a stable string drawn from
///   [ConfigWarning.Kind] so machine consumers can branch without
///   grepping the message.
/// * **`generated_at`** is ISO-8601 UTC with fractional seconds.
///   Consumers should treat it as informational only — not a stable
///   sort key.
public enum BindingsSchema {

    public static let version = "chord.bindings.v1"

    /// Top-level wire document.
    public struct Document: Codable, Sendable {
        public let schema: String
        public let generatedAt: String
        public let sourcePath: String?
        public let options: WireOptions
        public let aliases: [String: String]
        public let bindings: [WireBinding]
        public let fallbacks: [WireBinding]
        public let dropped: [WireDropped]

        enum CodingKeys: String, CodingKey {
            case schema, options, aliases, bindings, fallbacks, dropped
            case generatedAt = "generated_at"
            case sourcePath  = "source_path"
        }
    }

    public struct WireOptions: Codable, Sendable {
        public let passthroughUnmatched: Bool
        public let excludeApps: [String]

        enum CodingKeys: String, CodingKey {
            case passthroughUnmatched = "passthrough_unmatched"
            case excludeApps          = "exclude_apps"
        }
    }

    public struct WireBinding: Codable, Sendable {
        public let index: Int
        public let name: String
        public let sourceLine: Int?
        public let input: WireInput
        public let apps: [String]?
        public let action: WireAction

        enum CodingKeys: String, CodingKey {
            case index, name, input, apps, action
            case sourceLine = "source_line"
        }
    }

    public struct WireInput: Codable, Sendable {
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

    public struct ModifierSides: Codable, Sendable {
        public let cmd: String
        public let opt: String
        public let ctrl: String
        public let shift: String
    }

    public struct WireTrigger: Codable, Sendable {
        /// `"key"` | `"mouseButton"` | `"scroll"` | `"anyKey"`.
        public let kind: String
        public let name: String?
        public let keycode: UInt16?
    }

    public struct WireAction: Codable, Sendable {
        /// `"keys"` | `"shell"` | `"noop"`.
        public let kind: String
        /// `action-shell` / `action-keys` original user string.
        /// `nil` for `noop`.
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
    }

    public struct WireKey: Codable, Sendable {
        public let name: String
        public let keycode: UInt16
    }

    public struct WireDropped: Codable, Sendable {
        /// `"[[bindings]]"` | `"[[fallbacks]]"` | `"[aliases]"` —
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

    // MARK: - encoding

    /// Build a [Document] from a parse result.
    public static func makeDocument(
        from result: Config.ParseResult,
        generatedAt: Date = Date()
    ) -> Document {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,
                                   .withFractionalSeconds]
        let opts = WireOptions(
            passthroughUnmatched: result.config.options.passthroughUnmatched,
            excludeApps: result.config.options.excludeApps)
        let bindings = result.config.bindings.enumerated().map { i, b in
            wire(binding: b, index: i)
        }
        let fallbacks = result.config.fallbacks.enumerated().map { i, b in
            wire(binding: b, index: i)
        }
        let dropped = result.warnings.compactMap(wireDropped(from:))
        return Document(
            schema: version,
            generatedAt: formatter.string(from: generatedAt),
            sourcePath: result.sourcePath,
            options: opts,
            aliases: result.config.aliases,
            bindings: bindings,
            fallbacks: fallbacks,
            dropped: dropped)
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
            action: wireAction(b: b))
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

    private static func wireAction(b: Binding) -> WireAction {
        switch b.action {
        case .keys(let mods, let code):
            return WireAction(
                kind: "keys",
                raw: b.actionRaw,
                modifiers: modifierTokens(mods),
                key: WireKey(name: KeyCodes.name(forCode: code),
                             keycode: code),
                command: nil,
                alias: nil)
        case .shell(let body):
            return WireAction(
                kind: "shell",
                raw: b.actionRaw,
                modifiers: nil,
                key: nil,
                command: body,
                alias: b.aliasName)
        case .noop:
            return WireAction(kind: "noop", raw: nil, modifiers: nil,
                              key: nil, command: nil, alias: nil)
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
        case .aliasNonString:
            section = "[aliases]"
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
