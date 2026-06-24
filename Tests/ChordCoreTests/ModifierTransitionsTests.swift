import Testing
@testable import ChordCore

/// T7b — `Matcher.modifierTransitions`, the pure modifier-only
/// entry/exit edge logic extracted from `Controller.fireModifierOnlyBindings`.
/// Previously this lived inline in the daemon with no direct coverage.
@Suite struct ModifierTransitionsTests {

    private func modBinding(_ name: String, mods: Modifiers,
                            apps: [String]? = nil,
                            condition: Condition? = nil,
                            onUp: Action? = nil) -> Binding {
        Binding(name: name, trigger: .modifiersOnly, modifiers: mods,
                apps: apps, action: .setVariable(name: name, value: 1),
                condition: condition, onUpAction: onUp)
    }

    private func transitions(_ bindings: [Binding],
                             prev: Modifiers, curr: Modifiers,
                             state: StateSnapshot = StateSnapshot(),
                             bundleID: String? = nil,
                             excludeApps: [String] = [])
        -> [(binding: Binding, edge: ModifierEdge)]
    {
        Matcher(bindings: bindings, excludeApps: excludeApps)
            .modifierTransitions(prev: prev, curr: curr,
                                 state: state, bundleID: bundleID)
    }

    // NOTE: `prev`/`curr` are EVENT masks — they carry side-specific bits
    // (`.lcmd`/`.rcmd`…), exactly as the OS reports and the live Controller
    // passes. Binding constraints stay any-side (`.cmd`); `Modifiers.matches`
    // resolves any-side against either physical side.

    @Test func entryWhenMaskBecomesSatisfied() {
        let edges = transitions([modBinding("wm", mods: [.cmd, .opt])],
                                prev: [], curr: [.lcmd, .lopt])
        #expect(edges.count == 1)
        #expect(edges.first?.binding.name == "wm")
        #expect(edges.first?.edge == .entered)
    }

    @Test func exitEmittedOnlyWhenOnUpPresent() {
        // With onUp → exit edge.
        let withOnUp = transitions(
            [modBinding("h", mods: [.cmd, .opt],
                        onUp: .setVariable(name: "h", value: 0))],
            prev: [.lcmd, .lopt], curr: [])
        #expect(withOnUp.count == 1)
        #expect(withOnUp.first?.edge == .exited)

        // Without onUp → no exit edge (nothing to fire on release).
        let noOnUp = transitions([modBinding("wm", mods: [.cmd, .opt])],
                                 prev: [.lcmd, .lopt], curr: [])
        #expect(noOnUp.isEmpty)
    }

    @Test func noEdgeWhenSatisfactionUnchanged() {
        let b = [modBinding("wm", mods: [.cmd, .opt],
                            onUp: .setVariable(name: "wm", value: 0))]
        // Still satisfied before and after → neither entry nor exit.
        #expect(transitions(b, prev: [.lcmd, .lopt], curr: [.lcmd, .lopt]).isEmpty)
        // Still unsatisfied before and after → nothing.
        #expect(transitions(b, prev: [.lshift], curr: [.lctrl]).isEmpty)
    }

    @Test func nonModifierOnlyBindingsIgnored() {
        let edges = transitions([
            modBinding("mods", mods: [.cmd]),
            Binding(name: "key", trigger: .key(0x69), modifiers: [.cmd],
                    apps: nil, action: .noop),
        ], prev: [], curr: [.lcmd])
        #expect(edges.map(\.binding.name) == ["mods"])
    }

    @Test func appScopeFiltersTransitions() {
        let b = [modBinding("safari-only", mods: [.cmd],
                            apps: ["com.apple.Safari"])]
        // Wrong app → no transition.
        #expect(transitions(b, prev: [], curr: [.lcmd],
                            bundleID: "com.google.Chrome").isEmpty)
        // Right app → entry.
        #expect(
            transitions(b, prev: [], curr: [.lcmd],
                        bundleID: "com.apple.Safari").first?.edge == .entered)
    }

    @Test func globalExcludeAppsSuppressesTransitions() {
        // Regression for the exclude_apps bypass: a globally excluded app
        // must fire NO modifier-only edges, exactly as `Matcher.find()`
        // returns nil for it. Before the fix the extracted edge path
        // ignored `excludeApps`, so a setVariable leader still fired in an
        // app the user had globally disabled.
        let b = [modBinding("leader", mods: [.cmd])]
        #expect(
            transitions(b, prev: [], curr: [.lcmd],
                        bundleID: "com.apple.dt.Xcode",
                        excludeApps: ["com.apple.dt.Xcode"]).isEmpty)
        // A glob excludes too (same semantics as find()).
        #expect(
            transitions(b, prev: [], curr: [.lcmd],
                        bundleID: "com.foo.bar",
                        excludeApps: ["com.foo.*"]).isEmpty)
        // A non-excluded app still gets its entry edge.
        #expect(
            transitions(b, prev: [], curr: [.lcmd],
                        bundleID: "com.apple.Safari",
                        excludeApps: ["com.apple.dt.Xcode"]).first?.edge == .entered)
    }

    @Test func conditionGateFiltersTransitions() {
        let b = [modBinding("gated", mods: [.cmd],
                            condition: .variable(name: "on", equals: 1))]
        // Gate unmet → no transition.
        #expect(transitions(b, prev: [], curr: [.lcmd]).isEmpty)
        // Gate met → entry.
        #expect(
            transitions(b, prev: [], curr: [.lcmd],
                        state: StateSnapshot(variables: ["on": 1])).first?.edge == .entered)
    }
}
