import Foundation
import Testing
@testable import ChordCore

@Suite struct MatcherTests {
    private func b(
        _ name: String, trigger: Trigger, mods: Modifiers = [],
        apps: [String]? = nil
    ) -> Binding {
        Binding(
            name: name, trigger: trigger, modifiers: mods,
            apps: apps, action: .noop)
    }

    @Test func firstMatchWins() {
        let m = Matcher(bindings: [
            b("a", trigger: .key(0x69)),
            b("b", trigger: .key(0x69))
        ])
        let hit = m.find(
            .init(
                trigger: .key(0x69),
                modifiers: [], bundleID: nil))
        #expect(hit?.name == "a")
    }

    @Test func appAllowAndExcludeGlobs() {
        let m = Matcher(bindings: [
            b(
                "only-chrome", trigger: .mouseButton(.side1),
                apps: ["*chrome*"])
        ])
        let chrome = m.find(
            .init(
                trigger: .mouseButton(.side1),
                modifiers: [],
                bundleID: "com.google.Chrome"))
        #expect(chrome?.name == "only-chrome")
        let safari = m.find(
            .init(
                trigger: .mouseButton(.side1),
                modifiers: [],
                bundleID: "com.apple.Safari"))
        #expect(safari == nil)
    }

    @Test func globalExcludeApps() {
        let m = Matcher(
            bindings: [
                b("any", trigger: .key(0x69))
            ], excludeApps: ["com.apple.dt.Xcode"])
        let xcode = m.find(
            .init(
                trigger: .key(0x69),
                modifiers: [],
                bundleID: "com.apple.dt.Xcode"))
        #expect(xcode == nil)
    }

    @Test func exclusionWins() {
        let m = Matcher(bindings: [
            b(
                "almost-any", trigger: .mouseButton(.side2),
                apps: ["*", "!com.apple.dt.Xcode"])
        ])
        // The TOML loader turns ["*"] into nil; pretend the user
        // wrote a more interesting mix manually:
        let mix = Matcher(bindings: [
            b(
                "allow-and-block", trigger: .mouseButton(.side2),
                apps: ["*chrome*", "!com.google.Chrome.beta"])
        ])
        let main = mix.find(
            .init(
                trigger: .mouseButton(.side2),
                modifiers: [],
                bundleID: "com.google.Chrome"))
        #expect(main?.name == "allow-and-block")
        let beta = mix.find(
            .init(
                trigger: .mouseButton(.side2),
                modifiers: [],
                bundleID: "com.google.Chrome.beta"))
        #expect(beta == nil)
        _ = m  // silence unused
    }

    // MARK: - L/R modifier semantics (PR1)

    /// `ctrl - x` (any-side) accepts both lctrl-x and rctrl-x.
    @Test func anySideAcceptsBothPhysicalSides() {
        let m = Matcher(bindings: [
            b("any", trigger: .key(0x07), mods: .ctrl)  // x
        ])
        let left = m.find(
            .init(
                trigger: .key(0x07),
                modifiers: .lctrl, bundleID: nil))
        let right = m.find(
            .init(
                trigger: .key(0x07),
                modifiers: .rctrl, bundleID: nil))
        #expect(left?.name == "any")
        #expect(right?.name == "any")
    }

    /// `rctrl - x` requires the right side, rejects the left.
    @Test func strictRightRejectsLeft() {
        let m = Matcher(bindings: [
            b("strict-r", trigger: .key(0x07), mods: .rctrl)
        ])
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: .rctrl, bundleID: nil))?.name == "strict-r"
        )
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: .lctrl, bundleID: nil)) == nil
        )
    }

    /// `lctrl + rctrl - x` requires both sides held.
    @Test func requireBothSides() {
        let m = Matcher(bindings: [
            b("both", trigger: .key(0x07), mods: [.lctrl, .rctrl])
        ])
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: .lctrl, bundleID: nil)) == nil
        )
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: [.lctrl, .rctrl], bundleID: nil))?.name == "both"
        )
    }

    /// ZMK ULTRA_LL parity: rctrl+ralt+rshift on a key fires only
    /// when those three right-side keys are held *and no left ones*.
    @Test func ultraLLPattern() {
        let m = Matcher(bindings: [
            b(
                "ultra_ll", trigger: .key(0x08),  // c
                mods: [.rctrl, .ropt, .rshift])
        ])
        // Exactly right-side trio → fires.
        #expect(
            m.find(
                .init(
                    trigger: .key(0x08),
                    modifiers: [.rctrl, .ropt, .rshift],
                    bundleID: nil))?.name == "ultra_ll"
        )
        // One left modifier present → does NOT fire (the bug the
        // canon migration is fixing).
        #expect(
            m.find(
                .init(
                    trigger: .key(0x08),
                    modifiers: [.lctrl, .ropt, .rshift],
                    bundleID: nil)) == nil
        )
        // Plain left-side ctrl+opt+shift → does NOT fire either.
        #expect(
            m.find(
                .init(
                    trigger: .key(0x08),
                    modifiers: [.lctrl, .lopt, .lshift],
                    bundleID: nil)) == nil
        )
    }

    /// A binding with no modifiers must NOT match when modifiers
    /// are held — the existing exact-match contract holds.
    @Test func noModifierBindingRejectsHeldModifiers() {
        let m = Matcher(bindings: [
            b("bare", trigger: .key(0x07))  // no mods
        ])
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: [], bundleID: nil))?.name == "bare"
        )
        #expect(
            m.find(
                .init(
                    trigger: .key(0x07),
                    modifiers: .lctrl, bundleID: nil)) == nil
        )
    }

    // MARK: - globMatch behavioral coverage

    /// Empty pattern matches only empty input.
    @Test func globEmptyPattern() {
        #expect(Matcher.globMatch("", pattern: ""))
        #expect(!Matcher.globMatch("x", pattern: ""))
    }

    /// Bare "*" matches everything including empty.
    @Test func globBareStarMatchesAnything() {
        #expect(Matcher.globMatch("", pattern: "*"))
        #expect(Matcher.globMatch("com.apple.Safari", pattern: "*"))
    }

    /// "?" matches exactly one character.
    @Test func globQuestionMark() {
        #expect(Matcher.globMatch("ab", pattern: "?b"))
        #expect(!Matcher.globMatch("b", pattern: "?b"))
        #expect(!Matcher.globMatch("abb", pattern: "?b"))
    }

    /// Multiple "*" segments collapse correctly.
    @Test func globMultipleStars() {
        #expect(
            Matcher.globMatch(
                "com.google.Chrome",
                pattern: "*goog*chrome*"))
        #expect(
            Matcher.globMatch(
                "com.google.Chrome",
                pattern: "*.*.*"))
        #expect(
            !Matcher.globMatch(
                "com.google.Chrome",
                pattern: "*xyz*"))
    }

    /// Case-insensitive (bundle ids are reverse-DNS).
    @Test func globCaseInsensitive() {
        #expect(
            Matcher.globMatch(
                "Com.Apple.Safari",
                pattern: "*safari*"))
    }

    /// Adversarial: prior recursive impl was exponential on `*a*a*…*b`
    /// against `aaaa…`. With the linear impl this completes promptly.
    /// Regression guard: if someone reverts to a naive recursion, this
    /// either hangs the test target or fails the deadline check below.
    @Test func globNoExponentialBlowup() {
        let s = String(repeating: "a", count: 80)
        let p = String(repeating: "a*", count: 40) + "b"
        let start = Date()
        #expect(!Matcher.globMatch(s, pattern: p))
        #expect(
            Date().timeIntervalSince(start) < 1.0,
            "globMatch took too long — exponential regression")
    }
}
