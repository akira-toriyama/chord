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
public enum ModifierEdge: Hashable, Sendable {
    /// The binding's modifier mask just became satisfied (entry action).
    case entered
    /// The mask just stopped being satisfied (fire the binding's onUp).
    case exited
}

public struct Matcher: Sendable {
    public let bindings: [Binding]
    /// Document-ordered fallback bindings, consulted only after every
    /// `bindings` entry misses. Their trigger may be `.anyKey` (the
    /// `*` wildcard) — the matching path special-cases this so a
    /// fallback whose modifier constraint accepts the event will
    /// fire for any keyboard key not already handled above.
    public let fallbacks: [Binding]
    public let excludeApps: [String]
    /// When true, arrow / nav triggers (see [KeyCodes.fnAutoNavKeycodes])
    /// match regardless of the binding's / event's `fn` bit. macOS
    /// always tags those keys with `fn`, so the strict comparison
    /// would force every arrow binding to spell out `+ fn`. Mirrors
    /// `ChordConfig.Options.fnAutoArrows`.
    public let fnAutoArrows: Bool

    public init(bindings: [Binding], fallbacks: [Binding] = [],
                excludeApps: [String] = [],
                fnAutoArrows: Bool = true) {
        self.bindings = bindings
        self.fallbacks = fallbacks
        self.excludeApps = excludeApps
        self.fnAutoArrows = fnAutoArrows
    }

    public struct Event: Hashable, Sendable {
        public var trigger: Trigger
        public var modifiers: Modifiers
        public var bundleID: String?
        /// v2: snapshot of the controller's variable store at the
        /// moment this event arrived. Defaulted to empty so existing
        /// call sites (synthetic tests, fallbacks) compile unchanged.
        public var state: StateSnapshot
        /// chord 0.9.0+: the OS-side keyboard input source id at the
        /// moment this event arrived (e.g.
        /// `"com.apple.keylayout.US"`). `nil` when unknown / pre-init.
        /// Matched against `Binding.inputSource` glob list.
        public var inputSourceID: String?

        public init(trigger: Trigger, modifiers: Modifiers,
                    bundleID: String?,
                    state: StateSnapshot = StateSnapshot(),
                    inputSourceID: String? = nil) {
            self.trigger = trigger
            self.modifiers = modifiers
            self.bundleID = bundleID
            self.state = state
            self.inputSourceID = inputSourceID
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
            //
            // `ignoreFn` relaxes the strict `fn` comparison for arrow
            // / nav keys when the option is on. macOS always sets `fn`
            // on those events; without relaxation `input = "ctrl - right"`
            // would silently never match an actual ctrl+→ keystroke.
            // For the wildcard fallback (`.anyKey`), the event's
            // concrete trigger drives the decision.
            let triggerForFn: Trigger
            if case .anyKey = b.trigger { triggerForFn = event.trigger }
            else { triggerForFn = b.trigger }
            let ignoreFn = fnAutoArrows && KeyCodes.isFnAutoNav(triggerForFn)
            guard b.modifiers.matches(event: event.modifiers,
                                      ignoreFn: ignoreFn)
            else { continue }
            if let apps = b.apps {
                guard let id = event.bundleID else { continue }
                if !Matcher.appsAllow(id, patterns: apps) { continue }
            }
            // chord 0.9.0+ input-source filter (same glob semantics
            // as `apps`). When the current source is unknown, treat
            // every `inputSource` binding as a miss — caller can opt
            // out by leaving `inputSource` nil.
            if let sources = b.inputSource {
                guard let id = event.inputSourceID else { continue }
                if !Matcher.appsAllow(id, patterns: sources) { continue }
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

    /// Pure: which `.modifiersOnly` bindings cross an entry/exit edge as
    /// the OS modifier mask goes `prev → curr`. Applies the same app-scope
    /// and condition gates as [find]; an `.exited` pair is returned only
    /// when the binding carries an `onUpAction` (the caller swaps it in).
    /// Extracted from the Controller so the `.modifiersChanged` path no
    /// longer re-implements `appsAllow` / `conditionHolds` / the edge math.
    public func modifierTransitions(
        prev: Modifiers, curr: Modifiers,
        state: StateSnapshot, bundleID: String?
    ) -> [(binding: Binding, edge: ModifierEdge)] {
        // Global exclude-apps gate — mirror `find()`. A globally disabled
        // app must fire no edges either; otherwise a modifier-only binding
        // (a setVariable leader, a hold-while) still fires in an app the
        // user excluded. `find()` honored `excludeApps`; this extracted
        // edge path did not, so the exclusion silently leaked.
        if let id = bundleID,
           Matcher.matchesGlobs(id, patterns: excludeApps) {
            return []
        }
        var out: [(binding: Binding, edge: ModifierEdge)] = []
        for b in bindings where b.trigger == .modifiersOnly {
            if let apps = b.apps {
                guard let id = bundleID else { continue }
                if !Matcher.appsAllow(id, patterns: apps) { continue }
            }
            if let cond = b.condition,
               !Matcher.conditionHolds(cond, state: state) { continue }
            let prevSat = b.modifiers.matches(event: prev)
            let curSat = b.modifiers.matches(event: curr)
            if !prevSat && curSat {
                out.append((b, .entered))
            } else if prevSat && !curSat, b.onUpAction != nil {
                out.append((b, .exited))
            }
        }
        return out
    }

    /// Pure function — Matcher stays value-type and the tap thread
    /// calls into it lock-free (the snapshot was already copied in).
    /// An unset variable reads as 0; `Condition.variable(_, equals: 0)`
    /// is the idiomatic "mode is cleared" predicate.
    ///
    /// Public so the Controller's modifier-only / flagsChanged path
    /// can apply the same gate semantics without going through
    /// `find(_:)` (which insists on a concrete .key / .mouse / .scroll
    /// event trigger).
    public static func conditionHolds(_ c: Condition,
                                      state: StateSnapshot) -> Bool {
        switch c {
        case .variable(let name, let expected):
            return state.value(name) == expected
        case .conjunction(let parts):
            return parts.allSatisfy { conditionHolds($0, state: state) }
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
        // Vendor-HID wildcard: `.anyVKey` (the `input = "v-key"`
        // fallback literal) matches every `.vkey` event not already
        // handled — the single-sound "undefined vkey" feedback bucket.
        if case .anyVKey = ruleTrigger {
            if case .vkey = event { return true }
            return false
        }
        return ruleTrigger == event
    }

    // MARK: - glob matching

    /// `["*"]` is treated as "any" by the caller (apps == nil); this
    /// function handles the mixed allow/deny list otherwise. One
    /// exclusion match wins over any allowlist match. Public so the
    /// Controller's modifier-only flagsChanged path can re-use the
    /// same glob semantics without going through `find(_:)`.
    public static func appsAllow(_ id: String, patterns: [String]) -> Bool {
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
    ///
    /// Iterative star-backtrack: O(n·m) worst case, O(n+m) on inputs
    /// without ambiguous `*` runs. Replaced the previous recursive
    /// implementation whose `for k in i...s.count { glob(...) }` loop
    /// is exponential on patterns like `*a*a*a*` against `aaaa...b`
    /// (never observed in bundle-id workloads, but the linear form
    /// is also simpler).
    public static func globMatch(_ s: String, pattern: String) -> Bool {
        let a = Array(s.lowercased())
        let p = Array(pattern.lowercased())
        var i = 0
        var j = 0
        var starJ = -1
        var matchI = 0
        while i < a.count {
            if j < p.count && (p[j] == "?" || p[j] == a[i]) {
                i += 1
                j += 1
            } else if j < p.count && p[j] == "*" {
                starJ = j
                matchI = i
                j += 1
            } else if starJ != -1 {
                j = starJ + 1
                matchI += 1
                i = matchI
            } else {
                return false
            }
        }
        while j < p.count && p[j] == "*" { j += 1 }
        return j == p.count
    }
}
