import XCTest
@testable import ChordCore

/// chord 0.8.0+: macOS always tags arrow / nav keys with
/// `NSEventModifierFlagFunction`, so the strict `fn` comparison in
/// `Modifiers.matches` would force users to spell out `+ fn` for
/// every arrow binding. `Options.fnAutoArrows = true` (default)
/// skips that check for the arrow / nav cluster only.
final class FnAutoArrowsTests: XCTestCase {

    // MARK: - Modifiers.matches `ignoreFn` flag

    func testMatchesIgnoreFnSkipsTheFnComparison() {
        let binding: Modifiers = [.ctrl]
        let eventWithFn: Modifiers = [.lctrl, .fn]

        XCTAssertFalse(binding.matches(event: eventWithFn),
                       "default-strict matching should reject fn-tagged event")
        XCTAssertTrue(binding.matches(event: eventWithFn, ignoreFn: true),
                      "ignoreFn=true must accept fn-tagged event")
    }

    func testMatchesIgnoreFnStillEnforcesOtherCategories() {
        let binding: Modifiers = [.ctrl]
        let event: Modifiers = [.lcmd, .fn]
        XCTAssertFalse(binding.matches(event: event, ignoreFn: true),
                       "ignoreFn doesn't relax cmd/opt/ctrl/shift")
    }

    // MARK: - Options default + parsing

    func testFnAutoArrowsDefaultsTrue() {
        XCTAssertTrue(ChordConfig.Options().fnAutoArrows)
    }

    func testParseFnAutoArrowsOption() throws {
        let onByDefault = try Config.parse("")
        XCTAssertTrue(onByDefault.config.options.fnAutoArrows)

        let explicitOn = try Config.parse("""
        [options]
        fn-auto-arrows = true
        """)
        XCTAssertTrue(explicitOn.config.options.fnAutoArrows)

        let explicitOff = try Config.parse("""
        [options]
        fn-auto-arrows = false
        """)
        XCTAssertFalse(explicitOff.config.options.fnAutoArrows)
    }

    // MARK: - KeyCodes.isFnAutoNav

    func testIsFnAutoNavRecognizesArrowAndNavKeys() {
        // The 9 keys macOS always decorates with fn.
        for kc: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E,   // arrows
                           0x73, 0x77,               // home/end
                           0x74, 0x79,               // page_up/page_down
                           0x75] {                   // forward_delete
            XCTAssertTrue(KeyCodes.isFnAutoNav(.key(kc)),
                          "keycode 0x\(String(kc, radix: 16)) should be fn-auto-nav")
        }
    }

    func testIsFnAutoNavRejectsRegularKeys() {
        // Letters / function row / numpad / mouse / scroll / wildcard.
        XCTAssertFalse(KeyCodes.isFnAutoNav(.key(0x00)))   // 'a'
        XCTAssertFalse(KeyCodes.isFnAutoNav(.key(0x69)))   // 'f13'
        XCTAssertFalse(KeyCodes.isFnAutoNav(.key(0x33)))   // delete (regular backspace, no fn)
        XCTAssertFalse(KeyCodes.isFnAutoNav(.mouseButton(.left)))
        XCTAssertFalse(KeyCodes.isFnAutoNav(.scroll(.up)))
        XCTAssertFalse(KeyCodes.isFnAutoNav(.anyKey))
    }

    // MARK: - Matcher end-to-end (default option)

    func testCtrlRightMatchesEventWithFn() throws {
        // The canonical pain point: user writes `ctrl - right`, macOS
        // emits `ctrl + fn + right` — these must match by default.
        let res = try Config.parse("""
        [[bindings]]
        name = "go right"
        input = "ctrl - right"
        action-keys = "ctrl + fn - right"
        """)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let hit = m.find(.init(trigger: .key(0x7C),     // arrow_right
                               modifiers: [.lctrl, .fn],
                               bundleID: nil))
        XCTAssertEqual(hit?.name, "go right")
    }

    func testExplicitFnInBindingStillMatches() throws {
        // Legacy form `ctrl + fn - right` must also still match —
        // fn-auto-arrows relaxes the comparison on both sides for
        // arrow / nav triggers.
        let res = try Config.parse("""
        [[bindings]]
        name = "go right (legacy)"
        input = "ctrl + fn - right"
        action-keys = "ctrl + fn - right"
        """)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let hit = m.find(.init(trigger: .key(0x7C),
                               modifiers: [.lctrl, .fn],
                               bundleID: nil))
        XCTAssertEqual(hit?.name, "go right (legacy)")
    }

    func testNonArrowKeyStillEnforcesFn() throws {
        // For an `a` keystroke, fn matching is still strict — there
        // are real keyboards where fn+a is a distinct chord and we
        // don't want to collapse them.
        let res = try Config.parse("""
        [[bindings]]
        name = "ctrl-a"
        input = "ctrl - a"
        action-keys = "ctrl - a"
        """)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let withoutFn = m.find(.init(trigger: .key(0x00),  // 'a'
                                     modifiers: [.lctrl],
                                     bundleID: nil))
        let withFn = m.find(.init(trigger: .key(0x00),
                                  modifiers: [.lctrl, .fn],
                                  bundleID: nil))
        XCTAssertEqual(withoutFn?.name, "ctrl-a")
        XCTAssertNil(withFn,
                     "fn-auto-arrows must NOT relax non-arrow keys")
    }

    // MARK: - Opt-out (fn-auto-arrows = false)

    func testFnAutoArrowsOffRestoresStrictMatching() throws {
        let res = try Config.parse("""
        [options]
        fn-auto-arrows = false

        [[bindings]]
        name = "go right (strict)"
        input = "ctrl - right"
        action-keys = "ctrl - right"
        """)
        XCTAssertFalse(res.config.options.fnAutoArrows)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let hit = m.find(.init(trigger: .key(0x7C),
                               modifiers: [.lctrl, .fn],
                               bundleID: nil))
        XCTAssertNil(hit, "with fn-auto-arrows=false, fn must match strictly")
    }

    func testFnAutoArrowsOffStillAcceptsExplicitFn() throws {
        let res = try Config.parse("""
        [options]
        fn-auto-arrows = false

        [[bindings]]
        name = "go right (strict-explicit)"
        input = "ctrl + fn - right"
        action-keys = "ctrl + fn - right"
        """)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let hit = m.find(.init(trigger: .key(0x7C),
                               modifiers: [.lctrl, .fn],
                               bundleID: nil))
        XCTAssertEqual(hit?.name, "go right (strict-explicit)")
    }

    // MARK: - Fallback (.anyKey) uses the event's trigger for fn check

    func testFallbackForArrowEventGetsFnRelaxed() throws {
        // A wildcard fallback (`input = "*"`) fires on every keyboard
        // event. If the event is an arrow key, fn-auto-arrows should
        // skip the fn check so a `ctrl - *` fallback catches `ctrl + fn
        // + arrow_right`.
        let res = try Config.parse("""
        [[fallbacks]]
        name = "ctrl-anything"
        input = "ctrl - *"
        action-keys = "f1"
        """)
        let m = Matcher(bindings: [],
                        fallbacks: res.config.fallbacks,
                        fnAutoArrows: true)
        let arrowHit = m.find(.init(trigger: .key(0x7C),
                                    modifiers: [.lctrl, .fn],
                                    bundleID: nil))
        XCTAssertEqual(arrowHit?.name, "ctrl-anything")

        // Same fallback against a non-arrow event with fn still fails
        // (the event isn't fn-auto-nav, so the strict check kicks in).
        let letterHitWithFn = m.find(.init(trigger: .key(0x00),
                                           modifiers: [.lctrl, .fn],
                                           bundleID: nil))
        XCTAssertNil(letterHitWithFn)
    }

    // MARK: - Schema round-trip

    func testSchemaEmitsFnAutoArrowsInOptions() throws {
        let res = try Config.parse("""
        [options]
        fn-auto-arrows = false
        """)
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let opts = json["options"] as! [String: Any]
        XCTAssertEqual(opts["fn_auto_arrows"] as? Bool, false)
    }

    func testSchemaDefaultsFnAutoArrowsTrue() throws {
        let res = try Config.parse("")
        let doc = BindingsSchema.makeDocument(from: res)
        let data = try BindingsSchema.encodeJSON(doc)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let opts = json["options"] as! [String: Any]
        XCTAssertEqual(opts["fn_auto_arrows"] as? Bool, true)
    }
}
