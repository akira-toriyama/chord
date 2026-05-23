import Foundation

/// Looks up the binding that fires for a given input event.
///
/// Match order is the document order of `[[bindings]]` in
/// `config.toml`. The first binding whose
/// `(trigger, modifiers, apps)` all match wins.
///
/// `apps` semantics (same as stroke):
///   • nil or `["*"]` ⇒ match any frontmost app
///   • plain entries (`"com.apple.Safari"`, `"*chrome*"`) form an
///     allowlist; one match is enough
///   • exclusion entries (`"!com.apple.dt.Xcode"`) win over any
///     allowlist hit when the bundle id matches
public struct Matcher: Sendable {
    public let bindings: [Binding]
    public let excludeApps: [String]

    public init(bindings: [Binding], excludeApps: [String] = []) {
        self.bindings = bindings
        self.excludeApps = excludeApps
    }

    public struct Event: Hashable, Sendable {
        public var trigger: Trigger
        public var modifiers: Modifiers
        public var bundleID: String?

        public init(trigger: Trigger, modifiers: Modifiers,
                    bundleID: String?) {
            self.trigger = trigger
            self.modifiers = modifiers
            self.bundleID = bundleID
        }
    }

    public func find(_ event: Event) -> Binding? {
        if let id = event.bundleID,
           Matcher.matchesGlobs(id, patterns: excludeApps) {
            return nil
        }
        for b in bindings {
            guard b.trigger == event.trigger else { continue }
            guard b.modifiers == event.modifiers else { continue }
            if let apps = b.apps {
                guard let id = event.bundleID else { continue }
                if !Matcher.appsAllow(id, patterns: apps) { continue }
            }
            return b
        }
        return nil
    }

    // MARK: - glob matching

    /// `["*"]` is treated as "any" by the caller (apps == nil); this
    /// function handles the mixed allow/deny list otherwise. One
    /// exclusion match wins over any allowlist match.
    static func appsAllow(_ id: String, patterns: [String]) -> Bool {
        var anyExcl = false
        var anyAllow = false
        var matched = false
        for raw in patterns {
            if raw.hasPrefix("!") {
                anyExcl = true
                let p = String(raw.dropFirst())
                if globMatch(id, pattern: p) { return false }
            } else {
                anyAllow = true
                if globMatch(id, pattern: raw) { matched = true }
            }
        }
        if !anyAllow && anyExcl { return true }
        return matched
    }

    static func matchesGlobs(_ id: String, patterns: [String]) -> Bool {
        for p in patterns where globMatch(id, pattern: p) { return true }
        return false
    }

    /// Lightweight glob: `*` matches any run of characters, `?`
    /// matches one character; matching is case-insensitive (bundle
    /// ids are reverse-DNS so this is safe).
    public static func globMatch(_ s: String, pattern: String) -> Bool {
        let a = Array(s.lowercased())
        let p = Array(pattern.lowercased())
        return glob(a, 0, p, 0)
    }

    private static func glob(_ s: [Character], _ i: Int,
                             _ p: [Character], _ j: Int) -> Bool {
        if j == p.count { return i == s.count }
        if p[j] == "*" {
            if j + 1 == p.count { return true }
            for k in i...s.count {
                if glob(s, k, p, j + 1) { return true }
            }
            return false
        }
        if i == s.count { return false }
        if p[j] == "?" || p[j] == s[i] {
            return glob(s, i + 1, p, j + 1)
        }
        return false
    }
}
