import XCTest
@testable import ChordCore

/// Vendor-HID "v-key" path: `[v-key-aliases] NAME = <id>` + a binding that
/// selects one via a bare `input = "<name>"`. vkeys are ordinary bindings
/// carrying a `.vkey(id)` trigger, so apps / when-var / on-up all work and
/// they flow through the same Matcher as keyboard bindings.
final class VKeyTests: XCTestCase {
    /// A `[v-key-aliases]` entry + a bare-name `input` becomes a
    /// `.vkey(id)` trigger with no modifiers.
    func testVKeyAliasResolvesToTrigger() throws {
        let source = """
        [v-key-aliases]
        TU_LL_C = 0x26

        [[bindings]]
        name = "paste"
        input = "TU_LL_C"
        action-keys = "cmd - v"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.bindings.count, 1)
        XCTAssertEqual(r.config.bindings[0].trigger, .vkey(0x26))
        XCTAssertEqual(r.config.bindings[0].modifiers, [])
    }

    /// The migration's core case: ONE id, two app-scoped bindings. Both
    /// load; the Matcher routes by frontmost app (this is exactly what the
    /// flat `[[vkey]]` design could NOT express).
    func testVKeyAppRouting() throws {
        let source = """
        [v-key-aliases]
        TU_LL_C = 38

        [[bindings]]
        name = "chrome"
        input = "TU_LL_C"
        apps = ["com.google.Chrome"]
        action-keys = "ctrl + shift - tab"

        [[bindings]]
        name = "vscode"
        input = "TU_LL_C"
        apps = ["com.microsoft.VSCode"]
        action-keys = "cmd + shift - ["
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.bindings.count, 2)
        let m = Matcher(bindings: r.config.bindings)
        XCTAssertEqual(
            m.find(.init(trigger: .vkey(38), modifiers: [],
                         bundleID: "com.google.Chrome"))?.name, "chrome")
        XCTAssertEqual(
            m.find(.init(trigger: .vkey(38), modifiers: [],
                         bundleID: "com.microsoft.VSCode"))?.name, "vscode")
        // An app neither binding scopes to → no match (would beep via the
        // any-vkey fallback if one were declared).
        XCTAssertNil(
            m.find(.init(trigger: .vkey(38), modifiers: [],
                         bundleID: "com.apple.Terminal")))
    }

    /// The bare `v-key` literal is the any-vkey wildcard — `[[fallbacks]]`
    /// only; the single-sound "undefined vkey" feedback bucket.
    func testAnyVKeyWildcardFallback() throws {
        let source = """
        [[fallbacks]]
        name = "undefined vkey beep"
        input = "v-key"
        action-shell = "afplay /x.aiff"
        """
        let r = try Config.parse(source)
        XCTAssertEqual(r.droppedBindings, 0)
        XCTAssertEqual(r.config.fallbacks.count, 1)
        XCTAssertEqual(r.config.fallbacks[0].trigger, .anyVKey)
        let m = Matcher(bindings: [], fallbacks: r.config.fallbacks)
        // Matches any vkey the bindings missed…
        XCTAssertEqual(
            m.find(.init(trigger: .vkey(99), modifiers: [], bundleID: nil))?.name,
            "undefined vkey beep")
        // …but not a keyboard key (that is `*` / .anyKey territory).
        XCTAssertNil(m.find(.init(trigger: .key(0), modifiers: [], bundleID: nil)))
    }

    /// `v-key` in a regular `[[bindings]]` is rejected (wildcard is
    /// fallback-only, same contract as `*`).
    func testAnyVKeyRejectedInBindings() throws {
        let r = try Config.parse("""
        [[bindings]]
        input = "v-key"
        action-noop = true
        """)
        XCTAssertEqual(r.config.bindings.count, 0)
        XCTAssertGreaterThanOrEqual(r.droppedBindings, 1)
    }

    /// Out-of-range alias id is ignored; a binding that references it then
    /// fails to resolve and drops.
    func testAliasOutOfRangeIgnored() throws {
        let r = try Config.parse("""
        [v-key-aliases]
        BAD = 999

        [[bindings]]
        input = "BAD"
        action-noop = true
        """)
        XCTAssertEqual(r.config.bindings.count, 0)
        XCTAssertGreaterThanOrEqual(r.droppedBindings, 1)
    }

    /// An alias name that shadows a real keycode is rejected — `input = "a"`
    /// then resolves to the literal key `a`, never the alias (ambiguity
    /// guard keeps bare-name resolution sound).
    func testAliasShadowingKeycodeIgnored() throws {
        let r = try Config.parse("""
        [v-key-aliases]
        a = 5

        [[bindings]]
        input = "a"
        action-noop = true
        """)
        XCTAssertEqual(r.config.bindings.count, 1)
        XCTAssertEqual(r.config.bindings[0].trigger,
                       .key(KeyCodes.code(forName: "a")!))
    }

    /// Hex (`0x1A`) and decimal (`26`) id forms are equivalent.
    func testHexAndDecimalIds() throws {
        let r = try Config.parse("""
        [v-key-aliases]
        H = 0x1A
        D = 26

        [[bindings]]
        input = "H"
        action-noop = true

        [[bindings]]
        input = "D"
        action-noop = true
        """)
        XCTAssertEqual(r.config.bindings.count, 2)
        XCTAssertEqual(r.config.bindings[0].trigger, .vkey(0x1A))
        XCTAssertEqual(r.config.bindings[1].trigger, .vkey(26))
    }
}
