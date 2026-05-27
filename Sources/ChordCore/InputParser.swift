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
/// `context` for `chord --validate`.
public enum InputParser {
    public struct Parsed: Equatable {
        public let modifiers: Modifiers
        public let trigger: Trigger
    }

    public enum InputParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unknownToken(String, context: String)
        case missingPrimary(context: String)

        public var description: String {
            switch self {
            case .empty:
                return "empty input string"
            case .unknownToken(let t, let ctx):
                return "unknown token '\(t)' in \"\(ctx)\""
            case .missingPrimary(let ctx):
                return "no key / mouse / scroll token in \"\(ctx)\""
            }
        }
    }

    public static func parse(_ raw: String,
                             allowWildcard: Bool = false) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw InputParseError.empty }

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

        let mods = try parseModifiers(modPart, context: raw)
        let trigger = try parsePrimary(primaryPart, context: raw,
                                       allowWildcard: allowWildcard)
        return Parsed(modifiers: mods, trigger: trigger)
    }

    /// Parse a modifier-only chain like `"cmd + opt"` or
    /// `"hyper"`. Used by v2's `hold-while` field — the modifier mask
    /// that ties a variable's lifecycle to a held-down mod set. An
    /// empty string returns the empty mask (no auto-clear).
    public static func parseModifiersOnly(_ raw: String) throws -> Modifiers {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        // The internal modifier parser splits on `+`. Strip a trailing
        // `-` if present (lets users write `"cmd + opt -"` or
        // `"cmd + opt"` interchangeably — same dash convention as the
        // primary-key form).
        let body = trimmed.hasSuffix("-")
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            : trimmed
        return try parseModifiers(body, context: raw)
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

    private static func parseModifiers(_ raw: String, context: String)
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
                throw InputParseError.unknownToken(t, context: context)
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
