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
}
