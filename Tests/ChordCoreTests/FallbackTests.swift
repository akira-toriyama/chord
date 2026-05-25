import XCTest
@testable import ChordCore

/// Coverage for `[[fallbacks]]` (PR5) — wildcard primary key in
/// fallback section, 2-stage matching, capsule-corp ULTRA_LL
/// effect-sound use case.
final class FallbackTests: XCTestCase {

    // MARK: - parser context

    func testWildcardInBindingsIsRejected() throws {
        // `*` outside [[fallbacks]] must throw — the [[bindings]]
        // section can never accidentally swallow every key.
        XCTAssertThrowsError(try InputParser.parse("ctrl - *",
                                                   allowWildcard: false))
    }

    func testWildcardInFallbackIsAccepted() throws {
        let p = try InputParser.parse(
            "rctrl + ralt + rshift - *", allowWildcard: true)
        XCTAssertEqual(p.modifiers, [.rctrl, .ropt, .rshift])
        XCTAssertEqual(p.trigger, .anyKey)
    }

    // MARK: - 2-stage match

    func testFallbackFiresWhenNoBindingMatches() throws {
        let config = try Config.parse("""
        [[bindings]]
        name = "specific"
        input = "rctrl + ralt + rshift - c"
        action-shell = "echo specific"

        [[fallbacks]]
        name = "ultra_ll undefined"
        input = "rctrl + ralt + rshift - *"
        action-shell = "afplay undefined.wav"
        """)
        XCTAssertEqual(config.config.bindings.count, 1)
        XCTAssertEqual(config.config.fallbacks.count, 1)

        let m = Matcher(bindings: config.config.bindings,
                        fallbacks: config.config.fallbacks)

        // The specific key wins.
        let cKey = m.find(.init(trigger: .key(0x08),
                                modifiers: [.rctrl, .ropt, .rshift],
                                bundleID: nil))
        XCTAssertEqual(cKey?.name, "specific")

        // Any other key under the same modset hits the fallback.
        let zKey = m.find(.init(trigger: .key(0x06),
                                modifiers: [.rctrl, .ropt, .rshift],
                                bundleID: nil))
        XCTAssertEqual(zKey?.name, "ultra_ll undefined")
    }

    func testFallbackDoesNotFireForMouse() throws {
        // anyKey matches keyDown only — mouse / scroll events fall
        // through. The capsule-corp v1 fallback design is keyboard-
        // only by spec; mouse fallbacks are explicitly deferred.
        let config = try Config.parse("""
        [[fallbacks]]
        name = "no-mouse-please"
        input = "rctrl + ralt + rshift - *"
        action-shell = "afplay undefined.wav"
        """)
        let m = Matcher(bindings: [], fallbacks: config.config.fallbacks)
        let mouseHit = m.find(.init(
            trigger: .mouseButton(.side1),
            modifiers: [.rctrl, .ropt, .rshift], bundleID: nil))
        XCTAssertNil(mouseHit)
    }

    func testFallbackModifierConstraintRespected() throws {
        // A fallback scoped to ULTRA_LL (right-only) must NOT fire
        // when the user holds left modifiers instead — the design
        // intent capsule-corp explicitly wants preserved.
        let config = try Config.parse("""
        [[fallbacks]]
        name = "right-only fallback"
        input = "rctrl + ralt + rshift - *"
        action-shell = "afplay undefined.wav"
        """)
        let m = Matcher(bindings: [], fallbacks: config.config.fallbacks)
        let rightHit = m.find(.init(
            trigger: .key(0x06),
            modifiers: [.rctrl, .ropt, .rshift], bundleID: nil))
        XCTAssertEqual(rightHit?.name, "right-only fallback")
        let leftHit = m.find(.init(
            trigger: .key(0x06),
            modifiers: [.lctrl, .lopt, .lshift], bundleID: nil))
        XCTAssertNil(leftHit)
    }

    func testMultipleFallbacksFirstMatchWins() throws {
        let config = try Config.parse("""
        [[fallbacks]]
        name = "ultra_ll"
        input = "rctrl + ralt + rshift - *"
        action-shell = "echo ultra"

        [[fallbacks]]
        name = "mega_rm"
        input = "rctrl + ralt + rshift + rcmd - *"
        action-shell = "echo mega"
        """)
        let m = Matcher(bindings: [], fallbacks: config.config.fallbacks)
        let ultra = m.find(.init(
            trigger: .key(0x07),
            modifiers: [.rctrl, .ropt, .rshift], bundleID: nil))
        XCTAssertEqual(ultra?.name, "ultra_ll")
        let mega = m.find(.init(
            trigger: .key(0x07),
            modifiers: [.rctrl, .ropt, .rshift, .rcmd], bundleID: nil))
        XCTAssertEqual(mega?.name, "mega_rm")
    }

    func testBindingsDropWildcardWithWarning() throws {
        // A user putting `*` inside [[bindings]] is dropped + warned,
        // not loaded — even though the rest of the file parses fine.
        let res = try Config.parse("""
        [[bindings]]
        name = "oops-wildcard"
        input = "ctrl - *"
        action-shell = "echo no"

        [[bindings]]
        name = "good"
        input = "f13"
        action-shell = "echo yes"
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertEqual(res.config.bindings[0].name, "good")
        XCTAssertEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.message.contains("oops-wildcard")
        })
    }
}
