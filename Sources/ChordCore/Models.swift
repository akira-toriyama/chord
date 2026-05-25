import Foundation

/// The domain model. Pure value types, intentionally free of any
/// AppKit / CoreGraphics / IOKit dependency — Core stays portable
/// and unit-testable.

public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    // "Any side" modifiers — match either the left or right physical
    // key. Used by the legacy `cmd` / `opt` / `ctrl` / `shift` tokens
    // and by every event when the binding does not care about the
    // side (the common case).
    public static let cmd   = Modifiers(rawValue: 1 << 0)
    public static let opt   = Modifiers(rawValue: 1 << 1)
    public static let ctrl  = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
    public static let fn    = Modifiers(rawValue: 1 << 4)

    // Side-specific modifiers. Required to express ZMK-style
    // `ULTRA_LL = rctrl + ralt + rshift` patterns, where the
    // strict-right semantics carry the design intent. A binding
    // that sets, say, `.rctrl` matches when the right Control key
    // is held AND the left one is NOT. A binding that sets both
    // `.lctrl` and `.rctrl` matches when both are held.
    public static let lcmd   = Modifiers(rawValue: 1 << 5)
    public static let rcmd   = Modifiers(rawValue: 1 << 6)
    public static let lopt   = Modifiers(rawValue: 1 << 7)
    public static let ropt   = Modifiers(rawValue: 1 << 8)
    public static let lctrl  = Modifiers(rawValue: 1 << 9)
    public static let rctrl  = Modifiers(rawValue: 1 << 10)
    public static let lshift = Modifiers(rawValue: 1 << 11)
    public static let rshift = Modifiers(rawValue: 1 << 12)

    /// `hyper` is the colloquial name for cmd+ctrl+opt+shift — the
    /// "no-one ever uses this combination" modifier popularised by
    /// Karabiner-Elements. Treated as a sugar over the four
    /// any-side flags when parsing config, never as a separate bit.
    public static let hyper: Modifiers = [.cmd, .opt, .ctrl, .shift]

    /// Does this BINDING constraint accept the given EVENT modifier
    /// set? `event` carries only side-specific bits (lcmd / rcmd /
    /// etc.) plus `fn` — those are what the tap actually observes.
    ///
    /// Per-category logic:
    ///   • Both `.lX` and `.rX` set on the binding  → both sides
    ///     must be held on the event.
    ///   • Only `.lX` set                          → left held,
    ///                                                right absent.
    ///   • Only `.rX` set                          → right held,
    ///                                                left absent.
    ///   • Only `.X` (any-side) set                → at least one
    ///                                                side held.
    ///   • Neither set                             → both sides
    ///                                                must be absent.
    ///
    /// `fn` is symmetric (no L/R variants) and matches strictly.
    public func matches(event: Modifiers) -> Bool {
        return matchCategory(any: .cmd,   l: .lcmd,   r: .rcmd,   event: event)
            && matchCategory(any: .opt,   l: .lopt,   r: .ropt,   event: event)
            && matchCategory(any: .ctrl,  l: .lctrl,  r: .rctrl,  event: event)
            && matchCategory(any: .shift, l: .lshift, r: .rshift, event: event)
            && self.contains(.fn) == event.contains(.fn)
    }

    private func matchCategory(any: Modifiers, l: Modifiers, r: Modifiers,
                               event: Modifiers) -> Bool {
        let eL = event.contains(l)
        let eR = event.contains(r)
        let bAny = self.contains(any)
        let bL = self.contains(l)
        let bR = self.contains(r)
        if bL && bR { return eL && eR }
        if bL       { return eL && !eR }
        if bR       { return eR && !eL }
        if bAny     { return eL || eR }
        return !eL && !eR
    }
}

/// What started the chord. Either a physical key (identified by its
/// CGKeyCode-equivalent UInt16) or a mouse input (button or scroll
/// direction). String names parse to / from this in
/// [InputParser](InputParser.swift).
///
/// `.anyKey` is the wildcard trigger used by `[[fallbacks]]` rows:
/// it matches every keyboard keyDown event whose modifier mask
/// satisfies the binding constraint. By contract, the parser only
/// produces `.anyKey` when called from the fallback-parsing path —
/// using `*` inside a regular `[[bindings]]` row is rejected, so
/// `[[bindings]]` can never accidentally swallow every key.
public enum Trigger: Hashable, Sendable {
    case key(UInt16)
    case mouseButton(MouseButton)
    case scroll(ScrollDirection)
    case anyKey
}

public enum MouseButton: Int, Hashable, Sendable, Codable {
    case left = 0
    case right = 1
    case middle = 2
    case side1 = 3       // commonly the "back" button
    case side2 = 4       // commonly the "forward" button
    case other5 = 5
    case other6 = 6
    case other7 = 7
}

public enum ScrollDirection: String, Hashable, Sendable, Codable {
    case up, down, left, right
}

/// What chord does when a binding matches.
public enum Action: Hashable, Sendable {
    /// Post a synthetic key event. `keys` is the key + modifiers to
    /// emit; the original event is swallowed so the user does not
    /// see both.
    case keys(Modifiers, UInt16)
    /// Run a shell command. The command inherits chord's env plus a
    /// few `CHORD_*` variables describing the triggering event.
    case shell(String)
    /// Absorb the input and do nothing. Useful for disabling a key
    /// inside a specific app.
    case noop
}

/// One binding: trigger + modifiers + optional app scope → action.
///
/// Carries `inputRaw` / `actionRaw` / `aliasName` / `sourceLine`
/// metadata alongside the runtime fields. The matcher ignores
/// them; the `chord --list --json` serialiser
/// ([Schema.swift](Schema.swift)) needs them to round-trip a config
/// faithfully (preserve user-typed strings, attribute warnings to
/// source lines, surface alias usage).
public struct Binding: Hashable, Sendable {
    public var name: String
    public var trigger: Trigger
    public var modifiers: Modifiers
    /// Bundle-id glob patterns. `nil` = match everywhere.
    /// `["*"]` is treated identically to `nil`.
    /// Exclusion via `!com.example`; any exclusion wins.
    public var apps: [String]?
    public var action: Action

    // — metadata (read by Schema.swift, not by Matcher) —

    /// Original `input = "..."` string as the user wrote it. Kept
    /// verbatim so the JSON form can expose `input.raw` for human
    /// display and so `--list` text output mirrors the file.
    public var inputRaw: String
    /// Original `action-shell = "..."` / `action-keys = "..."`
    /// string. `nil` for `action-noop`.
    public var actionRaw: String?
    /// When the user wrote `action-shell = "@name"`, this is `name`
    /// (without the `@`) and `action` holds the resolved body. `nil`
    /// when no alias was used.
    public var aliasName: String?
    /// 1-based line of the row's `[[bindings]]` / `[[fallbacks]]`
    /// header in the source config, when the TOML parser tracked
    /// it. `nil` if unavailable.
    public var sourceLine: Int?

    public init(name: String, trigger: Trigger, modifiers: Modifiers,
                apps: [String]?, action: Action,
                inputRaw: String = "",
                actionRaw: String? = nil,
                aliasName: String? = nil,
                sourceLine: Int? = nil) {
        self.name = name
        self.trigger = trigger
        self.modifiers = modifiers
        self.apps = apps
        self.action = action
        self.inputRaw = inputRaw
        self.actionRaw = actionRaw
        self.aliasName = aliasName
        self.sourceLine = sourceLine
    }
}

/// Whole-program configuration. The TOML file lands here.
public struct ChordConfig: Sendable {
    public struct Options: Sendable {
        public var passthroughUnmatched: Bool
        public var excludeApps: [String]

        public init(passthroughUnmatched: Bool = true,
                    excludeApps: [String] = []) {
            self.passthroughUnmatched = passthroughUnmatched
            self.excludeApps = excludeApps
        }
    }

    public var options: Options
    public var bindings: [Binding]
    /// Document-ordered fallbacks evaluated AFTER every `[[bindings]]`
    /// row misses. Same shape as a binding, but the trigger may be
    /// `.anyKey` (the `*` wildcard). Intended for "play a sound
    /// when ULTRA_LL fires on an undefined key"-style feedback.
    public var fallbacks: [Binding]
    /// Named shell-command snippets. A binding whose `action-shell`
    /// is the single token `@name` resolves to the body string here.
    /// Lookup is simple (no recursion, no argument passing — `@name
    /// arg` syntax is reserved for a future expansion).
    public var aliases: [String: String]

    public init(options: Options = .init(),
                bindings: [Binding] = [],
                fallbacks: [Binding] = [],
                aliases: [String: String] = [:]) {
        self.options = options
        self.bindings = bindings
        self.fallbacks = fallbacks
        self.aliases = aliases
    }

    /// Conventional config path: `$XDG_CONFIG_HOME/chord/config.toml`
    /// or `~/.config/chord/config.toml`.
    public static var path: String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() + "/.config")
        return base + "/chord/config.toml"
    }
}
