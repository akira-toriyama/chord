import XCTest
@testable import ChordApp
@testable import ChordCore

/// Covers `config --observe`'s pure formatter (`ObserveCommand.line` /
/// `modString`) and its dispatch wiring. The live tap + run loop in
/// `ObserveCommand.run()` is not unit-testable (it blocks until Ctrl-C
/// and needs an Accessibility grant), so the testable seam is the
/// pure event→line mapping plus the CLI registration.
@MainActor
final class ObserveFormatTests: XCTestCase {

    private func keyDown(_ code: UInt16, _ mods: Modifiers,
                         repeat isRepeat: Bool = false) -> InputEvent {
        InputEvent(trigger: .key(code), modifiers: mods,
                   frontmostBundleID: nil, kind: .down, isRepeat: isRepeat)
    }

    // MARK: - line(for:)

    func testKeyDownShowsCodeNameAndSideSpecificMods() {
        let line = ObserveCommand.line(for: keyDown(38, [.rctrl, .rshift]))
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("keyDown"))
        XCTAssertTrue(line!.contains("code=38"))
        // Name comes from KeyCodes (38 == ANSI 'j'); don't hardcode it.
        XCTAssertTrue(line!.contains("key=\(KeyCodes.name(forCode: 38))"))
        // The whole point: side bits are surfaced, not collapsed to "ctrl".
        XCTAssertTrue(line!.contains("rctrl + rshift"))
        XCTAssertFalse(line!.contains("(repeat)"))
    }

    func testKeyDownNoModifiersShowsNone() {
        let line = ObserveCommand.line(for: keyDown(0, []))
        XCTAssertEqual(line?.contains("mods=[(none)]"), true)
    }

    func testAutorepeatIsFlagged() {
        let line = ObserveCommand.line(for: keyDown(38, [.lcmd], repeat: true))
        XCTAssertEqual(line?.contains("(repeat)"), true)
    }

    func testKeyUpIsOmitted() {
        let up = InputEvent(trigger: .key(38), modifiers: [.rctrl],
                            frontmostBundleID: nil, kind: .up)
        XCTAssertNil(ObserveCommand.line(for: up))
    }

    func testSyntheticEventIsOmitted() {
        let synth = InputEvent(trigger: .key(38), modifiers: [],
                               frontmostBundleID: nil, kind: .down,
                               isSynthetic: true)
        XCTAssertNil(ObserveCommand.line(for: synth))
    }

    func testModifiersChangedWithHeldModShown() {
        let e = InputEvent(trigger: .key(0), modifiers: [.rctrl],
                           frontmostBundleID: nil, kind: .modifiersChanged)
        let line = ObserveCommand.line(for: e)
        XCTAssertEqual(line?.contains("flags"), true)
        XCTAssertEqual(line?.contains("rctrl"), true)
    }

    func testModifiersChangedReleaseToEmptyIsOmitted() {
        let e = InputEvent(trigger: .key(0), modifiers: [],
                           frontmostBundleID: nil, kind: .modifiersChanged)
        XCTAssertNil(ObserveCommand.line(for: e))
    }

    func testMouseButtonDownShowsNameAndRawNumber() {
        let e = InputEvent(trigger: .mouseButton(.side1), modifiers: [.cmd],
                           frontmostBundleID: nil, kind: .down)
        let line = ObserveCommand.line(for: e)
        XCTAssertEqual(line?.contains("mouseDown"), true)
        XCTAssertEqual(line?.contains("side1"), true)
        XCTAssertEqual(line?.contains("(3)"), true)   // MouseButton.side1.rawValue
    }

    func testScrollShowsDirection() {
        let e = InputEvent(trigger: .scroll(.up), modifiers: [],
                           frontmostBundleID: nil, kind: .down)
        XCTAssertEqual(ObserveCommand.line(for: e)?.contains("dir=up"), true)
    }

    // MARK: - modString

    func testModStringEmptyIsNone() {
        XCTAssertEqual(ObserveCommand.modString([]), "(none)")
    }

    func testModStringKeepsSideBitsInStableOrder() {
        XCTAssertEqual(ObserveCommand.modString([.rshift, .lctrl]),
                       "lctrl + rshift")
    }

    // MARK: - dispatch wiring (no tap is opened)

    /// `config --observe` is registered as a verb that honours no
    /// modifiers — so passing one is rejected (exit 2) BEFORE the
    /// blocking `run()` is reached. This proves the verb is wired in
    /// without actually opening a tap.
    func testObserveRejectsModifierFlag() {
        let out = ChordApp.dispatch(["config", "--observe", "--json"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("no effect with --observe") == true)
    }

    func testObserveAppearsInHelp() {
        let out = ChordApp.dispatch(["--help"])
        XCTAssertTrue(out?.stdout?.contains("config --observe") == true)
    }
}
