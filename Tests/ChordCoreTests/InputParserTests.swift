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
    }

    func testUnknownToken() {
        XCTAssertThrowsError(try InputParser.parse("supercmd - a"))
    }
}
