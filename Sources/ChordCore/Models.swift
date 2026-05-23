import Foundation

/// The domain model. Pure value types, intentionally free of any
/// AppKit / CoreGraphics / IOKit dependency — Core stays portable
/// and unit-testable.

public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let cmd   = Modifiers(rawValue: 1 << 0)
    public static let opt   = Modifiers(rawValue: 1 << 1)
    public static let ctrl  = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
    public static let fn    = Modifiers(rawValue: 1 << 4)

    /// `hyper` is the colloquial name for cmd+ctrl+opt+shift — the
    /// "no-one ever uses this combination" modifier popularised by
    /// Karabiner-Elements. Treated as a sugar over the four flags
    /// when parsing config, never as a fifth bit.
    public static let hyper: Modifiers = [.cmd, .opt, .ctrl, .shift]
}

/// What started the chord. Either a physical key (identified by its
/// CGKeyCode-equivalent UInt16) or a mouse input (button or scroll
/// direction). String names parse to / from this in
/// [InputParser](InputParser.swift).
public enum Trigger: Hashable, Sendable {
    case key(UInt16)
    case mouseButton(MouseButton)
    case scroll(ScrollDirection)
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
public struct Binding: Hashable, Sendable {
    public var name: String
    public var trigger: Trigger
    public var modifiers: Modifiers
    /// Bundle-id glob patterns. `nil` = match everywhere.
    /// `["*"]` is treated identically to `nil`.
    /// Exclusion via `!com.example`; any exclusion wins.
    public var apps: [String]?
    public var action: Action

    public init(name: String, trigger: Trigger, modifiers: Modifiers,
                apps: [String]?, action: Action) {
        self.name = name
        self.trigger = trigger
        self.modifiers = modifiers
        self.apps = apps
        self.action = action
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

    public init(options: Options = .init(), bindings: [Binding] = []) {
        self.options = options
        self.bindings = bindings
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
