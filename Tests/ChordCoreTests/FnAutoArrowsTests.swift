import Testing
@testable import ChordCore

/// chord 0.8.0+: macOS always tags arrow / nav keys with
/// `NSEventModifierFlagFunction`, so the strict `fn` comparison in
/// `Modifiers.matches` would force users to spell out `+ fn` for
/// every arrow binding. `Options.fnAutoArrows = true` (default)
/// skips that check for the arrow / nav cluster only.
@Suite struct FnAutoArrowsTests {

    // MARK: - Modifiers.matches `ignoreFn` flag

    @Test func matchesIgnoreFnSkipsTheFnComparison() {
        let binding: Modifiers = [.ctrl]
        let eventWithFn: Modifiers = [.lctrl, .fn]

        #expect(!binding.matches(event: eventWithFn),
                "default-strict matching should reject fn-tagged event")
        #expect(binding.matches(event: eventWithFn, ignoreFn: true),
                "ignoreFn=true must accept fn-tagged event")
    }

    @Test func matchesIgnoreFnStillEnforcesOtherCategories() {
        let binding: Modifiers = [.ctrl]
        let event: Modifiers = [.lcmd, .fn]
        #expect(!binding.matches(event: event, ignoreFn: true),
                "ignoreFn doesn't relax cmd/opt/ctrl/shift")
    }

    // MARK: - Options default + parsing

    @Test func fnAutoArrowsDefaultsTrue() {
        #expect(ChordConfig.Options().fnAutoArrows)
    }

    @Test func parseFnAutoArrowsOption() throws {
        let onByDefault = try Config.parse("")
        #expect(onByDefault.config.options.fnAutoArrows)

        let explicitOn = try Config.parse("""
        [options]
        fn-auto-arrows = true
        """)
        #expect(explicitOn.config.options.fnAutoArrows)

        let explicitOff = try Config.parse("""
        [options]
        fn-auto-arrows = false
        """)
        #expect(!explicitOff.config.options.fnAutoArrows)
    }

    // MARK: - KeyCodes.isFnAutoNav

    @Test func isFnAutoNavRecognizesArrowAndNavKeys() {
        // The 9 keys macOS always decorates with fn.
        for kc: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E,   // arrows
                           0x73, 0x77,               // home/end
                           0x74, 0x79,               // page_up/page_down
                           0x75] {                   // forward_delete
            #expect(KeyCodes.isFnAutoNav(.key(kc)),
                    "keycode 0x\(String(kc, radix: 16)) should be fn-auto-nav")
        }
    }

    @Test func isFnAutoNavRejectsRegularKeys() {
        // Letters / function row / numpad / mouse / scroll / wildcard.
        #expect(!KeyCodes.isFnAutoNav(.key(0x00)))   // 'a'
        #expect(!KeyCodes.isFnAutoNav(.key(0x69)))   // 'f13'
        #expect(!KeyCodes.isFnAutoNav(.key(0x33)))   // delete (regular backspace, no fn)
        #expect(!KeyCodes.isFnAutoNav(.mouseButton(.left)))
        #expect(!KeyCodes.isFnAutoNav(.scroll(.up)))
        #expect(!KeyCodes.isFnAutoNav(.anyKey))
    }

    // MARK: - Matcher end-to-end (default option)

    @Test func ctrlRightMatchesEventWithFn() throws {
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
        #expect(hit?.name == "go right")
    }

    @Test func explicitFnInBindingStillMatches() throws {
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
        #expect(hit?.name == "go right (legacy)")
    }

    @Test func nonArrowKeyStillEnforcesFn() throws {
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
        #expect(withoutFn?.name == "ctrl-a")
        #expect(withFn == nil,
                "fn-auto-arrows must NOT relax non-arrow keys")
    }

    // MARK: - Opt-out (fn-auto-arrows = false)

    @Test func fnAutoArrowsOffRestoresStrictMatching() throws {
        let res = try Config.parse("""
        [options]
        fn-auto-arrows = false

        [[bindings]]
        name = "go right (strict)"
        input = "ctrl - right"
        action-keys = "ctrl - right"
        """)
        #expect(!res.config.options.fnAutoArrows)
        let m = Matcher(bindings: res.config.bindings,
                        fnAutoArrows: res.config.options.fnAutoArrows)
        let hit = m.find(.init(trigger: .key(0x7C),
                               modifiers: [.lctrl, .fn],
                               bundleID: nil))
        #expect(hit == nil, "with fn-auto-arrows=false, fn must match strictly")
    }

    @Test func fnAutoArrowsOffStillAcceptsExplicitFn() throws {
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
        #expect(hit?.name == "go right (strict-explicit)")
    }

    // MARK: - Fallback (.anyKey) uses the event's trigger for fn check

    @Test func fallbackForArrowEventGetsFnRelaxed() throws {
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
        #expect(arrowHit?.name == "ctrl-anything")

        // Same fallback against a non-arrow event with fn still fails
        // (the event isn't fn-auto-nav, so the strict check kicks in).
        let letterHitWithFn = m.find(.init(trigger: .key(0x00),
                                           modifiers: [.lctrl, .fn],
                                           bundleID: nil))
        #expect(letterHitWithFn == nil)
    }

    // MARK: - Schema round-trip

    @Test func schemaEmitsFnAutoArrowsInOptions() throws {
        let json = try parseToBindingsJSON("""
        [options]
        fn-auto-arrows = false
        """)
        let opts = try #require(json["options"] as? [String: Any])
        #expect(opts["fn_auto_arrows"] as? Bool == false)
    }

    @Test func schemaDefaultsFnAutoArrowsTrue() throws {
        let json = try parseToBindingsJSON("")
        let opts = try #require(json["options"] as? [String: Any])
        #expect(opts["fn_auto_arrows"] as? Bool == true)
    }
}
