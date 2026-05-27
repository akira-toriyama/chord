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
    /// Document-ordered fallback bindings, consulted only after every
    /// `bindings` entry misses. Their trigger may be `.anyKey` (the
    /// `*` wildcard) — the matching path special-cases this so a
    /// fallback whose modifier constraint accepts the event will
    /// fire for any keyboard key not already handled above.
    public let fallbacks: [Binding]
    public let excludeApps: [String]

    public init(bindings: [Binding], fallbacks: [Binding] = [],
                excludeApps: [String] = []) {
        self.bindings = bindings
        self.fallbacks = fallbacks
        self.excludeApps = excludeApps
    }

    public struct Event: Hashable, Sendable {
        public var trigger: Trigger
        public var modifiers: Modifiers
        public var bundleID: String?
        /// v2: snapshot of the controller's variable store at the
        /// moment this event arrived. Defaulted to empty so existing
        /// call sites (synthetic tests, fallbacks) compile unchanged.
        public var state: StateSnapshot

        public init(trigger: Trigger, modifiers: Modifiers,
                    bundleID: String?,
                    state: StateSnapshot = StateSnapshot()) {
            self.trigger = trigger
            self.modifiers = modifiers
            self.bundleID = bundleID
            self.state = state
        }
    }

    public func find(_ event: Event) -> Binding? {
        if let id = event.bundleID,
           Matcher.matchesGlobs(id, patterns: excludeApps) {
            return nil
        }
        // Stage 1: regular bindings, document order, first-match-wins.
        if let hit = findIn(bindings, event: event) { return hit }
        // Stage 2: fallbacks. Only consulted when stage 1 misses.
        // `.anyKey` triggers match every concrete `.key(_)` event
        // whose modifier mask satisfies the constraint.
        return findIn(fallbacks, event: event)
    }

    private func findIn(_ rules: [Binding], event: Event) -> Binding? {
        for b in rules {
            guard triggerMatches(b.trigger, event: event.trigger)
            else { continue }
            // Predicate match (NOT ==): the binding constraint may
            // ask for any-side `ctrl`, the event carries side-
            // specific `lctrl`/`rctrl`. See `Modifiers.matches`.
            guard b.modifiers.matches(event: event.modifiers)
            else { continue }
            if let apps = b.apps {
                guard let id = event.bundleID else { continue }
                if !Matcher.appsAllow(id, patterns: apps) { continue }
            }
            // v2 state gate. Evaluated last because most bindings
            // have `condition == nil` and the modifier / apps tests
            // are cheaper to short-circuit on the hot keystroke path.
            if let cond = b.condition,
               !Matcher.conditionHolds(cond, state: event.state)
            {
                continue
            }
            return b
        }
        return nil
    }

    /// Pure function — Matcher stays value-type and the tap thread
    /// calls into it lock-free (the snapshot was already copied in).
    /// An unset variable reads as 0; `Condition.variable(_, equals: 0)`
    /// is the idiomatic "mode is cleared" predicate.
    static func conditionHolds(_ c: Condition, state: StateSnapshot) -> Bool {
        switch c {
        case .variable(let name, let expected):
            return state.value(name) == expected
        }
    }

    private func triggerMatches(_ ruleTrigger: Trigger,
                                event: Trigger) -> Bool {
        if case .anyKey = ruleTrigger {
            // The wildcard fires only for keyboard events, not
            // mouse / scroll. Mouse fallbacks were considered for
            // v1 and explicitly deferred (canon use case
            // is keyboard-only).
            if case .key = event { return true }
            return false
        }
        return ruleTrigger == event
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
