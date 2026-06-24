import Testing
@testable import ChordCore

@Suite struct InputParserTests {

    /// One parse expectation. `mods` / `trigger` are optional so a case
    /// can assert only the field it cares about (e.g. `hyper - space`
    /// checks modifiers only; `mouse.side1` checks the trigger only).
    struct Case: Sendable {
        let input: String
        var mods: Modifiers? = nil
        var trigger: Trigger? = nil
    }

    @Test(arguments: [
        Case(input: "f13", mods: [], trigger: .key(0x69)),
        Case(input: "f24", trigger: .key(0x6C)),  // Karabiner HID-slot convention
        Case(input: "cmd + shift - return", mods: [.cmd, .shift], trigger: .key(0x24)),
        Case(input: "hyper - space", mods: .hyper),
        Case(input: "mouse.side1", trigger: .mouseButton(.side1)),
        Case(input: "ctrl - scroll.up", mods: .ctrl, trigger: .scroll(.up)),
        Case(input: "cmd + a", mods: .cmd, trigger: .key(0x00)),
        Case(input: "keycode-200", mods: [], trigger: .key(200)),
        // Regression: `keycode-NNN` contains a `-`, which collides with
        // the modifier/primary separator. The standalone form is covered
        // by the fast-path; with modifiers the separator-based split must
        // still work.
        Case(input: "ctrl - keycode-200", mods: .ctrl, trigger: .key(200)),
        // L/R modifier tokens (PR1)
        Case(input: "rctrl - a", mods: .rctrl),
        Case(input: "lctrl + rctrl - a", mods: [.lctrl, .rctrl]),
        Case(input: "ralt - a", mods: .ropt),  // ralt is an alias for ropt
        // ZMK ULTRA_LL = right-side ctrl + alt + shift modifier set.
        Case(input: "rctrl + ralt + rshift - c", mods: [.rctrl, .ropt, .rshift], trigger: .key(0x08)),
        // Existing any-side tokens still parse — no breakage of current configs.
        Case(input: "ctrl + shift - z", mods: [.ctrl, .shift]),
    ])
    func parses(_ c: Case) throws {
        let p = try InputParser.parse(c.input)
        if let mods = c.mods { #expect(p.modifiers == mods) }
        if let trigger = c.trigger { #expect(p.trigger == trigger) }
    }

    @Test func unknownTokenThrows() {
        #expect(throws: (any Error).self) {
            try InputParser.parse("supercmd - a")
        }
    }
}
