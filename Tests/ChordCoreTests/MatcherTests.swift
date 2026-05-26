import XCTest
@testable import ChordCore

final class MatcherTests: XCTestCase {
    private func b(_ name: String, trigger: Trigger, mods: Modifiers = [],
                   apps: [String]? = nil) -> Binding {
        Binding(name: name, trigger: trigger, modifiers: mods,
                apps: apps, action: .noop)
    }

    func testFirstMatchWins() {
        let m = Matcher(bindings: [
            b("a", trigger: .key(0x69)),
            b("b", trigger: .key(0x69)),
        ])
        let hit = m.find(.init(trigger: .key(0x69),
                               modifiers: [], bundleID: nil))
        XCTAssertEqual(hit?.name, "a")
    }

    func testAppAllowAndExcludeGlobs() {
        let m = Matcher(bindings: [
            b("only-chrome", trigger: .mouseButton(.side1),
              apps: ["*chrome*"]),
        ])
        let chrome = m.find(.init(trigger: .mouseButton(.side1),
                                  modifiers: [],
                                  bundleID: "com.google.Chrome"))
        XCTAssertEqual(chrome?.name, "only-chrome")
        let safari = m.find(.init(trigger: .mouseButton(.side1),
                                  modifiers: [],
                                  bundleID: "com.apple.Safari"))
        XCTAssertNil(safari)
    }

    func testGlobalExcludeApps() {
        let m = Matcher(bindings: [
            b("any", trigger: .key(0x69)),
        ], excludeApps: ["com.apple.dt.Xcode"])
        let xcode = m.find(.init(trigger: .key(0x69),
                                 modifiers: [],
                                 bundleID: "com.apple.dt.Xcode"))
        XCTAssertNil(xcode)
    }

    func testExclusionWins() {
        let m = Matcher(bindings: [
            b("almost-any", trigger: .mouseButton(.side2),
              apps: ["*", "!com.apple.dt.Xcode"]),
        ])
        // The TOML loader turns ["*"] into nil; pretend the user
        // wrote a more interesting mix manually:
        let mix = Matcher(bindings: [
            b("allow-and-block", trigger: .mouseButton(.side2),
              apps: ["*chrome*", "!com.google.Chrome.beta"]),
        ])
        let main = mix.find(.init(trigger: .mouseButton(.side2),
                                  modifiers: [],
                                  bundleID: "com.google.Chrome"))
        XCTAssertEqual(main?.name, "allow-and-block")
        let beta = mix.find(.init(trigger: .mouseButton(.side2),
                                  modifiers: [],
                                  bundleID: "com.google.Chrome.beta"))
        XCTAssertNil(beta)
        _ = m  // silence unused
    }

    // MARK: - L/R modifier semantics (PR1)

    /// `ctrl - x` (any-side) accepts both lctrl-x and rctrl-x.
    func testAnySideAcceptsBothPhysicalSides() {
        let m = Matcher(bindings: [
            b("any", trigger: .key(0x07), mods: .ctrl),  // x
        ])
        let left = m.find(.init(trigger: .key(0x07),
                                modifiers: .lctrl, bundleID: nil))
        let right = m.find(.init(trigger: .key(0x07),
                                 modifiers: .rctrl, bundleID: nil))
        XCTAssertEqual(left?.name,  "any")
        XCTAssertEqual(right?.name, "any")
    }

    /// `rctrl - x` requires the right side, rejects the left.
    func testStrictRightRejectsLeft() {
        let m = Matcher(bindings: [
            b("strict-r", trigger: .key(0x07), mods: .rctrl),
        ])
        XCTAssertEqual(
            m.find(.init(trigger: .key(0x07),
                         modifiers: .rctrl, bundleID: nil))?.name,
            "strict-r"
        )
        XCTAssertNil(
            m.find(.init(trigger: .key(0x07),
                         modifiers: .lctrl, bundleID: nil))
        )
    }

    /// `lctrl + rctrl - x` requires both sides held.
    func testRequireBothSides() {
        let m = Matcher(bindings: [
            b("both", trigger: .key(0x07), mods: [.lctrl, .rctrl]),
        ])
        XCTAssertNil(
            m.find(.init(trigger: .key(0x07),
                         modifiers: .lctrl, bundleID: nil))
        )
        XCTAssertEqual(
            m.find(.init(trigger: .key(0x07),
                         modifiers: [.lctrl, .rctrl], bundleID: nil))?.name,
            "both"
        )
    }

    /// ZMK ULTRA_LL parity: rctrl+ralt+rshift on a key fires only
    /// when those three right-side keys are held *and no left ones*.
    func testUltraLLPattern() {
        let m = Matcher(bindings: [
            b("ultra_ll", trigger: .key(0x08),  // c
              mods: [.rctrl, .ropt, .rshift]),
        ])
        // Exactly right-side trio → fires.
        XCTAssertEqual(
            m.find(.init(trigger: .key(0x08),
                         modifiers: [.rctrl, .ropt, .rshift],
                         bundleID: nil))?.name,
            "ultra_ll"
        )
        // One left modifier present → does NOT fire (the bug the
        // canon migration is fixing).
        XCTAssertNil(
            m.find(.init(trigger: .key(0x08),
                         modifiers: [.lctrl, .ropt, .rshift],
                         bundleID: nil))
        )
        // Plain left-side ctrl+opt+shift → does NOT fire either.
        XCTAssertNil(
            m.find(.init(trigger: .key(0x08),
                         modifiers: [.lctrl, .lopt, .lshift],
                         bundleID: nil))
        )
    }

    /// A binding with no modifiers must NOT match when modifiers
    /// are held — the existing exact-match contract holds.
    func testNoModifierBindingRejectsHeldModifiers() {
        let m = Matcher(bindings: [
            b("bare", trigger: .key(0x07)),  // no mods
        ])
        XCTAssertEqual(
            m.find(.init(trigger: .key(0x07),
                         modifiers: [], bundleID: nil))?.name,
            "bare"
        )
        XCTAssertNil(
            m.find(.init(trigger: .key(0x07),
                         modifiers: .lctrl, bundleID: nil))
        )
    }
}
