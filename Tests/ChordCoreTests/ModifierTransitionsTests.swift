import XCTest
@testable import ChordCore

/// T7b — `Matcher.modifierTransitions`, the pure modifier-only
/// entry/exit edge logic extracted from `Controller.fireModifierOnlyBindings`.
/// Previously this lived inline in the daemon with no direct coverage.
final class ModifierTransitionsTests: XCTestCase {

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
                             bundleID: String? = nil)
        -> [(binding: Binding, edge: ModifierEdge)]
    {
        Matcher(bindings: bindings)
            .modifierTransitions(prev: prev, curr: curr,
                                 state: state, bundleID: bundleID)
    }

    // NOTE: `prev`/`curr` are EVENT masks — they carry side-specific bits
    // (`.lcmd`/`.rcmd`…), exactly as the OS reports and the live Controller
    // passes. Binding constraints stay any-side (`.cmd`); `Modifiers.matches`
    // resolves any-side against either physical side.

    func testEntryWhenMaskBecomesSatisfied() {
        let edges = transitions([modBinding("wm", mods: [.cmd, .opt])],
                                prev: [], curr: [.lcmd, .lopt])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.binding.name, "wm")
        XCTAssertEqual(edges.first?.edge, .entered)
    }

    func testExitEmittedOnlyWhenOnUpPresent() {
        // With onUp → exit edge.
        let withOnUp = transitions(
            [modBinding("h", mods: [.cmd, .opt],
                        onUp: .setVariable(name: "h", value: 0))],
            prev: [.lcmd, .lopt], curr: [])
        XCTAssertEqual(withOnUp.count, 1)
        XCTAssertEqual(withOnUp.first?.edge, .exited)

        // Without onUp → no exit edge (nothing to fire on release).
        let noOnUp = transitions([modBinding("wm", mods: [.cmd, .opt])],
                                 prev: [.lcmd, .lopt], curr: [])
        XCTAssertTrue(noOnUp.isEmpty)
    }

    func testNoEdgeWhenSatisfactionUnchanged() {
        let b = [modBinding("wm", mods: [.cmd, .opt],
                            onUp: .setVariable(name: "wm", value: 0))]
        // Still satisfied before and after → neither entry nor exit.
        XCTAssertTrue(transitions(b, prev: [.lcmd, .lopt], curr: [.lcmd, .lopt]).isEmpty)
        // Still unsatisfied before and after → nothing.
        XCTAssertTrue(transitions(b, prev: [.lshift], curr: [.lctrl]).isEmpty)
    }

    func testNonModifierOnlyBindingsIgnored() {
        let edges = transitions([
            modBinding("mods", mods: [.cmd]),
            Binding(name: "key", trigger: .key(0x69), modifiers: [.cmd],
                    apps: nil, action: .noop),
        ], prev: [], curr: [.lcmd])
        XCTAssertEqual(edges.map(\.binding.name), ["mods"])
    }

    func testAppScopeFiltersTransitions() {
        let b = [modBinding("safari-only", mods: [.cmd],
                            apps: ["com.apple.Safari"])]
        // Wrong app → no transition.
        XCTAssertTrue(transitions(b, prev: [], curr: [.lcmd],
                                  bundleID: "com.google.Chrome").isEmpty)
        // Right app → entry.
        XCTAssertEqual(
            transitions(b, prev: [], curr: [.lcmd],
                        bundleID: "com.apple.Safari").first?.edge,
            .entered)
    }

    func testConditionGateFiltersTransitions() {
        let b = [modBinding("gated", mods: [.cmd],
                            condition: .variable(name: "on", equals: 1))]
        // Gate unmet → no transition.
        XCTAssertTrue(transitions(b, prev: [], curr: [.lcmd]).isEmpty)
        // Gate met → entry.
        XCTAssertEqual(
            transitions(b, prev: [], curr: [.lcmd],
                        state: StateSnapshot(variables: ["on": 1])).first?.edge,
            .entered)
    }
}
