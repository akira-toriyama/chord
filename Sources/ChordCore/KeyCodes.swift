import Foundation

/// Mapping from human key names to CGKeyCode-equivalent UInt16
/// values, and back. Lives in Core because it's pure data — the
/// adapter feeds raw UInt16 keycodes from CGEventTap and Core
/// decides what they mean.
///
/// Sources:
///   • Carbon `HIToolbox/Events.h` — `kVK_*` constants for
///     standard keys and F1–F20.
///   • Apple has never published `kVK_F21` … `kVK_F24` — the
///     hardware (custom keyboards, ZSA Moonlander, Karabiner)
///     ships these as HID usages 0x70–0x73, which IOHIDSystem
///     translates to the unassigned virtual-keycode slots below.
///     The numbers used here are the ones Karabiner-Elements
///     emits for the same HID usages, which is the de-facto
///     convention on macOS today.
public enum KeyCodes {
    /// Look up by name (case-insensitive). Accepts both human names
    /// (`"return"`, `"f13"`, `"arrow_left"`) and the explicit
    /// `"keycode-NNN"` escape hatch for anything not listed.
    public static func code(forName raw: String) -> UInt16? {
        let n = raw.lowercased()
        if n.hasPrefix("keycode-") {
            return UInt16(n.dropFirst("keycode-".count))
        }
        return table[n]
    }

    /// Reverse lookup. Returns the canonical name for a keycode, or
    /// `keycode-NNN` if unknown.
    public static func name(forCode code: UInt16) -> String {
        if let n = reverse[code] { return n }
        return "keycode-\(code)"
    }

    /// Keycodes for arrow keys and the nav cluster that macOS
    /// **always** decorates with `NSEventModifierFlagFunction`
    /// regardless of whether the user is physically holding `fn`.
    /// Matcher uses this set to apply `Options.fnAutoArrows` —
    /// when the option is on (default), the strict `fn` comparison
    /// is skipped for these keys so users don't have to write
    /// `ctrl + fn - right` in place of the natural `ctrl - right`.
    public static let fnAutoNavKeycodes: Set<UInt16> = [
        0x7B, 0x7C, 0x7D, 0x7E,   // arrow_left, arrow_right, arrow_down, arrow_up
        0x73, 0x77,               // home, end
        0x74, 0x79,               // page_up, page_down
        0x75,                     // forward_delete (fn+delete on laptops)
    ]

    /// `true` when the trigger is one of the keys macOS always
    /// tags with `fn` (arrow / nav cluster). Returns `false` for
    /// mouse / scroll / wildcard / non-nav keys.
    public static func isFnAutoNav(_ trigger: Trigger) -> Bool {
        guard case .key(let kc) = trigger else { return false }
        return fnAutoNavKeycodes.contains(kc)
    }

    private static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            // Letters (US ANSI; physical-position keycodes).
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
            "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
            "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
            "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "-": 0x1B, "minus": 0x1B,
            "8": 0x1C, "0": 0x1D, "]": 0x1E, "rbracket": 0x1E,
            "o": 0x1F, "u": 0x20, "[": 0x21, "lbracket": 0x21,
            "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
            "'": 0x27, "quote": 0x27, "k": 0x28, ";": 0x29,
            "semicolon": 0x29, "\\": 0x2A, "backslash": 0x2A,
            ",": 0x2B, "comma": 0x2B, "/": 0x2C, "slash": 0x2C,
            "n": 0x2D, "m": 0x2E, ".": 0x2F, "period": 0x2F,
            "`": 0x32, "grave": 0x32,

            // Control / whitespace.
            "return": 0x24, "enter": 0x24, "tab": 0x30,
            "space": 0x31, "delete": 0x33, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35,

            // Arrows + nav cluster.
            "arrow_left":  0x7B, "left":  0x7B,
            "arrow_right": 0x7C, "right": 0x7C,
            "arrow_down":  0x7D, "down":  0x7D,
            "arrow_up":    0x7E, "up":    0x7E,
            "home": 0x73, "end": 0x77, "page_up": 0x74,
            "pageup": 0x74, "page_down": 0x79, "pagedown": 0x79,
            "forward_delete": 0x75, "fwd_delete": 0x75, "del": 0x75,
            "help": 0x72,

            // F-row (F1–F20 use Apple's documented kVK_* constants).
            "f1":  0x7A, "f2":  0x78, "f3":  0x63, "f4":  0x76,
            "f5":  0x60, "f6":  0x61, "f7":  0x62, "f8":  0x64,
            "f9":  0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
            "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A,
            "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,

            // F21–F24 are unassigned in Carbon. Karabiner / firmware-
            // remapping is the only way they reach an event tap;
            // these are the slots that convention uses.
            "f21": 0x68, "f22": 0x6E, "f23": 0x66, "f24": 0x6C,

            // Keypad cluster (numpad).
            "kp_decimal": 0x41, "kp_multiply": 0x43, "kp_plus": 0x45,
            "kp_clear": 0x47, "kp_divide": 0x4B, "kp_enter": 0x4C,
            "kp_minus": 0x4E, "kp_equal": 0x51, "kp_0": 0x52,
            "kp_1": 0x53, "kp_2": 0x54, "kp_3": 0x55, "kp_4": 0x56,
            "kp_5": 0x57, "kp_6": 0x58, "kp_7": 0x59, "kp_8": 0x5B,
            "kp_9": 0x5C,
        ]
        // International / multimedia keys appear on some hardware
        // via these slots; expose them by both human aliases.
        t["section"]      = 0x0A
        t["caps_lock"]    = 0x39
        t["mute"]         = 0x4A
        t["volume_up"]    = 0x48
        t["volume_down"]  = 0x49
        return t
    }()

    private static let reverse: [UInt16: String] = {
        var r: [UInt16: String] = [:]
        // Prefer the descriptive name when several aliases map to
        // the same code (e.g. "return" over "enter", "f13" over
        // anything custom).
        let preferred: Set<String> = [
            "return", "tab", "space", "delete", "escape",
            "arrow_left", "arrow_right", "arrow_up", "arrow_down",
            "home", "end", "page_up", "page_down", "forward_delete",
            "help", "equal", "minus", "lbracket", "rbracket",
            "quote", "semicolon", "backslash", "comma", "slash",
            "period", "grave", "section", "caps_lock",
            "mute", "volume_up", "volume_down",
        ]
        // F1–F24 stay as f1…f24, and a–z, 0–9 stay literal.
        for (name, code) in table {
            if r[code] == nil {
                r[code] = name
                continue
            }
            // Disambiguate aliases.
            let existing = r[code]!
            if preferred.contains(name) && !preferred.contains(existing) {
                r[code] = name
            } else if name.hasPrefix("f"),
                      name.dropFirst().allSatisfy(\.isNumber) {
                r[code] = name
            }
        }
        return r
    }()
}
