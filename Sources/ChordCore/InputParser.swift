import Foundation

/// Parses the `input = "…"` and `action-keys = "…"` strings users
/// write in `config.toml` into [Trigger] + [Modifiers].
///
/// Grammar (whitespace tolerant):
///
///     INPUT      := MODIFIERS? PRIMARY
///     MODIFIERS  := MOD ('+' MOD)* '-'    // canonical: 'mod1 + mod2 - key'
///                 | MOD ('+' MOD)*        // pure modifier+primary works too
///     MOD        := 'cmd' | 'opt' | 'alt' | 'ctrl' | 'shift' | 'fn' | 'hyper'
///     PRIMARY    := KEY_NAME | 'mouse.' MOUSE_BTN | 'scroll.' SCROLL_DIR
///     MOUSE_BTN  := 'left' | 'right' | 'middle' | 'side1' | 'side2' | UInt
///     SCROLL_DIR := 'up' | 'down' | 'left' | 'right'
///
/// `hyper` expands to cmd+opt+ctrl+shift. `alt` is an alias for
/// `opt`. Unknown tokens raise [InputParseError] with a useful
/// `context` for `chord config --validate`.
public enum InputParser {
    public struct Parsed: Equatable {
        public let modifiers: Modifiers
        public let trigger: Trigger
    }

    public enum InputParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unknownToken(String, context: String)
        case missingPrimary(context: String)
        /// A `$name` reference resolved to no entry in `[input-aliases]`.
        /// Separate from `unknownToken` because the failure mode is
        /// distinct: the user *intended* an alias (the `$` prefix is
        /// the explicit signal), they just typoed the name or forgot
        /// to declare it.
        case undefinedInputAlias(String, context: String)

        public var description: String {
            switch self {
            case .empty:
                return "empty input string"
            case .unknownToken(let t, let ctx):
                return "unknown token '\(t)' in \"\(ctx)\""
            case .missingPrimary(let ctx):
                return "no key / mouse / scroll token in \"\(ctx)\""
            case .undefinedInputAlias(let name, let ctx):
                return
                    "undefined input-alias '$\(name)' in \"\(ctx)\" " +
                    "— declare it in [input-aliases] or fix the typo"
            }
        }
    }

    public static func parse(_ raw: String,
                             allowWildcard: Bool = false,
                             allowModifiersOnly: Bool = false,
                             inputAliases: [String: Modifiers] = [:],
                             vkeyAliases: [String: UInt8] = [:])
        throws -> Parsed
    {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw InputParseError.empty }

        // Vendor-HID v-key trigger. A v-key alias is a COMPLETE trigger
        // (like a custom key name — no `$` sigil, parallel to `f13`), so
        // it is resolved BEFORE the keycode fast-path below: a declared
        // v-key alias can never be silently re-read as a literal key.
        // The bare `v-key` / `vkey` literal is the any-vkey wildcard
        // (`[[fallbacks]]` only) — the vendor-HID counterpart of `*`.
        let lowered = trimmed.lowercased()
        if lowered == "v-key" || lowered == "vkey" {
            guard allowWildcard else {
                throw InputParseError.unknownToken(
                    "v-key (any-vkey wildcard only allowed in [[fallbacks]])",
                    context: raw)
            }
            return Parsed(modifiers: [], trigger: .anyVKey)
        }
        if let id = vkeyAliases[lowered] {
            return Parsed(modifiers: [], trigger: .vkey(id))
        }

        // Fast path: the whole string is a valid primary token
        // (e.g. `f13`, `mouse.side1`, `keycode-200`, `*`). Treat as
        // no-modifier binding. This is what disambiguates
        // `keycode-200` from a `keycode - 200` split that would
        // mistake the prefix for a modifier — `-` is overloaded as
        // both a separator and an in-token character.
        if let trigger = try? parsePrimary(trimmed,
                                           context: raw,
                                           allowWildcard: allowWildcard)
        {
            return Parsed(modifiers: [], trigger: trigger)
        }

        // chord 0.9.0+ modifier-only input: the whole string parses
        // as a non-empty modifier mask (no primary key). Caller opts
        // in via `allowModifiersOnly: true` — falls through to the
        // legacy "missing primary" error path otherwise.
        if allowModifiersOnly {
            if let mods = try? parseModifiers(trimmed, context: raw,
                                              inputAliases: inputAliases),
               mods.rawValue != 0
            {
                return Parsed(modifiers: mods, trigger: .modifiersOnly)
            }
        }

        // Otherwise, look for a modifier/primary separator. Split
        // on the first `-` (canonical form separates modifier
        // chain from the primary key). If absent, treat the whole
        // thing as a `+`-joined chain whose last segment is the
        // primary.
        let modPart: String
        let primaryPart: String
        if let dash = trimmed.firstIndex(of: "-") {
            modPart = String(trimmed[..<dash])
                .trimmingCharacters(in: .whitespaces)
            primaryPart = String(trimmed[trimmed.index(after: dash)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            let segs = trimmed.split(separator: "+").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let last = segs.last, !last.isEmpty else {
                throw InputParseError.missingPrimary(context: raw)
            }
            modPart = segs.dropLast().joined(separator: "+")
            primaryPart = last
        }

        let mods = try parseModifiers(modPart, context: raw,
                                      inputAliases: inputAliases)
        let trigger = try parsePrimary(primaryPart, context: raw,
                                       allowWildcard: allowWildcard)
        return Parsed(modifiers: mods, trigger: trigger)
    }

    /// Built-in modifier tokens (lowercased, including the common
    /// spellings: `cmd`/`command`/`⌘`/`alt`/`opt` etc). Used by
    /// `Config` to reject `[input-aliases]` names that would shadow a
    /// real modifier. Lookup is case-insensitive: callers should
    /// `.lowercased()` before checking.
    public static let reservedModifierTokens: Set<String> = [
        "cmd", "⌘", "command",
        "opt", "⌥", "alt", "option",
        "ctrl", "⌃", "control",
        "shift", "⇧",
        "fn", "hyper",
        "lcmd",   "lcommand",
        "rcmd",   "rcommand",
        "lopt",   "lalt", "loption",
        "ropt",   "ralt", "roption",
        "lctrl",  "lcontrol",
        "rctrl",  "rcontrol",
        "lshift",
        "rshift",
    ]

    /// Parse a modifier-only chain like `"cmd + opt"` or
    /// `"hyper"`. Used by v2's `hold-while` and v0.8.0's
    /// `[[remap]] modifiers = …` field — the modifier mask the
    /// downstream caller composes with a key into a binding.
    /// An empty string returns the empty mask (no modifiers).
    ///
    /// `inputAliases` mirrors the map passed to [parse]; pass it when
    /// `$alias` references are legal at this call site
    /// (e.g. `modifiers = "$ULTRA_LL"` in `[[remap]]`).
    public static func parseModifiersOnly(
        _ raw: String,
        inputAliases: [String: Modifiers] = [:]
    ) throws -> Modifiers {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        // The internal modifier parser splits on `+`. Strip a trailing
        // `-` if present (lets users write `"cmd + opt -"` or
        // `"cmd + opt"` interchangeably — same dash convention as the
        // primary-key form).
        let body = trimmed.hasSuffix("-")
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            : trimmed
        return try parseModifiers(body, context: raw,
                                  inputAliases: inputAliases)
    }

    /// Subset of `parse` that returns the keys form only (for
    /// `action-keys`, which by construction is a key, not a
    /// mouse). Throws if the parsed trigger is not `.key`.
    public static func parseKeyForOutput(_ raw: String) throws
        -> (Modifiers, UInt16)
    {
        let p = try parse(raw)
        guard case .key(let kc) = p.trigger else {
            throw InputParseError.unknownToken(
                "mouse/scroll not allowed in action-keys",
                context: raw)
        }
        return (p.modifiers, kc)
    }

    private static func parseModifiers(_ raw: String, context: String,
                                       inputAliases: [String: Modifiers] = [:])
        throws -> Modifiers
    {
        guard !raw.isEmpty else { return [] }
        var out: Modifiers = []
        for tok in raw.split(separator: "+") {
            let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "":             continue

            // Any-side modifiers (most common).
            case "cmd", "⌘", "command":         out.insert(.cmd)
            case "opt", "⌥", "alt", "option":   out.insert(.opt)
            case "ctrl", "⌃", "control":        out.insert(.ctrl)
            case "shift", "⇧":                  out.insert(.shift)
            case "fn":                          out.insert(.fn)
            case "hyper":                       out.formUnion(.hyper)

            // Side-specific modifiers (ZMK ULTRA_LL / MEGA_RM-style
            // patterns). `r*` = strict right (left must be absent),
            // `l*` = strict left (right must be absent). Use the
            // any-side spelling above unless side actually matters.
            case "lcmd",   "lcommand":          out.insert(.lcmd)
            case "rcmd",   "rcommand":          out.insert(.rcmd)
            case "lopt",   "lalt", "loption":   out.insert(.lopt)
            case "ropt",   "ralt", "roption":   out.insert(.ropt)
            case "lctrl",  "lcontrol":          out.insert(.lctrl)
            case "rctrl",  "rcontrol":          out.insert(.rctrl)
            case "lshift":                      out.insert(.lshift)
            case "rshift":                      out.insert(.rshift)

            default:
                // `$name` reference into [input-aliases]. The `$`
                // prefix is the *explicit* signal that the token is
                // a user-defined modifier-set alias — parallels the
                // `@name` syntax used for shell-action `[actionAliases]`
                // resolution. Without a prefix the token must be a
                // built-in modifier (the cases above); bare alias
                // references are not supported. The map's bodies are
                // pre-validated at load time (Config.swift), so a hit
                // here guarantees a valid mask.
                if t.hasPrefix("$") {
                    let aliasName = String(t.dropFirst())
                    if let aliased = inputAliases[aliasName] {
                        out.formUnion(aliased)
                    } else {
                        throw InputParseError.undefinedInputAlias(
                            aliasName, context: context)
                    }
                } else {
                    throw InputParseError.unknownToken(t, context: context)
                }
            }
        }
        return out
    }

    private static func parsePrimary(_ raw: String, context: String,
                                     allowWildcard: Bool = false)
        throws -> Trigger
    {
        let t = raw.lowercased()
        if t == "*" {
            // `*` is the wildcard primary key — only legal inside a
            // `[[fallbacks]]` row. Allowing it in `[[bindings]]`
            // would let a single rule swallow every key, which is
            // explicitly the surface area `[[fallbacks]]` exists
            // to keep separated.
            guard allowWildcard else {
                throw InputParseError.unknownToken(
                    "* (wildcard only allowed in [[fallbacks]])",
                    context: context)
            }
            return .anyKey
        }
        if t.hasPrefix("mouse.") {
            let name = String(t.dropFirst("mouse.".count))
            switch name {
            case "left":   return .mouseButton(.left)
            case "right":  return .mouseButton(.right)
            case "middle": return .mouseButton(.middle)
            case "side1", "back":    return .mouseButton(.side1)
            case "side2", "forward": return .mouseButton(.side2)
            default:
                if let n = Int(name), let mb = MouseButton(rawValue: n) {
                    return .mouseButton(mb)
                }
                throw InputParseError.unknownToken(
                    "mouse.\(name)", context: context)
            }
        }
        if t.hasPrefix("scroll.") {
            let name = String(t.dropFirst("scroll.".count))
            if let dir = ScrollDirection(rawValue: name) {
                return .scroll(dir)
            }
            throw InputParseError.unknownToken(
                "scroll.\(name)", context: context)
        }
        if let kc = KeyCodes.code(forName: t) {
            return .key(kc)
        }
        throw InputParseError.unknownToken(t, context: context)
    }
}
