import Testing
@testable import ChordApp
@testable import ChordCore

/// Covers `config --observe`'s pure formatter (`ObserveCommand.line` /
/// `modString`) and its dispatch wiring. The live tap + run loop in
/// `ObserveCommand.run()` is not unit-testable (it blocks until Ctrl-C
/// and needs an Accessibility grant), so the testable seam is the
/// pure event→line mapping plus the CLI registration.
@Suite @MainActor
struct ObserveFormatTests {

    private func keyDown(_ code: UInt16, _ mods: Modifiers,
                         repeat isRepeat: Bool = false) -> InputEvent {
        InputEvent(trigger: .key(code), modifiers: mods,
                   frontmostBundleID: nil, kind: .down, isRepeat: isRepeat)
    }

    // MARK: - line(for:)

    @Test func keyDownShowsCodeNameAndSideSpecificMods() {
        let line = ObserveCommand.line(for: keyDown(38, [.rctrl, .rshift]))
        #expect(line != nil)
        #expect(line!.contains("keyDown"))
        #expect(line!.contains("code=38"))
        // Name comes from KeyCodes (38 == ANSI 'j'); don't hardcode it.
        #expect(line!.contains("key=\(KeyCodes.name(forCode: 38))"))
        // The whole point: side bits are surfaced, not collapsed to "ctrl".
        #expect(line!.contains("rctrl + rshift"))
        #expect(!line!.contains("(repeat)"))
    }

    @Test func keyDownNoModifiersShowsNone() {
        let line = ObserveCommand.line(for: keyDown(0, []))
        #expect(line?.contains("mods=[(none)]") == true)
    }

    @Test func autorepeatIsFlagged() {
        let line = ObserveCommand.line(for: keyDown(38, [.lcmd], repeat: true))
        #expect(line?.contains("(repeat)") == true)
    }

    @Test func keyUpIsOmitted() {
        let up = InputEvent(trigger: .key(38), modifiers: [.rctrl],
                            frontmostBundleID: nil, kind: .up)
        #expect(ObserveCommand.line(for: up) == nil)
    }

    @Test func syntheticEventIsOmitted() {
        let synth = InputEvent(trigger: .key(38), modifiers: [],
                               frontmostBundleID: nil, kind: .down,
                               isSynthetic: true)
        #expect(ObserveCommand.line(for: synth) == nil)
    }

    @Test func modifiersChangedWithHeldModShown() {
        let e = InputEvent(trigger: .key(0), modifiers: [.rctrl],
                           frontmostBundleID: nil, kind: .modifiersChanged)
        let line = ObserveCommand.line(for: e)
        #expect(line?.contains("flags") == true)
        #expect(line?.contains("rctrl") == true)
    }

    @Test func modifiersChangedReleaseToEmptyIsOmitted() {
        let e = InputEvent(trigger: .key(0), modifiers: [],
                           frontmostBundleID: nil, kind: .modifiersChanged)
        #expect(ObserveCommand.line(for: e) == nil)
    }

    @Test func mouseButtonDownShowsNameAndRawNumber() {
        let e = InputEvent(trigger: .mouseButton(.side1), modifiers: [.cmd],
                           frontmostBundleID: nil, kind: .down)
        let line = ObserveCommand.line(for: e)
        #expect(line?.contains("mouseDown") == true)
        #expect(line?.contains("side1") == true)
        #expect(line?.contains("(3)") == true)   // MouseButton.side1.rawValue
    }

    @Test func scrollShowsDirection() {
        let e = InputEvent(trigger: .scroll(.up), modifiers: [],
                           frontmostBundleID: nil, kind: .down)
        #expect(ObserveCommand.line(for: e)?.contains("dir=up") == true)
    }

    // MARK: - modString

    @Test func modStringEmptyIsNone() {
        #expect(ObserveCommand.modString([]) == "(none)")
    }

    @Test func modStringKeepsSideBitsInStableOrder() {
        #expect(ObserveCommand.modString([.rshift, .lctrl]) == "lctrl + rshift")
    }

    // MARK: - dispatch wiring (no tap is opened)

    /// `config --observe` is registered as a verb that honours no
    /// modifiers — so passing one is rejected (exit 2) BEFORE the
    /// blocking `run()` is reached. This proves the verb is wired in
    /// without actually opening a tap.
    @Test func observeRejectsModifierFlag() {
        let out = ChordApp.dispatch(["config", "--observe", "--json"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("no effect with --observe") == true)
    }

    @Test func observeAppearsInHelp() {
        let out = ChordApp.dispatch(["--help"])
        #expect(out?.stdout?.contains("config --observe") == true)
    }
}
