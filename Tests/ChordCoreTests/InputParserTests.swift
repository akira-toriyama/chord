import XCTest
@testable import ChordCore

final class InputParserTests: XCTestCase {
    func testSimpleKey() throws {
        let p = try InputParser.parse("f13")
        XCTAssertEqual(p.modifiers, [])
        XCTAssertEqual(p.trigger, .key(0x69))
    }

    func testF24KaraConvention() throws {
        let p = try InputParser.parse("f24")
        XCTAssertEqual(p.trigger, .key(0x6C))
    }

    func testModifiers() throws {
        let p = try InputParser.parse("cmd + shift - return")
        XCTAssertEqual(p.modifiers, [.cmd, .shift])
        XCTAssertEqual(p.trigger, .key(0x24))
    }

    func testHyperExpands() throws {
        let p = try InputParser.parse("hyper - space")
        XCTAssertEqual(p.modifiers, .hyper)
    }

    func testMouseSide1() throws {
        let p = try InputParser.parse("mouse.side1")
        XCTAssertEqual(p.trigger, .mouseButton(.side1))
    }

    func testScroll() throws {
        let p = try InputParser.parse("ctrl - scroll.up")
        XCTAssertEqual(p.modifiers, .ctrl)
        XCTAssertEqual(p.trigger, .scroll(.up))
    }

    func testPlusOnly() throws {
        let p = try InputParser.parse("cmd + a")
        XCTAssertEqual(p.modifiers, .cmd)
        XCTAssertEqual(p.trigger, .key(0x00))
    }

    func testKeycodeEscape() throws {
        let p = try InputParser.parse("keycode-200")
        XCTAssertEqual(p.trigger, .key(200))
        XCTAssertEqual(p.modifiers, [])
    }

    /// Regression: `keycode-NNN` contains a `-`, which collides
    /// with the modifier/primary separator. The parser's fast-path
    /// (try-primary-first) covers the standalone form. With
    /// modifiers we still need the separator-based split to work.
    func testKeycodeWithModifier() throws {
        let p = try InputParser.parse("ctrl - keycode-200")
        XCTAssertEqual(p.modifiers, .ctrl)
        XCTAssertEqual(p.trigger, .key(200))
    }

    func testUnknownToken() {
        XCTAssertThrowsError(try InputParser.parse("supercmd - a"))
    }

    // MARK: - L/R modifier tokens (PR1)

    func testRightCtrlToken() throws {
        let p = try InputParser.parse("rctrl - a")
        XCTAssertEqual(p.modifiers, .rctrl)
    }

    func testLeftAndRightCtrlTokens() throws {
        let p = try InputParser.parse("lctrl + rctrl - a")
        XCTAssertEqual(p.modifiers, [.lctrl, .rctrl])
    }

    func testRaltIsAliasForRopt() throws {
        let p = try InputParser.parse("ralt - a")
        XCTAssertEqual(p.modifiers, .ropt)
    }

    func testUltraLLChord() throws {
        // ZMK ULTRA_LL = right-side ctrl + alt + shift modifier set.
        let p = try InputParser.parse("rctrl + ralt + rshift - c")
        XCTAssertEqual(p.modifiers, [.rctrl, .ropt, .rshift])
        XCTAssertEqual(p.trigger, .key(0x08))
    }

    func testAnySideStillSupported() throws {
        // Existing tokens still parse to the any-side bits — no
        // breakage of any user's current config.
        let p = try InputParser.parse("ctrl + shift - z")
        XCTAssertEqual(p.modifiers, [.ctrl, .shift])
    }
}
